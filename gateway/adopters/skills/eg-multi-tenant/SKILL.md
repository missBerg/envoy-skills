---
name: eg-multi-tenant
description: Set up Envoy Gateway for multi-tenant SaaS with namespace isolation, per-tenant gateways, and tenant-specific policies
---

# Envoy Gateway Multi-Tenant Setup

## Role

You set up Envoy Gateway for multi-tenant SaaS applications where each tenant needs traffic isolation. You guide the user through choosing the right deployment model, configuring tenant routing, and applying per-tenant security and rate limiting policies.

## Intake Interview

Before generating any configuration, ask the user these questions. Skip questions the user has already answered. Ask in a conversational tone, grouping related questions when it makes sense.

### Questions

1. **Tenant identification**: How do you identify tenants?
   - Subdomain: `tenant.example.com`
   - Path prefix: `/tenant-id/*`
   - Header: `X-Tenant-ID` or similar custom header

2. **Tenant count**: How many tenants do you expect?
   - Small (< 10) -- any deployment model works
   - Medium (10-100) -- shared Gateway with per-tenant routes is most practical
   - Large (100+) -- shared Gateway with automated route generation; dedicated Gateways only for premium tenants

3. **Isolation model**: Do tenants need separate Gateways (strongest isolation) or a shared Gateway with per-tenant routes?
   - Shared Gateway: single Envoy Proxy fleet, tenant routing by hostname or path, per-tenant SecurityPolicy
   - Dedicated Gateway per tenant: separate namespaces, separate Envoy Proxy fleet per tenant, strongest isolation
   - Gateway Namespace Mode (middle ground): shared controller, proxy deploys in tenant namespace

4. **Per-tenant rate limits**: Do you need per-tenant rate limits?
   - Same limits for all tenants
   - Different rate limit tiers per tenant (e.g., free vs. paid)
   - No rate limiting needed

5. **Authentication**: Do different tenants have different authentication requirements?
   - Same auth for all tenants (e.g., shared OIDC provider)
   - Per-tenant OIDC providers (each tenant has its own identity provider)
   - Per-tenant API keys
   - Mixed (some tenants use OIDC, others use API keys)

6. **Management model**: Should tenant configuration be managed by tenant admins (self-service) or centrally?
   - Central management: platform team owns all Gateway and Route configuration
   - Self-service: tenant admins create Routes in their own namespaces, platform team owns the Gateway
   - Hybrid: platform team owns Gateway and security baseline, tenants can customize Routes

## Workflow

### Phase 1: Choose Deployment Model

Based on the user's answers to the intake questions, recommend one of these deployment models and explain the tradeoffs.

#### Model A: Shared Gateway (simplest, fewest resources)

Best for: most multi-tenant deployments, especially with subdomain or path-based routing.

- Single GatewayClass and Gateway resource
- Tenant routing by hostname (subdomain) or path prefix
- Per-tenant SecurityPolicy attached to each tenant's HTTPRoute
- Per-tenant BackendTrafficPolicy for rate limits
- All tenants share one Envoy Proxy fleet and one external IP/load balancer
- Pros: simple, cost-effective, easy to manage
- Cons: blast radius -- a misconfiguration affects all tenants; shared resource limits

#### Model B: Dedicated Gateway per Tenant (strongest isolation)

Best for: regulated environments, premium tenants requiring SLA guarantees, compliance requirements.

- Separate namespace per tenant
- Separate Envoy Gateway controller per tenant (unique `controllerName` per Helm release)
- Each tenant gets its own GatewayClass, Gateway, and Envoy Proxy fleet
- Each tenant gets a dedicated external IP/load balancer
- Pros: full isolation, independent scaling, tenant-specific proxy tuning
- Cons: resource-intensive, more complex operations, one IP per tenant

```bash
# Install a dedicated controller for tenant "acme"
helm install eg-acme oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  -n tenant-acme \
  --create-namespace \
  --set config.envoyGateway.gateway.controllerName=gateway.envoyproxy.io/acme-controller
```

#### Model C: Gateway Namespace Mode (middle ground)

Best for: teams wanting proxy-level isolation without running separate controllers.

- Single Envoy Gateway controller
- Gateway resources created in each tenant's namespace
- Envoy Proxy pods deploy in the tenant's namespace (not the controller namespace)
- Tenants share the controller but have isolated proxy fleets
- Pros: proxy isolation, simpler than Model B, tenant admins can manage their own namespace
- Cons: shared control plane, slightly more complex than Model A

Enable in the EnvoyGateway configuration:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyGateway
provider:
  type: Kubernetes
  kubernetes:
    deploy:
      type: Namespace    # Proxy deploys in Gateway's namespace
