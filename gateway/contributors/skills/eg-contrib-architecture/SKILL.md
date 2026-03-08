---
name: eg-contrib-architecture
description: Envoy Gateway codebase architecture — translation pipeline, directory layout, runner pattern, and key types for navigating the envoyproxy/gateway repository
---

# Envoy Gateway Architecture

## Translation Pipeline

```
Gateway API CRDs
  │
  ▼
┌──────────────────────┐
│  Kubernetes Provider  │  Watches Gateway API + EG resources via informers
│  (providerrunner)     │  Publishes: ProviderResources
└──────────┬───────────┘
           │  watchable.Map subscription
           ▼
┌──────────────────────┐
│  GatewayAPI Translator│  Translates CRDs → IR, computes resource status
│  (gatewayapirunner)   │  Publishes: XdsIR, InfraIR
└──────────┬───────────┘
           │  watchable.Map subscription
     ┌─────┴──────┐
     ▼            ▼
┌─────────┐  ┌──────────────┐
│ xDS     │  │ Infra Manager │
│ Server  │  │ (infrarunner) │
│(xdsrun) │  └──────────────┘
└─────────┘     Manages Deployments,
  Serves xDS    Services, ConfigMaps
  to Envoy      for Envoy data plane
```

## Directory Map

| Directory | Responsibility | Key Files |
|-----------|---------------|-----------|
| `api/v1alpha1/` | CRD type definitions (EnvoyProxy, policies, Backend) | `*_types.go`, `shared_types.go`, `validation/` |
| `internal/gatewayapi/` | Gateway API → IR translation (the brain of EG) | `translator.go`, `backendtrafficpolicy.go`, `securitypolicy.go` |
| `internal/gatewayapi/resource/` | Resource context wrappers and helpers | `resource.go` |
| `internal/gatewayapi/status/` | Status condition computation | `gateway.go`, `httproute.go` |
| `internal/gatewayapi/testdata/` | Golden test files for translator (~1000+ files) | `*.in.yaml`, `*.out.yaml` |
| `internal/ir/` | Intermediate Representation types | `xds.go` (~3500 lines), `infra.go` |
| `internal/xds/translator/` | IR → xDS translation (58+ files, one per feature) | `translator.go`, `httpfilters.go`, `cluster.go` |
| `internal/xds/translator/testdata/` | Golden test files for xDS translator | `in/xds-ir/*.yaml`, `out/xds-ir/*.yaml` |
| `internal/xds/bootstrap/` | Envoy bootstrap configuration generation | `bootstrap.go` |
| `internal/xds/server/` | xDS gRPC server (delta xDS) | `server.go` |
| `internal/xds/cache/` | xDS snapshot cache | `snapshotcache.go` |
| `internal/provider/kubernetes/` | Kubernetes resource watchers and controllers | `controller.go`, `predicates.go` |
| `internal/infrastructure/kubernetes/` | Data plane infrastructure management | `proxy.go`, `proxy_deployment.go` |
| `internal/message/` | Watchable Map message bus between runners | `types.go` |
| `internal/extension/` | Extension system (gRPC hooks for xDS modification) | `types/manager.go` |
| `internal/cmd/` | CLI entry points and server startup | `server.go` |
| `test/e2e/` | End-to-end tests against live K8s cluster | `tests/*.go`, `testdata/*.yaml` |
| `test/conformance/` | Gateway API conformance test suite | `conformance_test.go` |
| `test/cel-validation/` | CEL validation rule tests for CRDs | `*_test.go` |
| `charts/gateway-helm/` | Helm chart for deploying Envoy Gateway | `values.yaml`, `crds/generated/` |
| `site/content/en/contributions/design/` | Design documents (25+ docs) | `system-design.md`, `gatewayapi-translator.md` |

## Runner Pattern

Envoy Gateway uses concurrent runners connected via `watchable.Map` (from `github.com/telepresenceio/watchable`). Each runner subscribes to upstream maps and publishes to downstream maps.

| Runner | Package | Subscribes To | Publishes |
|--------|---------|---------------|-----------|
| **providerrunner** | `internal/provider/runner` | Kubernetes API (informers) | `ProviderResources` (Gateway API + EG resources) |
| **gatewayapirunner** | `internal/gatewayapi/runner` | `ProviderResources` | `XdsIR`, `InfraIR`, status updates |
| **xdsrunner** | `internal/xds/runner` | `XdsIR` | xDS snapshots to gRPC server |
| **infrarunner** | `internal/infrastructure/runner` | `InfraIR` | K8s Deployments, Services, ConfigMaps |
| **ratelimitrunner** | `internal/globalratelimit/runner` | `XdsIR` | Rate limit service config |

### How Watchable Map Works

- `watchable.Map[K, V]` is a thread-safe map with pub/sub semantics
- Publishers call `Store(key, value)` to update entries
- Subscribers call `Subscribe(ctx)` to get a channel of updates
- Updates are coalesced — multiple rapid mutations trigger a single subscriber notification
- `DeepEqual` is used to detect changes — this is why IR types must use slices instead of maps (maps have non-deterministic iteration order, causing false-positive diffs)

