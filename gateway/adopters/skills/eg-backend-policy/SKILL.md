---
name: eg-backend-policy
description: Configure backend traffic policies — load balancing, retries, health checks, circuit breaking, timeouts
arguments:
  - name: Feature
    description: "Feature to configure: loadbalancing, retries, healthcheck, circuitbreaker, timeout, all"
    required: false
---

Configure how Envoy Gateway communicates with backend services using BackendTrafficPolicy. This
policy controls load balancing, retries, health checks, circuit breaking, timeouts, and connection
settings. It attaches to a Gateway (applies to all routes) or to a specific HTTPRoute/GRPCRoute.

## Instructions

### Step 1: Create the BackendTrafficPolicy resource

Start with the base resource targeting a Gateway or HTTPRoute.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: <policy-name>  # TODO: Replace with a descriptive name
  namespace: <namespace>  # Must match the target resource namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute  # Or: Gateway, GRPCRoute
      name: <target-name>  # TODO: Replace with your target resource name
```

Then add the desired features from the sections below. Multiple features can be combined in a single
BackendTrafficPolicy resource.

---

### Step 2: Configure load balancing (Feature: loadbalancing)

Envoy Gateway supports four load balancing algorithms. If not specified, the default is **LeastRequest**.

**Round Robin** -- Distributes requests evenly across all backends:

```yaml
spec:
  loadBalancer:
    type: RoundRobin
```

**Random** -- Selects a random backend for each request:

```yaml
spec:
  loadBalancer:
    type: Random
```

**Least Request** -- Sends requests to the backend with the fewest active requests (default):

```yaml
spec:
  loadBalancer:
    type: LeastRequest
```

**Consistent Hash** -- Routes requests to the same backend based on a hash key. Useful for
session affinity and caching scenarios. The hash can be derived from source IP, a header, or a cookie.

By **source IP**:

```yaml
spec:
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: SourceIP
```

By **header**:

```yaml
spec:
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: Header
      header:
        name: x-user-id  # TODO: Replace with the header to hash on
```

By **cookie**:

```yaml
spec:
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: Cookie
      cookie:
        name: session-id  # TODO: Replace with the cookie name
        ttl: 3600s  # Cookie time-to-live; set to 0 for session cookies
        attributes:
          SameSite: Strict
```

**Slow start mode** -- Gradually ramp traffic to newly added endpoints. Supported with RoundRobin
and LeastRequest. Prevents overwhelming cold services during scaling events.

```yaml
spec:
  loadBalancer:
    type: RoundRobin
    slowStart:
      window: 60s  # TODO: Adjust -- duration of the ramp-up period for new endpoints
```

---

### Step 3: Configure retries (Feature: retries)

Retries automatically re-attempt failed requests. By default, retries are disabled unless configured.

```yaml
spec:
  retry:
    numRetries: 3  # TODO: Adjust -- number of retry attempts (default: 2 if omitted)
    perRetry:
      backOff:
        baseInterval: 100ms  # Initial backoff interval between retries
        maxInterval: 10s  # Maximum backoff interval
      timeout: 500ms  # Timeout for each individual retry attempt
    retryOn:
      triggers:
        - connect-failure  # Retry on TCP connection failures
        - retriable-status-codes  # Retry on specific HTTP status codes
        - reset  # Retry when the connection is reset
        # Other triggers: gateway-error, refused-stream, reset-before-request
      httpStatusCodes:
        - 500  # TODO: Adjust -- which status codes trigger a retry
        - 502
        - 503
```

Important: The `perRetry.timeout` applies to each retry attempt individually AND also sets the
timeout for the initial request. If your backends have variable response times, set
`perRetry.timeout` higher than the expected p99 latency, or configure `timeout.http.requestTimeout`
separately for the initial request.

**Retry budget** -- Limit the percentage of active requests that can be retried to prevent retry
storms. This is configured via circuit breaker `maxParallelRetries`:

```yaml
spec:
  retry:
    numRetries: 3
    retryOn:
      triggers:
        - connect-failure
        - retriable-status-codes
      httpStatusCodes:
        - 503
  circuitBreaker:
    maxParallelRetries: 10  # TODO: Adjust -- max concurrent retries across all requests
