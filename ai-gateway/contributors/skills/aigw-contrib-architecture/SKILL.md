---
name: aigw-contrib-architecture
description: Envoy AI Gateway codebase architecture — two-level ExtProc, file-based config, controller reconcilers, directory layout, and key types for navigating the envoyproxy/ai-gateway repository
---

# Envoy AI Gateway Architecture

## System Architecture

```
                   ┌─────────────────────────────────────────┐
                   │         AI Gateway Controller           │
                   │  (cmd/controller/main.go)               │
                   │                                         │
                   │  Reconciles: AIGatewayRoute,            │
                   │  AIServiceBackend, BackendSecurityPolicy,│
                   │  GatewayConfig, MCPRoute, QuotaPolicy   │
                   │                                         │
                   │  Publishes: filterapi.Config → K8s Secret│
                   │  Extension Server → Envoy Gateway       │
                   └────────────┬──────────────┬─────────────┘
                                │              │
                    Secret write│    gRPC hooks │
                                ▼              ▼
┌───────────────────────────────────────────────────────────┐
│                    Envoy Proxy Pod                         │
│                                                           │
│  ┌──────────────┐    ┌──────────────┐    ┌─────────────┐ │
│  │  Envoy Proxy │───▶│ Router       │───▶│ Upstream    │ │
│  │  (data plane)│    │ ExtProc      │    │ ExtProc     │ │
│  │              │◀───│ (sidecar)    │    │ (sidecar)   │ │
│  └──────────────┘    └──────────────┘    └─────────────┘ │
│                        │ watches file      │ watches file │
│                        ▼                   ▼              │
│                      filterapi.Config (mounted Secret)    │
└───────────────────────────────────────────────────────────┘
```

## Three Binaries

| Binary | Entry Point | Purpose |
|--------|-------------|---------|
| **controller** | `cmd/controller/main.go` | Reconciles AI Gateway CRDs, writes filterapi.Config to K8s Secrets, runs Extension Server for Envoy Gateway |
| **extproc** | `cmd/extproc/main.go` | External Processor sidecar — handles request/response translation, auth injection, model extraction |
| **aigw** | `cmd/aigw/main.go` | CLI for debugging, local development |

## Six CRDs

| CRD | API Group | Purpose |
|-----|-----------|---------|
| **AIGatewayRoute** | `aigateway.envoyproxy.io/v1alpha1` | Binds AI backends to a Gateway via routing rules (model-based header matching) |
| **AIServiceBackend** | `aigateway.envoyproxy.io/v1alpha1` | Describes an AI backend: API schema + reference to Envoy Gateway Backend |
| **BackendSecurityPolicy** | `aigateway.envoyproxy.io/v1alpha1` | Backend auth: API key, AWS SigV4, Azure AD, GCP WIF, Anthropic |
| **GatewayConfig** | `aigateway.envoyproxy.io/v1alpha1` | Per-Gateway ExtProc customization (resources, env vars) |
| **MCPRoute** | `aigateway.envoyproxy.io/v1alpha1` | Model Context Protocol routing for MCP tool access |
| **QuotaPolicy** | `aigateway.envoyproxy.io/v1alpha1` | Rate limiting and token quota management |

## Two-Level ExtProc Design

The key architectural decision: two separate ExtProc filters per request.

| Filter | Phase | Responsibility |
|--------|-------|----------------|
| **Router ExtProc** | Before routing | Extract model from request body, set `x-ai-eg-model` header, select backend |
| **Upstream ExtProc** | After routing | Translate request schema (e.g., OpenAI → AWSBedrock), inject backend auth, translate response |

This separation enables retry with a different backend schema — if the primary backend fails, Envoy can retry to a fallback with a different API schema, and the upstream ExtProc translates appropriately.

## File-Based Control-to-Data-Plane Communication

The ExtProc sidecar has **zero Kubernetes awareness**. All configuration flows through files:

1. Controller reconciles CRDs → builds `filterapi.Config` struct
2. Controller writes config as YAML to a K8s Secret
3. Secret is mounted as a file in the Envoy Pod
4. ExtProc watches the file via fsnotify and reloads on change

This design means the ExtProc binary can run outside Kubernetes (e.g., with `func-e` in tests).

## Directory Map

