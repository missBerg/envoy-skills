---
name: eg-route
description: Create routing rules for HTTP, gRPC, TCP, or UDP traffic
arguments:
  - name: Type
    description: "Route type: http, grpc, tcp, udp, tls (default: http)"
    required: false
  - name: Hostname
    description: "Hostname to match (e.g., api.example.com)"
    required: false
---

Create a Route resource that binds to a Gateway and defines how traffic is forwarded to backend Services. This skill generates HTTPRoute, GRPCRoute, TCPRoute, UDPRoute, or TLSRoute resources with appropriate matching rules, filters, and backend references.

## Instructions

### Step 1: Set variables

Determine the route type and hostname. If the user did not provide values, use these defaults:

- **Type**: `http`
- **Hostname**: none (matches all hostnames on the attached listener)

### Step 2: Generate the Route resource

Select the appropriate template based on the `Type` argument.

---

#### HTTPRoute

HTTPRoute is the most feature-rich route type. It supports path matching, header matching, method matching, weighted backends, header modification, URL rewrites, and redirects.

##### Basic HTTPRoute with path matching

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${Hostname}-route       # TODO: Choose a descriptive name
  namespace: default            # TODO: Set the Route's namespace
spec:
  parentRefs:
    - name: eg                  # TODO: Name of the Gateway to attach to
      # sectionName: https      # Optional: attach to a specific listener by name
  hostnames:
    - "${Hostname}"             # TODO: Set hostname or remove for catch-all
  rules:
    # Rule 1: Exact path match
    - matches:
        - path:
            type: Exact
            value: /healthz
      backendRefs:
        - name: health-service  # TODO: Backend Service name
          port: 8080            # TODO: Backend Service port

    # Rule 2: Path prefix match (most common)
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1
      backendRefs:
        - name: api-service     # TODO: Backend Service name
          port: 8080

    # Rule 3: Catch-all (lowest priority)
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend        # TODO: Backend Service name
          port: 3000
```

##### Header and method matching

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: advanced-matching
  namespace: default
spec:
  parentRefs:
    - name: eg
  hostnames:
    - "${Hostname}"
  rules:
    # Match on header value (exact match)
    - matches:
        - headers:
            - type: Exact
              name: x-api-version
              value: "v2"
          path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: api-v2
          port: 8080

    # Match on HTTP method
    - matches:
        - method: POST
          path:
            type: PathPrefix
            value: /webhooks
      backendRefs:
        - name: webhook-handler
          port: 8080

    # Multiple match conditions are OR'd.
    # Within a single match, all fields are AND'd.
```

##### Weighted backend splitting (canary deployments)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: canary-route
  namespace: default
spec:
  parentRefs:
    - name: eg
  hostnames:
    - "${Hostname}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        # 90% of traffic to the stable version
        - group: ""
          kind: Service
          name: app-stable       # TODO: Stable backend Service
          port: 8080
          weight: 90
        # 10% of traffic to the canary version
        - group: ""
          kind: Service
          name: app-canary       # TODO: Canary backend Service
          port: 8080
          weight: 10
```

> **Weight semantics**: Weights are proportional, not percentages. A split of `weight: 9` / `weight: 1` is equivalent to 90%/10%. The sum does not need to equal 100.

##### Request and response header modification

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: header-mod-route
  namespace: default
spec:
  parentRefs:
    - name: eg
  hostnames:
    - "${Hostname}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        # Add or set request headers before forwarding to the backend
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: X-Request-Source
                value: envoy-gateway
            set:
              - name: X-Forwarded-Proto
                value: https
            remove:
              - X-Internal-Debug

        # Modify response headers before sending back to the client
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            add:
              - name: X-Powered-By
                value: envoy
            remove:
              - Server
      backendRefs:
        - name: backend
          port: 8080
```

##### URL rewrite

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rewrite-route
  namespace: default
spec:
  parentRefs:
    - name: eg
  hostnames:
    - "${Hostname}"
  rules:
    # Rewrite path prefix: /api/v1/* -> /v1/*
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /v1
      backendRefs:
        - name: api-service
          port: 8080

    # Rewrite hostname
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: internal-api.cluster.local
      backendRefs:
        - name: api-service
          port: 8080
```

##### HTTP redirect (e.g., HTTP to HTTPS)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: default
spec:
  parentRefs:
    - name: eg
      sectionName: http       # Attach to the HTTP listener specifically
  hostnames:
    - "${Hostname}"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https     # Redirect HTTP -> HTTPS
            statusCode: 301   # Permanent redirect (default is 302)
      # No backendRefs needed for redirects
```

---

#### GRPCRoute

GRPCRoute provides native gRPC routing with service and method matching. It requires an HTTP/2 capable listener (HTTPS or HTTP).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: grpc-route
  namespace: default