**Critical rule**: Never use `map` types in IR structs. Use `[]MapEntry` slices instead. Map iteration order is non-deterministic, which causes `DeepEqual` to produce spurious diffs and unnecessary xDS updates to Envoy.

## Key Types

### TranslatorManager Interface

```go
// internal/gatewayapi/translator.go
type TranslatorManager interface {
    Translate(resources *resource.Resources) (*TranslateResult, error)
    GetRelevantGateways(resources *resource.Resources) (acceptedGateways, failedGateways []*GatewayContext)
    RoutesTranslator
    ListenersTranslator
    AddressesTranslator
    FiltersTranslator
}
```

### Translation Input and Output

- **Input**: `resource.Resources` — all Gateway API and EG resources from the provider
- **Output**: `TranslateResult` containing:
  - `[]*GatewayContext` — gateways with computed status
  - `map[string]*ir.Xds` — xDS IR keyed by gateway name
  - `map[string]*ir.Infra` — infra IR keyed by gateway name

### IR Types (internal/ir/)

- `ir.Xds` — complete xDS intermediate representation for one gateway
  - `HTTPListeners` — listeners with HTTP filter chain config
  - `TCPListeners`, `UDPListeners` — L4 listeners
  - `TLS` — TLS certificates and settings
- `ir.Infra` — infrastructure definition for one gateway
  - `Proxy` — Envoy proxy deployment spec (replicas, resources, volumes)

### Message Bus Types (internal/message/)

- `ProviderResources` — wraps `watchable.Map[string, *resource.ControllerResourcesContext]`
- `XdsIR` — wraps `watchable.Map[string, *XdsIRWithContext]`
- `InfraIR` — wraps `watchable.Map[string, *ir.Infra]`

## Gateway API to Envoy Concept Mapping

| Gateway API | Envoy xDS | Notes |
|------------|-----------|-------|
| Gateway Listener | Envoy Listener | One listener per port/protocol combo |
| HTTPRoute | Virtual Host + Route entries | Routes grouped by hostname into virtual hosts |
| GRPCRoute | Virtual Host + Route (gRPC match) | Uses gRPC-specific route matching |
| TLSRoute | Listener filter chain (SNI match) | TLS passthrough, no HTTP processing |
| TCPRoute | TCP Proxy network filter | L4 routing, no HTTP awareness |
| UDPRoute | UDP Proxy listener filter | L4 UDP routing |
| BackendRef (Service) | Cluster + ClusterLoadAssignment | Cluster = upstream definition, CLA = endpoints |
| SecurityPolicy (JWT) | JWT authn HTTP filter | Added to the downstream HTTP filter chain |
| SecurityPolicy (ExtAuth) | Ext authz HTTP filter | Each route gets its own filter instance |
| BackendTrafficPolicy | Cluster settings | Circuit breaking, retries, health checks, load balancing |
| ClientTrafficPolicy | Listener/HCM settings | Timeouts, connection limits, HTTP/2 settings |
| EnvoyExtensionPolicy | Custom HTTP filters | Wasm, ExtProc, Lua, Dynamic Modules |
| EnvoyPatchPolicy | Direct xDS patch | Escape hatch for unsupported Envoy features |

## Translation Order

The GatewayAPI translator processes resources in this order (from `translator.go`):

1. **Index resources** — build lookup maps for Namespaces, Services, Secrets, ConfigMaps, etc.
2. **Get relevant Gateways** — filter by GatewayClass, validate EnvoyProxy refs
3. **Initialize IRs** — create empty xDS IR and Infra IR per gateway
4. **Process Listeners** — validate compatibility, compute listener status
5. **Process Addresses** — compute service addresses for load balancing
6. **Process Routes** — HTTPRoute, GRPCRoute, TLSRoute, TCPRoute, UDPRoute
7. **Process Policies** — ClientTrafficPolicy, BackendTrafficPolicy, SecurityPolicy, EnvoyExtensionPolicy
8. **Process EnvoyPatchPolicy** — direct xDS patches (if enabled)
9. **Sort and finalize** — sort xDS IR for deterministic output, set filter order

## Entry Points for Common Tasks

| Task | Start Here |
|------|-----------|
| Add a new policy field | `api/v1alpha1/` → `internal/gatewayapi/` → `internal/ir/xds.go` → `internal/xds/translator/` |
| Fix a translation bug | `internal/gatewayapi/` or `internal/xds/translator/` (check golden test diffs) |
| Add a new HTTP filter | `internal/xds/translator/httpfilters.go` (register + set order) |
| Modify data plane infra | `internal/infrastructure/kubernetes/` |
| Add a new resource watch | `internal/provider/kubernetes/controller.go` |
| Debug xDS output | Use `egctl x translate --from gateway-api --to xds` |
| Understand a feature's flow | Trace from the CRD type → gatewayapi translator → IR → xDS translator |
