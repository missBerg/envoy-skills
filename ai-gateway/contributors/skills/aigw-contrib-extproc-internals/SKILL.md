---
name: aigw-contrib-extproc-internals
description: Envoy AI Gateway ExtProc internals — request lifecycle, translator pattern, EndpointSpec, streaming SSE, backend auth, and common data plane mistakes
---

# ExtProc Internals

## Request Lifecycle

```
Client Request (e.g., OpenAI chat/completions)
  │
  ▼
┌──────────────────────────────────────────────────────────┐
│                     Envoy Proxy                           │
│                                                          │
│  1. Receive request                                      │
│  2. ExtProc: Router Filter                               │
│     ├─ Extract model from request body                   │
│     ├─ Set x-ai-eg-model header                          │
│     └─ Return to Envoy for routing decision              │
│  3. Envoy routes based on x-ai-eg-model header           │
│  4. ExtProc: Upstream Filter                             │
│     ├─ Translate request (e.g., OpenAI → AWSBedrock)     │
│     ├─ Inject backend auth (API key, SigV4, etc.)        │
│     ├─ Rewrite host header                               │
│     └─ Modify request body for target schema             │
│  5. Forward to backend                                   │
│                                                          │
│  Response path:                                          │
│  6. ExtProc: Upstream Filter                             │
│     ├─ Translate response (e.g., AWSBedrock → OpenAI)    │
│     ├─ Handle streaming SSE chunks                       │
│     └─ Aggregate token usage metadata                    │
│  7. Return response to client                            │
└──────────────────────────────────────────────────────────┘
```

## Translator Pattern

Translators perform direct input→output schema mappings. There is **no universal intermediate representation** — each source-target pair is a separate implementation.

### File Naming Convention

```
internal/extproc/translators/<source>_<target>.go
```

Examples:
- `openai_awsbedrock.go` — OpenAI → AWS Bedrock
- `anthropic_openai.go` — Anthropic → OpenAI
- `openai_openai.go` — OpenAI → OpenAI (passthrough with model rewrite)

### Translator Interface

Each translator implements methods for:

1. **Request translation**: Transform request body from source schema to target schema
2. **Response translation**: Transform non-streaming response body from target back to source
3. **Streaming response translation**: Transform individual SSE chunks from target back to source

```go
// Simplified — actual uses generics [ReqT, RespT, RespChunkT]
type translator interface {
    TranslateRequest(body []byte) ([]byte, error)
    TranslateResponse(body []byte) ([]byte, error)
    TranslateResponseChunk(chunk []byte) ([]byte, error)
}
```

### Translator Matrix

The number of translators grows as O(n*m) where n = input schemas, m = output schemas:

| Source → Target | File |
|-----------------|------|
| OpenAI → OpenAI | `openai_openai.go` |
| OpenAI → AWSBedrock | `openai_awsbedrock.go` |
| OpenAI → AzureOpenAI | `openai_azureopenai.go` |
| OpenAI → GCPVertexAI | `openai_gcpvertexai.go` |
| Anthropic → OpenAI | `anthropic_openai.go` |
| Anthropic → AWSBedrock | `anthropic_awsbedrock.go` |

## EndpointSpec Abstraction

EndpointSpec maps API paths to the correct translator. Each backend has an EndpointSpec that defines which translator to use for each path:

```go
// Simplified concept
type EndpointSpec struct {
    Path       string          // e.g., "/v1/chat/completions"
    Schema     VersionedAPISchema
    Translator translatorFunc  // Resolved from path + source + target schema
}
```

The path determines the translator lookup:
- `/v1/chat/completions` → chat completion translator
- `/v1/embeddings` → embeddings translator
- `/v1/images/generations` → image generation translator

## Streaming SSE Handling

AI responses often use Server-Sent Events (SSE) for streaming. The ExtProc processes chunks incrementally:

### SSE Wire Format

```
data: {"id":"chatcmpl-123","choices":[{"delta":{"content":"Hello"}}]}\n\n
data: {"id":"chatcmpl-123","choices":[{"delta":{"content":" world"}}]}\n\n
data: [DONE]\n\n
```

### Processing Pattern

1. ExtProc receives response body chunks from Envoy
2. Each chunk may contain partial or multiple SSE events
3. Translator processes each complete `data:` line individually
4. Translated chunks are reassembled with SSE framing
5. `[DONE]` sentinel is passed through

### Key Implementation Details

- SSE constants (`data: `, `\n\n`, `[DONE]`) are pre-allocated as package-level byte slices
- Output is built via direct `append(*out, ...)` — no SSE libraries
- Buffered parsing: maintain a `buffered` field for incomplete chunks across calls
- AWS EventStream uses a different binary framing — dedicated parser needed

## filterapi.Config Structure

The control plane writes this config; the data plane reads it:

```go
type Config struct {
    // Routes maps request patterns to backend selections
    Routes []RouteConfig
    // Schema defines the client-facing API schema
    Schema VersionedAPISchema
    // ModelNameMapping overrides model names per backend
    ModelNameMapping map[string]string
    // BackendAuth contains credentials for each backend
    // ... additional fields for TLS, timeouts, etc.
}
```

The config is serialized as YAML to a K8s Secret and mounted as a file. ExtProc watches via fsnotify.

## Backend Authentication Types

| Type | Header/Mechanism | Implementation |
|------|-----------------|----------------|
| APIKey | `Authorization: Bearer <key>` | `backendauth/api_key.go` |
| AnthropicAPIKey | `x-api-key: <key>` | `backendauth/api_key.go` (variant) |
| AzureAPIKey | `api-key: <key>` | `backendauth/api_key.go` (variant) |
| AWSCredentials | AWS SigV4 signing | `backendauth/aws.go` (request signing) |
| AzureCredentials | `Authorization: Bearer <token>` (OAuth) | `backendauth/azure.go` (token exchange) |
| GCPCredentials | `Authorization: Bearer <token>` (WIF) | `backendauth/gcp.go` (token exchange) |

For AWS/Azure/GCP, the controller runs credential rotators that periodically refresh tokens and update the Secret.

## Common Data Plane Mistakes

| Mistake | Fix |
|---------|-----|
| Using `encoding/json` | Use `internal/json` (sonic wrapper) — mandatory, linter enforced |
| Allocating per-request resources | Pre-allocate HTTP clients, decoders, byte buffers at init time |
| Not handling streaming responses | Every translator must handle both streaming (SSE) and non-streaming paths |
| Forgetting `[DONE]` sentinel in SSE | Always check for and pass through the `data: [DONE]` line |
| Using `map[string]interface{}` for JSON mutation | Use `sjson` (tidwall) for byte-level JSON mutation |
| Not buffering partial SSE chunks | Maintain a `buffered` field across ProcessResponseBody calls |
| Modifying request body without updating Content-Length | Envoy handles this, but ensure the body bytes are correct |
| Not nil-checking optional fields in filterapi.Config | Config fields can be nil; always guard access |
| Ignoring error from translator | Wrap with context: `fmt.Errorf("translating request from %s to %s: %w", src, tgt, err)` |
| Adding a new translator without registering it | Register in the EndpointSpec path-based lookup table |