spec:
  parentRefs:
    - name: eg
  hostnames:
    - "grpc.${Hostname}"        # TODO: Set gRPC hostname
  rules:
    # Match a specific service and method (Exact match is the default)
    - matches:
        - method:
            service: com.example.UserService
            method: GetUser
      backendRefs:
        - name: user-service    # TODO: gRPC backend Service
          port: 50051

    # Match all methods on a service
    - matches:
        - method:
            service: com.example.OrderService
      backendRefs:
        - name: order-service
          port: 50051

    # Match using RegularExpression
    - matches:
        - method:
            service: "com\\.example\\..*"
            method: "Health.*"
            type: RegularExpression
      backendRefs:
        - name: health-service
          port: 50051

    # Match with header (e.g., canary routing)
    - matches:
        - headers:
            - type: Exact
              name: env
              value: canary
      backendRefs:
        - name: canary-service
          port: 50051
```

> **Note**: GRPCRoute and HTTPRoute must not share the same hostname on a Gateway. Use separate hostnames for gRPC and HTTP traffic (e.g., `grpc.example.com` vs `api.example.com`).

---

#### TCPRoute

TCPRoute forwards raw TCP streams. There is no application-layer routing -- each listener port maps to exactly one TCPRoute.

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata:
  name: tcp-route
  namespace: default
spec:
  parentRefs:
    - name: eg
      sectionName: tcp         # TODO: Name of the TCP listener on the Gateway
  rules:
    - backendRefs:
        - name: database-service  # TODO: TCP backend Service
          port: 5432              # TODO: Backend port (e.g., PostgreSQL)
```

> **One route per listener**: Because TCP has no routing discriminator, only one TCPRoute can attach to a given listener. Use separate listeners (with different ports) for different TCP services.

---

#### UDPRoute

UDPRoute forwards raw UDP datagrams. Like TCPRoute, each listener port maps to exactly one UDPRoute.

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: UDPRoute
metadata:
  name: udp-route
  namespace: default
spec:
  parentRefs:
    - name: eg
      sectionName: udp         # TODO: Name of the UDP listener on the Gateway
  rules:
    - backendRefs:
        - name: dns-service     # TODO: UDP backend Service
          port: 53              # TODO: Backend port (e.g., DNS)
```

> **Non-transparent proxying**: UDP (and TCP) routing operates in non-transparent mode. The backend sees the Envoy proxy's IP as the source, not the original client IP.

---

#### TLSRoute

TLSRoute is used with TLS Passthrough listeners. The Gateway forwards the encrypted TLS stream to the backend based on SNI without terminating TLS.

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: tls-passthrough-route
  namespace: default
spec:
  parentRefs:
    - name: eg
      sectionName: tls-passthrough  # TODO: Name of the TLS Passthrough listener
  hostnames:
    - "secure.${Hostname}"          # SNI hostname for matching
  rules:
    - backendRefs:
        - name: secure-backend      # TODO: Backend Service that handles its own TLS
          port: 443
```

### Step 3: Cross-namespace routing

If a Route needs to reference a backend Service in a different namespace, create a ReferenceGrant in the Service's namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-route-to-backend
  namespace: backend-namespace  # TODO: Namespace where the Service lives
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute           # TODO: Match the Route kind (HTTPRoute, GRPCRoute, etc.)
      namespace: default        # TODO: Namespace where the Route lives
  to:
    - group: ""
      kind: Service
```

Then reference the backend with an explicit namespace:

```yaml
backendRefs:
  - name: my-service
    namespace: backend-namespace
    port: 8080
```

### Step 4: Apply and verify

```bash
kubectl apply -f route.yaml
```

Check the Route status. It should show `Accepted: True` and reference the parent Gateway:

```bash
kubectl get httproute ${Name}-route -o yaml    # or grpcroute, tcproute, etc.
```

Test connectivity:

```bash
export GATEWAY_HOST=$(kubectl get gateway/eg -o jsonpath='{.status.addresses[0].value}')

# For HTTPRoute
curl --verbose --header "Host: ${Hostname}" http://$GATEWAY_HOST/

# For GRPCRoute
grpcurl -plaintext -authority=grpc.${Hostname} $GATEWAY_HOST:80 com.example.UserService/GetUser
```

## Checklist

- [ ] Route resource is created with the correct `apiVersion` for the route type
- [ ] `parentRefs` correctly references the Gateway (and optionally a specific `sectionName`)
- [ ] Hostname is set to match the intended domain (or omitted for catch-all)
- [ ] Path matching uses the appropriate type (Exact, PathPrefix, or RegularExpression)
- [ ] Backend Service names and ports are correct and Services exist
- [ ] For canary deployments: weights are set and sum to the desired ratio
- [ ] For cross-namespace routing: ReferenceGrant is in place in the backend's namespace
- [ ] Route status shows `Accepted: True` with a valid `parentRef`
- [ ] Traffic reaches the backend Service through the Gateway