```

### Phase 2: Install Envoy Gateway

Use the `/eg-install` skill with appropriate configuration for the chosen model.

For **Model A** (shared Gateway):
- Standard installation with production Helm values (replicas, resources, PDB)
- Single namespace for the controller

For **Model B** (dedicated per tenant):
- One Helm release per tenant with a unique `controllerName`
- Each release in its own namespace

For **Model C** (Gateway Namespace Mode):
- Standard installation with namespace deploy mode enabled
- Controller in `envoy-gateway-system`, proxies in tenant namespaces

### Phase 3: Create Tenant Namespace Structure and RBAC

Create namespaces for each tenant and configure RBAC so tenants can manage their own resources (if self-service model).

```yaml
# Tenant namespace
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-acme  # TODO: Replace with tenant name
  labels:
    tenant: acme
    gateway-access: "true"  # Used by allowedRoutes selector
---
# RBAC: Allow tenant admin to manage Routes in their namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-route-admin
  namespace: tenant-acme  # TODO: Replace with tenant namespace
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes", "grpcroutes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-acme-route-admin
  namespace: tenant-acme  # TODO: Replace with tenant namespace
subjects:
  - kind: Group
    name: tenant-acme-admins  # TODO: Replace with your tenant admin group
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: tenant-route-admin
  apiGroup: rbac.authorization.k8s.io
```

For cross-namespace routing (shared Gateway referencing backends in tenant namespaces), create a ReferenceGrant in each tenant namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-refs
  namespace: tenant-acme  # TODO: Replace with tenant namespace
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: gateway-system  # TODO: Namespace where the shared Gateway lives
  to:
    - group: ""
      kind: Service
```

### Phase 4: Configure Per-Tenant Routing

Use the `/eg-route` skill to create routes for each tenant. The approach depends on the tenant identification method.

#### Subdomain-based routing (tenant.example.com)

Configure the Gateway listener to accept wildcard hostnames, then create per-tenant HTTPRoutes with specific hostnames:

```yaml
# Gateway listener (accepts all tenant subdomains)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: multi-tenant-gw
  namespace: gateway-system  # TODO: Replace with your gateway namespace
spec:
  gatewayClassName: eg
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"  # TODO: Replace with your domain
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: wildcard-tls  # TODO: Wildcard cert for *.example.com
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
---
# Per-tenant HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-acme-route
  namespace: tenant-acme  # TODO: Replace with tenant namespace
  labels:
    tenant: acme
spec:
  parentRefs:
    - name: multi-tenant-gw
      namespace: gateway-system  # TODO: Replace with gateway namespace
  hostnames:
    - "acme.example.com"  # TODO: Replace with tenant subdomain
  rules:
    - backendRefs:
        - name: acme-app  # TODO: Replace with tenant backend service
          port: 8080
```

#### Path-based routing (/tenant-id/*)

```yaml
# Per-tenant HTTPRoute with path prefix
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-acme-route
  namespace: tenant-acme  # TODO: Replace with tenant namespace
  labels:
    tenant: acme
spec:
  parentRefs:
    - name: multi-tenant-gw
      namespace: gateway-system  # TODO: Replace with gateway namespace
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /acme  # TODO: Replace with tenant path prefix
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /  # Strip tenant prefix before forwarding to backend
      backendRefs:
        - name: acme-app  # TODO: Replace with tenant backend service
          port: 8080
```

#### Header-based routing (X-Tenant-ID)

```yaml
# Per-tenant HTTPRoute matching on header
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-acme-route
  namespace: tenant-acme  # TODO: Replace with tenant namespace
  labels:
    tenant: acme
spec:
  parentRefs:
    - name: multi-tenant-gw
      namespace: gateway-system  # TODO: Replace with gateway namespace
  rules:
    - matches:
        - headers:
            - name: X-Tenant-ID  # TODO: Replace with your tenant header
              value: acme         # TODO: Replace with tenant identifier
      backendRefs:
        - name: acme-app  # TODO: Replace with tenant backend service
          port: 8080
```

### Phase 5: Apply Per-Tenant Security Policies

Use the `/eg-auth` skill to create SecurityPolicy resources for each tenant. Attach them to the tenant's HTTPRoute so each tenant can have independent auth configuration.

```yaml
# Per-tenant SecurityPolicy (JWT example)
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: tenant-acme-auth
  namespace: tenant-acme  # TODO: Replace with tenant namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: tenant-acme-route  # TODO: Replace with tenant route name
  jwt:
    providers:
      - name: acme-jwt
        issuer: "https://acme.auth0.com/"  # TODO: Replace with tenant's JWT issuer
        remoteJWKS:
          uri: "https://acme.auth0.com/.well-known/jwks.json"  # TODO: Replace
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-tenant
        action: Allow
        principal:
          jwt:
            provider: acme-jwt
            claims:
              - name: tenant_id
                values: ["acme"]  # TODO: Replace with tenant identifier
```

For a baseline security policy that applies to all tenants at the Gateway level:

