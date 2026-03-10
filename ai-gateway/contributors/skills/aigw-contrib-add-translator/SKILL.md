---
name: aigw-contrib-add-translator
description: Add a new LLM provider translator to envoyproxy/ai-gateway — the most common contribution type
arguments:
  - name: SourceSchema
    description: "Input API schema (e.g., OpenAI, Anthropic)"
    required: true
  - name: TargetSchema
    description: "Output API schema (e.g., AWSBedrock, AzureOpenAI, GCPVertexAI)"
    required: true
  - name: ProviderName
    description: "Human-readable provider name (e.g., AWS Bedrock, Azure OpenAI)"
    required: true
---

# Add a New Translator

Add a new LLM provider translator to Envoy AI Gateway. This is the most common contribution type. A translator converts requests from one API schema (e.g., OpenAI) to another (e.g., AWS Bedrock) and translates responses back.

**Before starting**: Read `aigw-contrib-go-style` — performance patterns and JSON handling are the most common reasons translator PRs get rejected.

## Phase 1: Understand the Interfaces

Study an existing translator to understand the pattern. Start with a simple one like `openai_openai.go` (passthrough), then look at a complex one like `openai_awsbedrock.go`.

Key interfaces your translator must implement:

1. **Request translation**: `(sourceBody []byte) → (targetBody []byte, error)`
2. **Response translation**: `(targetBody []byte) → (sourceBody []byte, error)`
3. **Streaming chunk translation**: `(targetChunk []byte) → (sourceChunk []byte, error)`

The translator is generic over `[ReqT, RespT, RespChunkT]` type parameters.

## Phase 2: Create the Translator File

Create `internal/extproc/translators/${SourceSchema}_${TargetSchema}.go`:

```go
// Copyright Envoy AI Gateway Authors
// SPDX-License-Identifier: Apache-2.0
// The full text of the Apache license is available in the LICENSE file at
// the root of the repo.

package translators

import (
    "fmt"

    "github.com/tidwall/gjson"
    "github.com/tidwall/sjson"

    "github.com/envoyproxy/ai-gateway/internal/json"
)

// ${SourceSchema}To${TargetSchema}Translator translates from ${SourceSchema}
// to ${TargetSchema} API format.
type ${sourceSchema}To${targetSchema}Translator struct {
    // Pre-allocated resources — constructed once, not per-request
}

// new${SourceSchema}To${TargetSchema}Translator creates a new translator.
func new${SourceSchema}To${TargetSchema}Translator() *${sourceSchema}To${targetSchema}Translator {
    return &${sourceSchema}To${targetSchema}Translator{}
}
```

### Key Implementation Rules

- **Use `gjson`** to read JSON fields — never unmarshal to `map[string]interface{}`
- **Use `sjson`** to mutate JSON bytes — never marshal from maps
- **Use `internal/json`** for marshal/unmarshal — never `encoding/json`
- **Pre-allocate** byte buffers and reusable objects in the constructor
- **No allocations inside loops** — the translator runs in the hot path

### Request Translation Example

```go
func (t *${sourceSchema}To${targetSchema}Translator) translateRequest(
    body []byte,
) (translated []byte, err error) {
    // Extract model from source format
    model := gjson.GetBytes(body, "model").String()
    if model == "" {
        return nil, fmt.Errorf("missing model field in request")
    }

    // Transform to target format
    translated = body // Start with source, modify as needed
    translated, err = sjson.SetBytes(translated, "modelId", model)
    if err != nil {
        return nil, fmt.Errorf("setting modelId: %w", err)
    }
    translated, err = sjson.DeleteBytes(translated, "model")
    if err != nil {
        return nil, fmt.Errorf("deleting model: %w", err)
    }

    return translated, nil
}
```

### Streaming Response Translation

```go
var (
    sseDataPrefix  = []byte("data: ")
    sseLineEnd     = []byte("\n\n")
    sseDoneMessage = []byte("data: [DONE]\n\n")
)

func (t *${sourceSchema}To${targetSchema}Translator) translateStreamChunk(
    chunk []byte,
) (out []byte, err error) {
    // Handle [DONE] sentinel
    if bytes.Equal(bytes.TrimSpace(chunk), []byte("[DONE]")) {
        return sseDoneMessage, nil
    }

    // Parse target format chunk
    // Transform to source format chunk
    // Build SSE output
    out = append(out, sseDataPrefix...)
    out = append(out, translatedChunk...)
    out = append(out, sseLineEnd...)
    return out, nil
}
```

## Phase 3: Register the Translator

Register your translator in the EndpointSpec path-based lookup. The exact registration location depends on the current codebase structure — look for where existing translators are registered (typically in the router or upstream processor initialization).

The registration maps:
- API path (e.g., `/v1/chat/completions`) + source schema + target schema → your translator

## Phase 4: Add Backend Auth (if new auth type)