```

---

### Step 4: Configure health checks (Feature: healthcheck)

Health checks detect unhealthy backends and remove them from the load balancing pool. Envoy Gateway
supports both active (periodic probes) and passive (outlier detection based on real traffic) health checks.

#### Active health checks

Active health checks send periodic probes to backend endpoints.

**HTTP health check:**

```yaml
spec:
  healthCheck:
    active:
      type: HTTP
      http:
        path: /healthz  # TODO: Replace with your backend health check path
        expectedStatuses:
          - 200  # TODO: Adjust expected healthy status codes
        # method: GET  # Default is GET
        # expectedResponse:
        #   type: Text
        #   text: "ok"
      interval: 10s  # Time between health check probes (default: 3s)
      timeout: 5s  # Timeout for each probe (default: 1s)
      unhealthyThreshold: 3  # Consecutive failures before marking unhealthy (default: 3)
      healthyThreshold: 2  # Consecutive successes before marking healthy (default: 1)
```

**TCP health check:**

```yaml
spec:
  healthCheck:
    active:
      type: TCP
      tcp: {}  # Simple connection check -- verifies the port is reachable
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 2
```

#### Passive health checks (outlier detection)

Passive health checks monitor real traffic patterns and eject backends that return too many errors.
No extra probe traffic is generated.

```yaml
spec:
  healthCheck:
    passive:
      consecutive5XxErrors: 5  # Eject after 5 consecutive 5xx errors (default: 5)
      consecutiveGatewayErrors: 0  # 0 disables gateway error detection
      consecutiveLocalOriginFailures: 5  # Connection timeouts, resets (default: 5)
      interval: 3s  # Evaluation interval (default: 3s)
      baseEjectionTime: 30s  # Base duration a host is ejected (default: 30s)
      maxEjectionPercent: 50  # Max percentage of hosts that can be ejected (default: 10)
      splitExternalLocalOriginErrors: false  # Track external and local errors separately
    # panicThreshold: 50  # When unhealthy% exceeds this, ignore health and balance across all
```

**Combine active and passive health checks:**

```yaml
spec:
  healthCheck:
    active:
      type: HTTP
      http:
        path: /healthz
        expectedStatuses:
          - 200
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 2
    passive:
      consecutive5XxErrors: 3
      interval: 2s
      baseEjectionTime: 10s
      maxEjectionPercent: 50
```

When both are configured, a successful active health check can uneject a host that was ejected
by passive detection.

---

### Step 5: Configure circuit breaking (Feature: circuitbreaker)

Circuit breakers prevent cascading failures by limiting the number of connections and requests to
backends. Envoy Gateway defaults to a threshold of 1024 for each limit, which may be too strict for
high-throughput systems.

Note: Circuit breaker counters are per-BackendReference and are NOT synchronized across Envoy
instances. Each Envoy replica maintains its own counters independently.

```yaml
spec:
  circuitBreaker:
    maxConnections: 1024  # TODO: Adjust -- max concurrent connections to the backend
    maxPendingRequests: 128  # TODO: Adjust -- max queued requests when all connections are busy
    maxParallelRequests: 1024  # TODO: Adjust -- max concurrent in-flight requests
    maxParallelRetries: 32  # TODO: Adjust -- max concurrent retry requests
```

A practical example for a degraded backend scenario -- fail fast instead of queuing:

```yaml
spec:
  circuitBreaker:
    maxPendingRequests: 0  # Reject immediately if no connections are available
    maxParallelRequests: 10  # Allow only 10 concurrent requests
```

When `maxPendingRequests` or `maxParallelRequests` is exceeded, Envoy returns `503 Service Unavailable`.

---

### Step 6: Configure timeouts (Feature: timeout)

Control how long Envoy waits for backend responses and connections.

```yaml
spec:
  timeout:
    http:
      requestTimeout: 30s  # TODO: Adjust -- max time to wait for a complete response
      connectionIdleTimeout: 3600s  # Close idle connections after this duration (default: 1h)
    tcp:
      connectTimeout: 5s  # TODO: Adjust -- max time to establish a TCP connection