```yaml
# Gateway-level baseline SecurityPolicy
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: baseline-security
  namespace: gateway-system  # TODO: Replace with gateway namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: multi-tenant-gw
  cors:
    allowOrigins:
      - "https://*.example.com"  # TODO: Replace with your domain
    allowMethods:
      - GET
      - POST
      - PUT
      - DELETE
    allowHeaders:
      - Authorization
      - Content-Type
      - X-Tenant-ID
```

Note: A SecurityPolicy on a tenant's HTTPRoute overrides the Gateway-level policy for that tenant. The Gateway-level policy serves as a fallback for routes without their own SecurityPolicy.

### Phase 6: Apply Per-Tenant Rate Limits

Use the `/eg-rate-limit` skill to configure rate limits. For per-tenant rate limits, attach BackendTrafficPolicy to each tenant's HTTPRoute.

#### Same rate limit for all tenants

Attach to the Gateway so all routes inherit it:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: baseline-rate-limit
  namespace: gateway-system  # TODO: Replace with gateway namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: multi-tenant-gw
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 100
            unit: Second
```

#### Tiered rate limits per tenant

Attach different BackendTrafficPolicy to each tenant's HTTPRoute:

```yaml
# Premium tenant: higher rate limit
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: tenant-acme-rate-limit
  namespace: tenant-acme  # TODO: Replace with tenant namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: tenant-acme-route
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 1000  # TODO: Adjust per tenant tier
            unit: Second
---
# Free tenant: lower rate limit
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: tenant-free-rate-limit
  namespace: tenant-free  # TODO: Replace with tenant namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: tenant-free-route
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 10  # TODO: Adjust per tenant tier
            unit: Second
```

For global rate limits (shared across all Envoy replicas), use the `/eg-rate-limit` skill with `Type: global`. This requires a Redis deployment but ensures consistent rate limiting regardless of which Envoy replica handles the request.

### Phase 7: Configure Observability with Tenant Labels

Use the `/eg-observability` skill to set up access logging, metrics, and tracing. Ensure that tenant context is included in telemetry data for per-tenant monitoring.

Configure access logging to include tenant-identifying information:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: multi-tenant-proxy
  namespace: envoy-gateway-system
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: JSON
            json:
              start_time: "%START_TIME%"
              method: "%REQ(:METHOD)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              protocol: "%PROTOCOL%"
              response_code: "%RESPONSE_CODE%"
              duration: "%DURATION%"
              upstream_host: "%UPSTREAM_HOST%"
              # Tenant identification in logs
              tenant_host: "%REQ(:AUTHORITY)%"
              tenant_header: "%REQ(X-TENANT-ID)%"
          sinks:
            - type: File
              file:
                path: /dev/stdout
    metrics:
      sinks:
        - type: OpenTelemetry
          openTelemetry:
            host: otel-collector.observability.svc.cluster.local  # TODO: Replace
            port: 4317
      enableVirtualHostStats: true  # Per-vhost metrics help track per-tenant traffic
    tracing:
      provider:
        host: otel-collector.observability.svc.cluster.local  # TODO: Replace
        port: 4317
        type: OpenTelemetry
      samplingRate: 10  # TODO: Adjust sampling rate (1-100)
      customTags:
        tenant:
          type: RequestHeader
          requestHeader:
            name: X-Tenant-ID
            defaultValue: "unknown"
```

Attach the EnvoyProxy configuration to the GatewayClass or Gateway via `parametersRef`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: multi-tenant-proxy
    namespace: envoy-gateway-system
```

## Output Requirements

Generate a complete set of Kubernetes manifests organized by concern:

1. Envoy Gateway installation (Helm command or values file)
2. Tenant namespaces with labels
3. RBAC (Roles, RoleBindings) for tenant self-service
4. GatewayClass and Gateway with multi-tenant listener configuration
5. ReferenceGrants for cross-namespace routing
6. Per-tenant HTTPRoutes
7. Per-tenant SecurityPolicy resources
8. Per-tenant BackendTrafficPolicy (rate limits)
9. EnvoyProxy telemetry configuration with tenant context
10. Verification commands to confirm each tenant's traffic flows correctly

## Guidelines

- Always pin the Envoy Gateway Helm chart version explicitly (default: `v1.7.0`).
- Use `gateway.networking.k8s.io/v1` for Gateway API resources and `gateway.envoyproxy.io/v1alpha1` for Envoy Gateway extension CRDs.
- Use kebab-case for all resource names. Include the tenant name in resource names for clarity (e.g., `tenant-acme-route`).
- Include TODO comments in YAML for values the user must customize.
- Label all tenant resources consistently with `tenant: <name>` for easy filtering.
- For the self-service model, restrict tenant RBAC to Routes and Services only -- tenants should not create Gateways, GatewayClasses, or cluster-scoped resources.
- When tenant count is large (100+), recommend automation for route and policy generation (e.g., a controller or CI/CD pipeline that generates per-tenant manifests).
