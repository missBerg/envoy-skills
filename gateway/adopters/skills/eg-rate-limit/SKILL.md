---
name: eg-rate-limit
description: Configure local and global rate limiting to protect services from overload
arguments:
  - name: Type
    description: "Rate limit type: local or global (default: local)"
    required: false
  - name: Rate
    description: "Rate limit value (e.g., 100/second, 1000/minute)"
    required: false
---

Configure rate limiting for Envoy Gateway using BackendTrafficPolicy. Rate limits protect backend
services from overload, prevent abuse, and enforce usage quotas. Envoy Gateway supports local
(per-instance) and global (shared across all instances) rate limiting, and both can be used simultaneously.

Important: Rate limits are applied per route, even if the BackendTrafficPolicy targets a Gateway.
For example, if the limit is 100r/s and a Gateway has 3 routes, each route has its own 100r/s bucket.

## Instructions

### Step 1: Choose rate limiting type

**Local rate limiting** (default) -- Independent limits per Envoy Proxy instance. No external
dependencies. If you have 3 Envoy replicas with a 100r/s local limit, the effective cluster-wide
limit is up to 300r/s.

**Global rate limiting** -- Shared limits across all Envoy Proxy instances via an external rate limit
service backed by Redis. If you set a 100r/s global limit, that limit applies regardless of how many
Envoy replicas exist. Requires Redis deployment.

**Combined** -- Use both local and global limits. Local limits act as a first line of defense to block
bursts quickly, while global limits enforce the true shared quota. A request must pass both checks.

---

### Step 2a: Configure local rate limiting

Local rate limiting requires no external services. Limits are enforced independently at each Envoy
Proxy instance.

**Rate limit all requests on a route:**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: local-ratelimit  # TODO: Replace with a descriptive name
  namespace: <namespace>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace with your HTTPRoute name
  rateLimit:
    local:
      rules:
        - limit:
            requests: 50  # TODO: Adjust to your desired rate per instance
            unit: Minute  # Options: Second, Minute, Hour
```

**Rate limit with client selectors** (match specific headers):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: local-ratelimit-by-header
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  rateLimit:
    local:
      rules:
        - clientSelectors:
            - headers:
                - name: x-user-tier  # TODO: Replace with the header to match
                  value: free  # TODO: Replace with the header value to match
          limit:
            requests: 10
            unit: Minute
        - clientSelectors:
            - headers:
                - name: x-user-tier
                  value: premium
          limit:
            requests: 1000
            unit: Minute
        # Fallback rule for requests not matching any selector above:
        - limit:
            requests: 50
            unit: Minute
```

**Apply to a Gateway** (each route gets its own independent limit bucket):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: gateway-local-ratelimit
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <gateway-name>  # TODO: Replace with your Gateway name
  rateLimit:
    local:
      rules:
        - limit:
            requests: 100
            unit: Second
```

Note: Local rate limiting does not support `distinct` matching (e.g., per-client-IP bucketing).
Use global rate limiting for distinct value-based rate limits.

---

### Step 2b: Configure global rate limiting

Global rate limiting enforces shared limits across all Envoy Proxy instances. It requires deploying
Redis and configuring the Envoy Gateway rate limit service.

#### Deploy Redis

```yaml
kind: Namespace
apiVersion: v1
metadata:
  name: redis-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: redis-system
  labels:
    app: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - image: redis:6.0.6  # TODO: Use a version appropriate for your environment
          imagePullPolicy: IfNotPresent
          name: redis
          resources:
            limits:
              cpu: 1500m
              memory: 512Mi
            requests:
              cpu: 200m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: redis-system
  labels:
    app: redis
spec:
  ports:
    - name: redis
      port: 6379
      protocol: TCP
      targetPort: 6379
  selector:
    app: redis
```

#### Configure Envoy Gateway to use Redis

Update the EnvoyGateway configuration to point at Redis. If you installed Envoy Gateway with Helm,
use `helm upgrade`:

```bash
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
  --set config.envoyGateway.rateLimit.backend.type=Redis \
  --set config.envoyGateway.rateLimit.backend.redis.url="redis.redis-system.svc.cluster.local:6379" \
  --reuse-values \
  -n envoy-gateway-system
```

Or update the ConfigMap directly:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-gateway-config
  namespace: envoy-gateway-system
data:
  envoy-gateway.yaml: |
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyGateway
    # ... keep existing configuration ...
    rateLimit:
      backend:
        type: Redis
        redis:
          url: redis.redis-system.svc.cluster.local:6379
          # For TLS connections to Redis:
          # tls:
          #   certificateRef:
          #     name: redis-tls-cert
```