| Directory | Responsibility | Key Files |
|-----------|---------------|-----------|
| `api/v1alpha1/` | CRD type definitions | `*_types.go`, `zz_generated.deepcopy.go` |
| `api/v1alpha1/filterapi/` | Data plane config wire format | `filterapi.go` (Config struct) |
| `internal/controller/` | Kubernetes controller reconcilers | `ai_gateway_route.go`, `ai_service_backend.go`, `backend_security_policy.go` |
| `internal/controller/rotators/` | Credential rotation controllers | `aws.go`, `gcp.go`, `azure.go` |
| `internal/extensionserver/` | Envoy Gateway extension hooks | `server.go` (PostRouteModify, PostTranslateModify, PostClusterModify) |
| `internal/extproc/` | ExtProc main logic | `server.go`, `listener.go` |
| `internal/extproc/router/` | Router filter processors | `router.go`, `request_body.go` |
| `internal/extproc/upstream/` | Upstream filter processors | `upstream.go`, `request_body.go`, `response_body.go` |
| `internal/extproc/translators/` | Schema translators (O(n*m) files) | `openai_awsbedrock.go`, `anthropic_openai.go`, etc. |
| `internal/extproc/backendauth/` | Backend auth injection | `api_key.go`, `aws.go`, `azure.go`, `gcp.go` |
| `internal/json/` | JSON wrapper (sonic under the hood) | `json.go` — **always use this, never encoding/json** |
| `tests/crdcel/` | CEL validation tests | `*_test.go` |
| `tests/controller/` | Controller integration tests (envtest) | `*_test.go` |
| `tests/data-plane/` | Data plane tests with func-e | `*_test.go` |
| `tests/e2e/` | End-to-end tests (kind cluster) | `*_test.go`, `testdata/` |
| `manifests/` | Helm values, example configs | `envoy-gateway-values.yaml` |

## Controller Reconcilers

| Reconciler | File | Watches |
|------------|------|---------|
| `aiGatewayRouteController` | `ai_gateway_route.go` | AIGatewayRoute, HTTPRoute, HTTPRouteFilter |
| `aiServiceBackendController` | `ai_service_backend.go` | AIServiceBackend, Backend |
| `backendSecurityPolicyController` | `backend_security_policy.go` | BackendSecurityPolicy, Secrets |
| `gatewayConfigController` | `gateway_config.go` | GatewayConfig, Gateway |
| `mcpRouteController` | `mcp_route.go` | MCPRoute |
| `quotaPolicyController` | `quota_policy.go` | QuotaPolicy |
| `sinkController` | `sink.go` | Aggregates all configs → writes filterapi.Config Secret |
| `awsCredentialRotator` | `rotators/aws.go` | Rotates AWS STS credentials |
| `gcpCredentialRotator` | `rotators/gcp.go` | Rotates GCP access tokens |

## Extension Server Hooks

The controller runs an Extension Server that hooks into Envoy Gateway's xDS translation:

| Hook | Purpose |
|------|---------|
| `PostRouteModify` | Injects ExtProc filter references into HTTPRoute xDS |
| `PostTranslateModify` | Modifies listener/cluster xDS after translation |
| `PostClusterModify` | Adjusts upstream cluster settings for AI backends |

## Generic Processor Types

The ExtProc uses Go generics for type-safe request/response processing:

```go
// Router processor — extracts model, selects backend
type routerProcessor[
    ReqT    any,  // Request body type (e.g., openaiChatCompletionRequest)
    RespT   any,  // Response body type
    RespChunkT any,  // Streaming response chunk type
    EndpointSpecT any, // Backend-specific config
]

// Upstream processor — translates schemas, injects auth
type upstreamProcessor[
    ReqT    any,
    RespT   any,
    RespChunkT any,
    EndpointSpecT any,
]
```

## filterapi.Config Wire Format

The central data structure connecting control plane to data plane:

```go
// api/v1alpha1/filterapi/filterapi.go
type Config struct {
    Schema          VersionedAPISchema
    Routes          []RouteConfig
    ModelNameMapping map[string]string
    // ... backend auth, TLS, etc.
}
```

Written as YAML to a K8s Secret, mounted in the Envoy Pod, watched by ExtProc.

## Gateway API to AI Gateway Concept Mapping

| Gateway API / EG | AI Gateway | Notes |
|------------------|------------|-------|
| Gateway | Gateway + GatewayConfig annotation | GatewayConfig customizes ExtProc per Gateway |
| HTTPRoute | AIGatewayRoute (generates HTTPRoute) | AI Gateway controller generates the HTTPRoute |
| Backend (EG) | AIServiceBackend → Backend | AIServiceBackend adds schema; must ref Backend |
| — | BackendSecurityPolicy | AI-specific auth (API keys, cloud IAM) |
| — | ExtProc (Router + Upstream) | Injected as sidecars by controller |

## Entry Points for Common Tasks

| Task | Start Here |
|------|-----------:|
| Add a new CRD field | `api/v1alpha1/` → `make apigen` → `make codegen` |
| Add a new LLM provider translator | `internal/extproc/translators/` → register in endpoint spec |
| Add backend auth type | `internal/extproc/backendauth/` → update `filterapi.Config` |
| Fix a controller bug | `internal/controller/` → check reconciler logic |
| Fix an ExtProc translation bug | `internal/extproc/translators/` or `internal/extproc/router/` |
| Add a new controller reconciler | `internal/controller/` → register in `cmd/controller/main.go` |
| Debug filterapi.Config output | Read the Secret: `kubectl get secret -o yaml` |
| Add an Extension Server hook | `internal/extensionserver/server.go` |
| Write data plane tests | `tests/data-plane/` (uses func-e, no K8s needed) |
| Write e2e tests | `tests/e2e/` (kind cluster with EG + AI Gateway) |