```

**TCP keepalive** -- Detect dead connections between Envoy and backends:

```yaml
spec:
  tcpKeepalive:
    probes: 3  # Number of keepalive probes before declaring dead
    idleTime: 60s  # Time connection must be idle before keepalive starts (seconds)
    interval: 10s  # Time between keepalive probes (seconds)
```

---

### Step 7: Configure connection settings (optional)

**HTTP/2 to backends** -- Enable when your backends support HTTP/2:

```yaml
spec:
  http2: {}  # Enable HTTP/2 for backend connections with default settings
  # Or with explicit settings:
  # http2:
  #   initialStreamWindowSize: 65536
  #   initialConnectionWindowSize: 1048576
```

**Backend connection buffer limits:**

```yaml
spec:
  connection:
    bufferLimit: 32768  # Per-connection buffer limit in bytes
```

---

### Step 8: Full example combining multiple features

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: production-backend-policy
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: api-route  # TODO: Replace with your HTTPRoute name
  loadBalancer:
    type: LeastRequest
    slowStart:
      window: 30s
  retry:
    numRetries: 3
    perRetry:
      backOff:
        baseInterval: 100ms
        maxInterval: 10s
      timeout: 2s
    retryOn:
      triggers:
        - connect-failure
        - retriable-status-codes
      httpStatusCodes:
        - 502
        - 503
        - 504
  healthCheck:
    active:
      type: HTTP
      http:
        path: /healthz
        expectedStatuses:
          - 200
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 2
    passive:
      consecutive5XxErrors: 5
      interval: 3s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  circuitBreaker:
    maxConnections: 4096
    maxPendingRequests: 512
    maxParallelRequests: 4096
    maxParallelRetries: 64
  timeout:
    http:
      requestTimeout: 30s
      connectionIdleTimeout: 300s
    tcp:
      connectTimeout: 5s
  tcpKeepalive:
    probes: 3
    idleTime: 60s
    interval: 10s
```

### Step 9: Apply and verify

```bash
kubectl apply -f backend-traffic-policy.yaml

# Verify the BackendTrafficPolicy status
kubectl get backendtrafficpolicy/<policy-name> -o yaml

# Check that conditions show Accepted: True
kubectl get backendtrafficpolicy/<policy-name> -o jsonpath='{.status.conditions}'

# Verify retries are working (check retry stats):
egctl x stats envoy-proxy -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=<gateway-name> \
  | grep upstream_rq_retry

# Verify circuit breaker behavior under load:
# Use a tool like 'hey' to generate concurrent requests against a slow backend
hey -n 100 -c 100 -host "www.example.com" http://${GATEWAY_HOST}/path?delay=10s
```

## Checklist

- [ ] BackendTrafficPolicy targets the correct resource (Gateway or HTTPRoute) in the same namespace
- [ ] Load balancing algorithm matches the application requirements (session affinity vs. even distribution)
- [ ] Slow start window is set for services that need warm-up time (e.g., JVM-based applications)
- [ ] Retry numRetries is reasonable (2-5); excessive retries can amplify failures
- [ ] Retry triggers include connect-failure for resilience against transient connection issues
- [ ] perRetry.timeout is set appropriately relative to the requestTimeout
- [ ] Active health check path exists on the backend and returns expected status codes
- [ ] Passive health check maxEjectionPercent is not 100% in production (risk of ejecting all hosts)
- [ ] Circuit breaker thresholds are tuned for expected traffic (default 1024 may be too low for high throughput)
- [ ] Request timeout is longer than the expected p99 backend latency
- [ ] connectionIdleTimeout is lower than or equal to the backend's idle timeout to prevent resets
- [ ] TCP keepalive is enabled for long-lived connections to detect dead peers
- [ ] BackendTrafficPolicy status shows Accepted: True with no error conditions
