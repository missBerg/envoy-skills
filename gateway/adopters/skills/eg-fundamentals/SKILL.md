---
name: eg-fundamentals
description: Envoy Gateway fundamentals — Gateway API resources, CRD relationships, naming conventions, and resource hierarchy
---

# Envoy Gateway Fundamentals

## Resource Hierarchy

```
GatewayClass          # Defines controller (e.g., gateway.envoyproxy.io/gatewayclass-controller)
  -> Gateway          # Binds listeners (ports/protocols) to a GatewayClass
    -> Routes         # Match traffic and direct to backends
      -> BackendRefs  # Target Services (or Backend CRDs)
```

### Route Types
- **HTTPRoute** — HTTP/HTTPS routing with path, header, query param matching
- **GRPCRoute** — gRPC routing with service/method matching
- **TLSRoute** — TLS passthrough routing (SNI-based)
- **TCPRoute** — Raw TCP routing
- **UDPRoute** — Raw UDP routing

### API Versions
- Gateway API resources: `gateway.networking.k8s.io/v1`
- Envoy Gateway CRDs: `gateway.envoyproxy.io/v1alpha1`

## Envoy Gateway Extension CRDs

| CRD | Purpose | Attaches To |
|-----|---------|-------------|
| **EnvoyProxy** | Customize Envoy Proxy deployment (replicas, resources, bootstrap, extra volumes) | GatewayClass or Gateway via `parametersRef` |
| **ClientTrafficPolicy** | Client-facing settings: rate limiting, client TLS validation, timeouts, HTTP/2 settings, connection limits | Gateway |
| **BackendTrafficPolicy** | Backend-facing settings: load balancing, health checks, retries, circuit breaking, connection pools, TCP keepalive | Gateway, Route |
| **SecurityPolicy** | Authentication (JWT, OIDC, Basic Auth, API Key, ExtAuth), authorization, CORS | Gateway, Route |
| **EnvoyExtensionPolicy** | Data plane extensions: Wasm filters, External Processing (ExtProc), Lua scripts | Gateway, Route, Backend |
| **EnvoyPatchPolicy** | Direct xDS patching for cases not covered by higher-level CRDs | N/A (targets xDS directly) |
| **Backend** | Route to external endpoints: FQDN, IP address, or Unix Domain Sockets outside the cluster | Referenced in Route `backendRefs` |
| **HTTPRouteFilter** | Reusable request/response transformations (header modification, URL rewrite, mirrors) | Referenced in HTTPRoute filter chains |

## Policy Attachment Model

- Policies attach to Gateway or Route resources via `targetRef`
- **Most-specific wins**: a policy on a Route overrides the same policy type on the parent Gateway
- A policy on a Gateway applies to all Routes under that Gateway unless overridden
- Only one policy of a given type can target the same resource

## Naming and Structural Conventions

- Use **kebab-case** for all resource names (`my-gateway`, `api-route`, `backend-policy`)
- Resources are **namespace-scoped** unless explicitly cluster-scoped (GatewayClass is cluster-scoped)
- Gateway listeners must have **unique protocol/port combinations** within the same Gateway
- BackendRefs can reference Services in **other namespaces only with a ReferenceGrant** in the target namespace
- Label resources consistently for filtering (e.g., `app.kubernetes.io/name`, `app.kubernetes.io/component`)

## Common targetRef Pattern

```yaml
targetRef:
  group: gateway.networking.k8s.io
  kind: Gateway          # or HTTPRoute, GRPCRoute, etc.
  name: my-gateway
```

For BackendTrafficPolicy targeting a route:
```yaml
targetRef:
  group: gateway.networking.k8s.io
  kind: HTTPRoute
  name: my-route
```