If the target provider needs a new authentication method not already supported:

1. Add auth type to `internal/extproc/backendauth/`
2. Update `api/v1alpha1/backend_security_policy_types.go` (separate API PR)
3. Update controller to handle the new auth type

Existing auth types: APIKey, AnthropicAPIKey, AzureAPIKey, AWSCredentials, AzureCredentials, GCPCredentials.

## Phase 5: Update filterapi.Config

If the new translator introduces a new `VersionedAPISchema` value:

1. Add the schema constant to `api/v1alpha1/filterapi/filterapi.go`
2. Update the controller to recognize the new schema
3. This may be part of the API PR if it is type-only

## Phase 6: Write Unit Tests

Create `internal/extproc/translators/${SourceSchema}_${TargetSchema}_test.go`:

```go
// Copyright Envoy AI Gateway Authors
// SPDX-License-Identifier: Apache-2.0
// The full text of the Apache license is available in the LICENSE file at
// the root of the repo.

package translators

import (
    "testing"

    "github.com/stretchr/testify/require"
)

func Test${SourceSchema}To${TargetSchema}_TranslateRequest(t *testing.T) {
    translator := new${SourceSchema}To${TargetSchema}Translator()

    tests := []struct {
        name      string
        input     []byte
        expOutput []byte
        expErr    string
    }{
        {
            name:      "valid chat completion",
            input:     []byte(`{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}`),
            expOutput: []byte(`{...target format...}`),
        },
        {
            name:   "missing model",
            input:  []byte(`{"messages":[{"role":"user","content":"hello"}]}`),
            expErr: "missing model",
        },
        {
            name:      "with streaming option",
            input:     []byte(`{"model":"gpt-4o","stream":true,"messages":[...]}`),
            expOutput: []byte(`{...target with streaming...}`),
        },
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            output, err := translator.translateRequest(tc.input)
            if tc.expErr != "" {
                require.ErrorContains(t, err, tc.expErr)
                return
            }
            require.NoError(t, err)
            require.JSONEq(t, string(tc.expOutput), string(output))
        })
    }
}

func Test${SourceSchema}To${TargetSchema}_TranslateStreamChunk(t *testing.T) {
    translator := new${SourceSchema}To${TargetSchema}Translator()

    tests := []struct {
        name      string
        chunk     []byte
        expOutput []byte
        expErr    string
    }{
        {
            name:      "normal data chunk",
            chunk:     []byte(`{...target streaming chunk...}`),
            expOutput: []byte("data: {...source streaming chunk...}\n\n"),
        },
        {
            name:      "done sentinel",
            chunk:     []byte("[DONE]"),
            expOutput: []byte("data: [DONE]\n\n"),
        },
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            output, err := translator.translateStreamChunk(tc.chunk)
            if tc.expErr != "" {
                require.ErrorContains(t, err, tc.expErr)
                return
            }
            require.NoError(t, err)
            require.Equal(t, string(tc.expOutput), string(output))
        })
    }
}
```

### go-vcr for Real Provider Responses

For more realistic tests, use go-vcr to record real API interactions:

```go
func TestWithRealProvider(t *testing.T) {
    r, err := recorder.New("testdata/fixtures/${SourceSchema}-to-${TargetSchema}")
    require.NoError(t, err)
    defer r.Stop()

    // Use r as HTTP transport — records/replays real responses
}
```

## Phase 7: Write Data Plane Tests

Add tests in `tests/data-plane/` that run your translator through a real Envoy:

```go
//go:build test_data_plane

func Test${SourceSchema}To${TargetSchema}_DataPlane(t *testing.T) {
    // 1. Write filterapi.Config with new schema mapping
    // 2. Start ExtProc server
    // 3. Start Envoy via func-e
    // 4. Send ${SourceSchema}-format request
    // 5. Verify backend receives ${TargetSchema} format
    // 6. Verify response translated back to ${SourceSchema}
    // 7. Test streaming SSE path
}
```

Run: `make test-data-plane`

## Checklist

- [ ] Translator file: `internal/extproc/translators/${SourceSchema}_${TargetSchema}.go`
- [ ] Uses `gjson`/`sjson` for JSON ops — not `encoding/json` or maps
- [ ] Uses `internal/json` for marshal/unmarshal
- [ ] No allocations in hot path (pre-allocate in constructor)
- [ ] Handles both streaming (SSE) and non-streaming responses
- [ ] SSE `[DONE]` sentinel handled correctly
- [ ] Registered in EndpointSpec path-based lookup
- [ ] Unit tests with table-driven cases (valid, invalid, streaming)
- [ ] Data plane tests with func-e
- [ ] License header on all new files
- [ ] `make precommit` passes
- [ ] `make test` passes
- [ ] PR title: `feat(extproc): add ${SourceSchema} to ${TargetSchema} translator`