After updating the ConfigMap, restart the Envoy Gateway deployment:

```bash
kubectl rollout restart deployment envoy-gateway -n envoy-gateway-system
```

#### Create global rate limit policy

**Rate limit all requests on a route (shared across all instances):**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: global-ratelimit  # TODO: Replace with a descriptive name
  namespace: <namespace>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  rateLimit:
    global:
      rules:
        - limit:
            requests: 100  # TODO: Adjust -- this limit is shared across ALL Envoy instances
            unit: Minute  # Options: Second, Minute, Hour
```

**Header-based rate limiting** (e.g., per API key or per user):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: global-ratelimit-per-key
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  rateLimit:
    global:
      rules:
        - clientSelectors:
            - headers:
                - name: x-api-key  # TODO: Replace with the header to rate limit on
                  type: Distinct  # Each unique header value gets its own rate limit bucket
          limit:
            requests: 100
            unit: Minute
```

**Source IP-based rate limiting:**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: global-ratelimit-per-ip
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  rateLimit:
    global:
      rules:
        - clientSelectors:
            - sourceCIDR:
                type: Distinct  # Each unique source IP gets its own bucket
                value: 0.0.0.0/0  # Match all IPs
          limit:
            requests: 50
            unit: Minute
```

---

### Step 2c: Combine local and global rate limiting

Use both local and global limits simultaneously for layered protection. Local limits fire first to
block bursts cheaply, then global limits enforce the true shared quota.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: combined-ratelimit
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route-name>  # TODO: Replace
  rateLimit:
    local:
      rules:
        - limit:
            requests: 50  # Per Envoy instance -- absorbs burst traffic locally
            unit: Second
    global:
      rules:
        - limit:
            requests: 100  # Shared across all instances -- enforces total quota
            unit: Second
```

How combined evaluation works:
1. Local rate limits are evaluated first at each Envoy instance.
2. Global rate limits are then evaluated using the shared rate limit service.
3. A request must pass BOTH checks to be allowed through.

---

### Step 3: Policy merging (optional)

Platform teams can set baseline rate limits at the Gateway level, while application teams add
route-specific limits that merge with (rather than override) the baseline.

```yaml
# Platform team: Gateway-level baseline
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: global-abuse-prevention
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <gateway-name>  # TODO: Replace
  rateLimit:
    global:
      rules:
        - clientSelectors:
            - sourceCIDR:
                type: Distinct
                value: 0.0.0.0/0
          limit:
            requests: 100
            unit: Second
          shared: true
---
# Application team: Route-level addition (merges with gateway policy)
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: signup-rate-limit
spec:
  mergeType: StrategicMerge  # Enables merging with gateway policy instead of overriding
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: signup-service
  rateLimit:
    global:
      rules:
        - clientSelectors:
            - sourceCIDR:
                type: Distinct
                value: 0.0.0.0/0
          limit:
            requests: 5
            unit: Minute
          shared: false
```

### Step 4: Apply and verify

```bash
kubectl apply -f rate-limit-policy.yaml

# Verify the BackendTrafficPolicy status
kubectl get backendtrafficpolicy/<policy-name> -o yaml

# Test the rate limit (adjust host and path to match your route)
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code}\n" -H "Host: www.example.com" http://${GATEWAY_HOST}/path
done
# Expect 429 (Too Many Requests) once the limit is exceeded

# For global rate limiting, verify Redis connectivity:
kubectl logs -n envoy-gateway-system deploy/envoy-ratelimit
```

## Checklist

- [ ] BackendTrafficPolicy targets the correct resource (Gateway or HTTPRoute) in the same namespace
- [ ] Rate limit values are appropriate for the expected traffic volume
- [ ] For local limits: account for the number of Envoy replicas (effective limit = per-instance * replicas)
- [ ] For global limits: Redis is deployed and reachable from the envoy-gateway-system namespace
- [ ] For global limits: EnvoyGateway config points to the correct Redis URL
- [ ] For global limits: envoy-gateway deployment was restarted after config change
- [ ] For global limits: envoy-ratelimit pods are running without errors
- [ ] Combined limits: local limit is set higher than or equal to the per-instance share of the global limit
- [ ] Distinct matching (per-IP, per-header) uses global rate limiting (local does not support distinct)
- [ ] BackendTrafficPolicy status shows Accepted: True with no error conditions
- [ ] Rate limiting behavior has been tested with actual HTTP requests (verify 429 responses)
