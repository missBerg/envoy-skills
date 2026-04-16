---
name: eg-client-policy
description: Configure client-facing traffic policies -- timeouts, connection limits, TLS settings, HTTP behavior
arguments:
  - name: Feature
    description: "Feature to configure: timeout, connection, tls, http, all (default: all)"
    required: false
---

# Envoy Gateway Client Traffic Policy

Generate ClientTrafficPolicy resources to configure how Envoy Proxy handles downstream
client connections. This includes timeouts, connection limits, TLS client settings,
HTTP protocol behavior, IP detection, and header management.

ClientTrafficPolicy attaches to Gateway resources (not Routes) and configures the
listener-level behavior for all traffic entering through that Gateway.

## Instructions

### Step 1: Create the ClientTrafficPolicy

ClientTrafficPolicy targets a Gateway. A section-specific policy (targeting a named
listener) takes precedence over a gateway-wide policy.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: client-policy       # TODO: choose a descriptive name
  namespace: default         # Must be in the same namespace as the target Gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg               # TODO: replace with your Gateway name
      # Optional: target a specific listener by name
      # sectionName: https-listener
```

### Step 2: Client Timeouts

Configure timeouts to protect Envoy from slow clients and prevent resource exhaustion.
Never rely on Envoy defaults -- set explicit timeouts.

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  timeout:
    http:
      # Maximum time to wait for the client to send the complete request
      # (headers + body). Protects against slowloris attacks.
      requestReceivedTimeout: 30s  # TODO: tune for your largest expected request
      # Close idle HTTP connections after this duration.
      # Set lower than backend idle timeout to close client-side first.
      idleTimeout: 120s            # TODO: tune based on client behavior
    tcp:
      # Close idle TCP connections after this duration.
      idleTimeout: 3600s           # TODO: 1 hour default, reduce for high-churn environments
```

### Step 3: Connection Management

Control connection limits and buffer sizes to protect Envoy under load.

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  connection:
    # Maximum concurrent connections per listener.
    # HTTP listeners: all HTTP listeners in a Gateway share one counter.
    # HTTPS/TLS listeners: each listener has a dedicated counter.
    connectionLimit:
      value: 10000             # TODO: set based on your capacity planning
      # Optional: delay before rejecting over-limit connections
      # closeDelay: 1s
    # Per-connection buffer limit. Caps memory used for read/write buffers.
    # 32 KiB is recommended to balance throughput and memory usage.
    bufferLimit: 32768         # 32 KiB in bytes
  # TCP keepalive prevents connections from being silently dropped by
  # intermediate load balancers or firewalls.
  tcpKeepalive:
    probes: 3                  # Number of keepalive probes before closing
    idleTime: 60s              # Time before sending first keepalive probe
    interval: 10s              # Interval between keepalive probes
```

### Step 4: TLS Client Settings

Configure TLS termination behavior for HTTPS listeners.

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
      sectionName: https       # TODO: target your HTTPS listener specifically
  tls:
    # Minimum TLS version. TLSv1.2 is the minimum for production.
    # Prefer TLSv1.3 for best security and performance.
    minVersion: "1.2"          # TODO: use "1.3" if all clients support it
    maxVersion: "1.3"
    # Cipher suites for TLS 1.0-1.2. No effect on TLS 1.3 (which has its own fixed set).
    # Remove weak ciphers; keep only AEAD ciphers with ECDHE key exchange.
    ciphers:
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
      - ECDHE-ECDSA-AES256-GCM-SHA384
      - ECDHE-RSA-AES256-GCM-SHA384
      - ECDHE-ECDSA-CHACHA20-POLY1305
      - ECDHE-RSA-CHACHA20-POLY1305
    # ALPN protocols for HTTPS listeners. Defaults to [h2, http/1.1].
    alpnProtocols:
      - h2
      - http/1.1
    # Client certificate validation (mTLS).
    # Uncomment to require clients to present a valid certificate.
    # clientValidation:
    #   caCertificateRefs:
    #     - name: client-ca-cert   # TODO: Secret or ConfigMap with CA bundle
    #       group: ""
    #       kind: ConfigMap
    #   optional: false            # true = accept connections without client certs
```

#### mTLS (Mutual TLS) -- require client certificates

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
      sectionName: https
  tls:
    minVersion: "1.2"
    clientValidation:
      caCertificateRefs:
        - name: trusted-client-ca  # TODO: ConfigMap or Secret with your CA certificate
          group: ""
          kind: ConfigMap
      optional: false              # Reject connections without valid client certs
```

Create the CA ConfigMap:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trusted-client-ca
data:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    # TODO: paste your CA certificate PEM here
    -----END CERTIFICATE-----
```

### Step 5: HTTP Protocol Behavior

