---
name: eg-nginx-capability-map
description: Reference mapping ingress-nginx annotations and behaviors to Envoy Gateway resources and patterns
---

# ingress-nginx to Envoy Gateway Capability Mapping

Reference for mapping ingress-nginx annotations and behaviors to Envoy Gateway resources. Use this when converting Ingress manifests or when `eg-nginx-analyze` flags unclear mappings.

## Mapping Table

| ingress-nginx | Envoy Gateway | Skill / Resource | Notes |
|---------------|---------------|------------------|-------|
| **Authentication & Authorization** |
| `auth-type`, `auth-secret`, `auth-realm` | SecurityPolicy `basic` | eg-auth | Basic auth; secret format may differ |
| `auth-tls-*` (client cert) | SecurityPolicy `jwt` or custom | eg-auth | Client cert auth; different setup |
| `auth-url`, `auth-cache-*` | SecurityPolicy `extAuth` | eg-auth | External auth service (ExtAuth gRPC/HTTP) |
| OIDC (via auth-url) | SecurityPolicy `oidc` | eg-auth | Native OIDC preferred |
| **IP & Access Control** |
| `whitelist-source-range` | SecurityPolicy `ipAllowList` | eg-auth, eg-security-guide | IP allow list |
| **Rate Limiting** |
| `limit-rps` | BackendTrafficPolicy `rateLimit.local` | eg-rate-limit | Requests per second |
| `limit-connections` | BackendTrafficPolicy `rateLimit.local` | eg-rate-limit | Connection limit; map to request limit |
| **CORS** |
| `enable-cors`, `cors-allow-origin`, `cors-allow-methods`, etc. | BackendTrafficPolicy or ClientTrafficPolicy | eg-backend-policy | CORS via policy; structure differs |
| **Session Affinity** |
| `affinity`, `affinity-mode`, `affinity-canary-behavior` | BackendTrafficPolicy `loadBalancer.consistentHash` | eg-backend-policy | Use `type: Cookie` or `type: Header` |
| **Canary / Traffic Splitting** |
| `canary`, `canary-by-header`, `canary-by-cookie` | HTTPRoute with header/cookie match + multiple backends | eg-route | Split backends by match |
| `canary-weight` | HTTPRoute `weight` in backendRefs | eg-route | Weighted traffic split |
| **Redirects** |
| `force-ssl-redirect` | HTTPRoute `filters[].type: RequestRedirect` | eg-route, eg-tls | Redirect HTTP→HTTPS |
| `permanent-redirect`, `temporal-redirect` | HTTPRoute `RequestRedirect` | eg-route | 301/302 redirect |
| **TLS** |
| `spec.tls` + cert-manager | Gateway listener + cert-manager | eg-tls | Same pattern; use TLSRoute or HTTPRoute |
| `backend-protocol: HTTPS` | BackendTLSPolicy | eg-backend-policy | TLS to backend |
| **Backend & Load Balancing** |
| Default round-robin | BackendTrafficPolicy `loadBalancer.type: RoundRobin` | eg-backend-policy | Explicit if needed |
| `upstream-hash-by` | BackendTrafficPolicy `loadBalancer.consistentHash` | eg-backend-policy | Hash by header/source IP |
| **Request/Response** |
| `proxy-body-size`, `client-body-buffer-size` | ClientTrafficPolicy or Envoy config | eg-client-policy | Body size limits |
| `configuration-snippet`, `server-snippet` | EnvoyExtensionPolicy or EnvoyPatchPolicy | eg-extension | ⚠️ No direct map; manual Envoy config |
| **gRPC** |
| `backend-protocol: GRPC` + path | GRPCRoute | eg-route | Native GRPCRoute preferred |

## Direct vs. Workaround vs. Unsupported

### Direct equivalent
- `whitelist-source-range` → SecurityPolicy `ipAllowList`
- `limit-rps` → BackendTrafficPolicy `rateLimit.local`
- `force-ssl-redirect` → HTTPRoute `RequestRedirect`
- `affinity` (cookie) → BackendTrafficPolicy `loadBalancer.consistentHash` (Cookie)
- `canary-weight` → HTTPRoute backendRef `weight`

### Workaround required
- `auth-url` → ExtAuth; ensure ExtAuth service is compatible
- `limit-connections` → Map to request-based limit or connection limit in Envoy config
- `cors-*` → Build CORS policy from multiple annotations into one BackendTrafficPolicy

### Unsupported or manual
- `configuration-snippet`, `server-snippet` → EnvoyExtensionPolicy with raw Envoy config; test carefully
- Lua scripts → Envoy Lua filter or alternative design
- NGINX-specific modules → No direct port

## Conversion Tools

- **ingress2gateway**: Converts Ingress → Gateway + HTTPRoute. Does not convert NGINX annotations. Use for structure, then add policies manually.
- **ingress2eg**: Converts Ingress + many NGINX annotations → Gateway API + Envoy Gateway CRDs. Covers 16+ annotation categories. Use for automated conversion, then validate output.

## Related Skills

- **eg-auth** — JWT, OIDC, Basic, ExtAuth, API keys
- **eg-rate-limit** — Local and global rate limiting
- **eg-backend-policy** — Load balancing, retries, health checks, session affinity
- **eg-client-policy** — Timeouts, connection limits, CORS
- **eg-tls** — TLS termination, cert-manager
- **eg-route** — HTTPRoute, GRPCRoute, redirects, weighted backends
- **eg-extension** — EnvoyExtensionPolicy for custom config

## Validation Checklist

- [ ] Annotation mapped to correct Envoy Gateway resource
- [ ] Direct / workaround / unsupported status noted
- [ ] Related skill referenced for implementation details
- [ ] Conversion tools (ingress2gateway, ingress2eg) mentioned where applicable
