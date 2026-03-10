---
name: eai-fundamentals
description: Envoy AI Gateway fundamentals — CRDs, resource hierarchy, API schemas, and provider authentication
---

# Envoy AI Gateway Fundamentals

Envoy AI Gateway extends Envoy Gateway to provide a unified API gateway for generative AI services. It translates between client-facing APIs (e.g., OpenAI-compatible) and backend-specific APIs (OpenAI, Anthropic, AWS Bedrock, Azure OpenAI, GCP Vertex AI, Cohere, etc.).

## Resource Hierarchy

```
GatewayClass (Gateway API)
  -> Gateway (Gateway API)
    -> AIGatewayRoute (AI Gateway CRD)
      -> rules with matches + backendRefs
        -> AIServiceBackend (AI Gateway CRD)
          -> Backend (Envoy Gateway) or InferencePool (Gateway API extension)
```

### Core AI Gateway CRDs (aigateway.envoyproxy.io/v1alpha1)

| CRD | Purpose |
|-----|---------|
| **AIGatewayRoute** | Binds AI backends to a Gateway. Defines routing rules (header matches, e.g. `x-ai-eg-model`), backend refs, timeouts, and optional LLM cost capture. Generates HTTPRoute and HTTPRouteFilter under the hood. |
| **AIServiceBackend** | Describes a single AI backend: its API schema (OpenAI, Anthropic, AWSBedrock, etc.) and the Envoy Gateway Backend it attaches to. |
| **BackendSecurityPolicy** | Backend authentication: API key, AWS credentials, Azure credentials, GCP credentials, Anthropic API key. Attaches to AIServiceBackend or InferencePool. |
| **GatewayConfig** | Gateway-scoped config (extProc resources, endpoint prefixes). Referenced via annotation on Gateway. |
| **MCPRoute** | Model Context Protocol routing for MCP tools. |
| **QuotaPolicy** | Rate limiting and quota management. |

### Envoy Gateway Resources Used by AI Gateway

- **Gateway**, **GatewayClass**, **HTTPRoute** — standard Gateway API
- **Backend** — external endpoints (FQDN, port) for AI providers
- **BackendTLSPolicy** — TLS validation for Backend (use `gateway.networking.k8s.io/v1` with Envoy Gateway v1.6+)
- **ClientTrafficPolicy** — client-facing settings (buffer limits, timeouts). **Required for AI**: set `connection.bufferLimit` (e.g., `50Mi`) because default 32KiB is too small for AI requests.
- **EnvoyProxy** — customizes Envoy deployment

## API Schemas (schema.name in AIServiceBackend)

Supported values (from ai-gateway codebase):

- **OpenAI** — OpenAI API, OpenAI-compatible backends
- **Cohere** — Cohere API
- **AWSBedrock** — AWS Bedrock
- **AzureOpenAI** — Azure OpenAI
- **GCPVertexAI** — GCP Vertex AI (Gemini)
- **GCPAnthropic** — Anthropic on GCP Vertex AI
- **Anthropic** — Native Anthropic API
- **AWSAnthropic** — Anthropic on AWS Bedrock

## Routing Model

- **x-ai-eg-model** header: The AI Gateway filter extracts the model from the request body and injects it into this header. Use it in AIGatewayRoute `matches` to route by model.
- **BackendRefs**: Reference AIServiceBackend by name (default). Can also reference InferencePool (`group: inference.networking.k8s.io`, `kind: InferencePool`) for self-hosted models.
- **Priority**: Use `priority` in backendRefs for failover (lower number = higher priority).
- **Weight**: Use `weight` for traffic splitting across backends.

## BackendSecurityPolicy Types

| Type | Use Case |
|------|----------|
| APIKey | OpenAI, generic API key in Authorization header |
| AnthropicAPIKey | Anthropic (x-api-key header) |
| AzureAPIKey | Azure OpenAI (api-key header) |
| AzureCredentials | Azure OpenAI with OAuth/client secret |
| AWSCredentials | AWS Bedrock (IRSA, Pod Identity, or credentials file) |
| GCPCredentials | GCP Vertex AI (service account or workload identity) |

## Two-Tier Gateway Pattern

- **Tier One Gateway**: Central entry point; handles auth, top-level routing, global rate limiting.
- **Tier Two Gateway**: Fine-grained control over self-hosted models; InferencePool with endpoint picker for LLM optimization.

## Naming Conventions

- Use **kebab-case** for resource names
- AIServiceBackend and Backend often share the same name for clarity
- BackendSecurityPolicy names typically indicate provider: `my-backend-openai-apikey`

## Checklist

- [ ] Understand AIGatewayRoute → AIServiceBackend → Backend chain
- [ ] Know which schema.name matches your provider
- [ ] BackendSecurityPolicy required for cloud providers (OpenAI, Anthropic, AWS, Azure, GCP)
- [ ] ClientTrafficPolicy with bufferLimit for AI workloads
- [ ] BackendTLSPolicy for HTTPS backends (hostname validation)