Configure HTTP/1.1 and HTTP/2 protocol settings, path normalization, and header handling.

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  # HTTP/2 settings
  http2:
    # Maximum concurrent streams per HTTP/2 connection.
    # Prevents a single connection from monopolizing resources.
    maxConcurrentStreams: 100   # Recommended default
  # Path normalization MUST be enabled to prevent path confusion attacks.
  # Without this, attackers can bypass route matching with paths like /admin/../secret.
  path:
    escapedSlashesAction: UnescapeAndRedirect
    disableMergeSlashes: false
  # Header management
  headers:
    # Reject requests with underscores in header names.
    # Prevents header injection via underscore-to-hyphen conversion.
    withUnderscoresAction: RejectRequest  # Options: Allow, RejectRequest, DropHeader
    # Preserve the external X-Request-Id header if present.
    # Useful when request IDs are generated by an upstream CDN or load balancer.
    preserveXRequestID: true
    # Control Envoy proxy headers sent to clients.
    # Disable in production to avoid leaking infrastructure details.
    enableEnvoyHeaders: false  # Suppresses x-envoy-upstream-service-time, server header, etc.
    # Early header flushing sends response headers to the client as soon as
    # they are received from the backend, without waiting for the body.
    # enableEarlyHeaderFlushing: true
```

### Step 6: Client IP Detection

Configure how Envoy determines the true client IP address. Critical for accurate
access logging, rate limiting, and authorization decisions.

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  clientIPDetection:
    # For edge proxies (directly receiving internet traffic):
    # use_remote_address uses the downstream connection IP as the client address.
    xForwardedFor:
      numTrustedHops: 0  # 0 = use the direct connection IP (edge proxy)
      # TODO: if behind a CDN or load balancer, set to the number of trusted
      # proxy hops between the client and Envoy. For example:
      # Client -> CloudFlare -> AWS NLB -> Envoy = numTrustedHops: 2
    # Alternative: use a custom header for client IP.
    # Useful when a CDN sets a non-standard header like CF-Connecting-IP.
    # customHeader:
    #   name: CF-Connecting-IP  # TODO: replace with your CDN's client IP header
    #   failClosed: true        # Reject requests missing this header
```

### Step 7: Proxy Protocol

If Envoy is behind a TCP load balancer that sends PROXY protocol headers (e.g., AWS NLB):

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  proxyProtocol:
    versions:
      - V1
      - V2
```

### Step 8: Complete Production ClientTrafficPolicy

Here is a comprehensive production-ready example:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: production-client-policy
  namespace: default  # TODO: same namespace as your Gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg  # TODO: replace with your Gateway name
  # -- Timeouts --
  timeout:
    http:
      requestReceivedTimeout: 30s
      idleTimeout: 120s
    tcp:
      idleTimeout: 3600s
  # -- Connection management --
  connection:
    connectionLimit:
      value: 10000
    bufferLimit: 32768  # 32 KiB
  tcpKeepalive:
    probes: 3
    idleTime: 60s
    interval: 10s
  # -- TLS --
  tls:
    minVersion: "1.2"
    ciphers:
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
      - ECDHE-ECDSA-AES256-GCM-SHA384
      - ECDHE-RSA-AES256-GCM-SHA384
    alpnProtocols:
      - h2
      - http/1.1
  # -- HTTP behavior --
  http2:
    maxConcurrentStreams: 100
  path:
    escapedSlashesAction: UnescapeAndRedirect
    disableMergeSlashes: false
  headers:
    withUnderscoresAction: RejectRequest
    preserveXRequestID: true
    enableEnvoyHeaders: false
  # -- Client IP detection --
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: 0  # TODO: adjust if behind CDN/LB
```

### Step 9: Listener-Specific Policy Override

You can create a more specific policy for a single listener that overrides the
gateway-wide policy:

```yaml
# Gateway-wide defaults
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: gateway-defaults
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
  timeout:
    http:
      idleTimeout: 120s
---
# Override for the HTTPS listener with stricter TLS settings
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: https-strict-tls
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eg
      sectionName: https  # This policy takes precedence for this listener
  tls:
    minVersion: "1.3"  # Require TLS 1.3 on this listener
    clientValidation:
      caCertificateRefs:
        - name: trusted-client-ca
          group: ""
          kind: ConfigMap
      optional: false
  timeout:
    http:
      idleTimeout: 60s  # Shorter idle timeout for this listener
```

## Checklist

- [ ] ClientTrafficPolicy is in the **same namespace** as the target Gateway
- [ ] `targetRefs` points to the correct Gateway (and optionally `sectionName` for a specific listener)
- [ ] `requestReceivedTimeout` is set to protect against slow client attacks
- [ ] `idleTimeout` for HTTP is set lower than backend idle timeout
- [ ] `connectionLimit` is set based on capacity planning and load testing
- [ ] `bufferLimit` is set to 32 KiB (32768) to cap per-connection memory
- [ ] `tcpKeepalive` is enabled to prevent silent connection drops
- [ ] TLS `minVersion` is at least `"1.2"` in production (prefer `"1.3"`)
- [ ] Weak cipher suites are excluded (no CBC-mode ciphers)
- [ ] Path normalization is enabled (`escapedSlashesAction`, `disableMergeSlashes: false`)
- [ ] `withUnderscoresAction: RejectRequest` is set to prevent header injection
- [ ] `enableEnvoyHeaders: false` is set to avoid leaking proxy details to clients
- [ ] `http2.maxConcurrentStreams` is limited (100 recommended)
- [ ] Client IP detection matches your deployment topology (edge vs. behind CDN/LB)
- [ ] If using mTLS: CA bundle ConfigMap/Secret exists and `clientValidation` is configured
- [ ] Verify policy status: `kubectl get clienttrafficpolicy <name> -o yaml` shows `Accepted: True`
- [ ] Test timeouts and connection behavior under load
