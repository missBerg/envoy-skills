---
name: eg-enterprise
description: Production-grade Envoy Gateway setup with comprehensive security, observability, high availability, and operational best practices
---

# Envoy Gateway Enterprise Production Setup

## Role

You set up a production-grade Envoy Gateway deployment following the full Envoy Gateway threat model and enterprise best practices. This agent covers everything needed for a secure, observable, resilient production deployment. You walk the user through each phase methodically, ensuring nothing is missed.

## Intake Interview

Before generating any configuration, ask the user these questions. Skip questions the user has already answered. Ask in a conversational tone, grouping related questions when it makes sense.

### Questions

1. **Deployment topology**: What is your deployment topology?
   - Single cluster
   - Multi-cluster (separate ingress per cluster, or shared control plane)
   - Hybrid (some workloads on-prem, some in cloud)

2. **Compliance**: SOC2, PCI-DSS, HIPAA, FedRAMP, or internal standards only?

3. **PKI infrastructure**: cert-manager already installed (which issuer?), need to set it up, or manual certificate management?

4. **Observability stack**: Prometheus+Grafana, Datadog, OpenTelemetry Collector, cloud-native, or other?

5. **GitOps**: ArgoCD, Flux, or none (manual kubectl/CI pipeline)?

6. **Backend mTLS**: Needed with mesh CA, cert-manager, or not needed?

7. **Traffic volume**: Low (<1K rps), Medium (1-10K rps), High (10-100K rps), or Very High (100K+ rps)?

8. **WAF**: Needed via ExtAuth, Wasm (e.g., Coraza), or not needed?

## Workflow

### Phase 1: Foundation -- Install with Production Helm Values

Use the `/eg-install` skill with production-grade Helm values.

```yaml
# values-production.yaml
deployment:
  replicas: 2                      # HA for the controller
  envoyGateway:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1024Mi
    image:
      tag: v1.7.0                  # TODO: Pin to your target version
podDisruptionBudget:
  maxUnavailable: 1
config:
  envoyGateway:
    logging:
      level:
        default: info              # Use 'debug' only for troubleshooting
```

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  -n envoy-gateway-system \
  --create-namespace \
  -f values-production.yaml
```

If cert-manager is not already installed, use the `/eg-tls` skill to install it and configure a production ClusterIssuer (Let's Encrypt recommended).

### Phase 2: Gateway with HTTPS and EnvoyProxy Customization

Use the `/eg-gateway` skill to create the Gateway. Use the `/eg-tls` skill for TLS configuration.

Create the EnvoyProxy resource with production resource limits and scaling:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: production-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 3  # TODO: Adjust based on traffic volume
        container:
          resources:
            requests:
              cpu: 500m        # TODO: Adjust based on traffic volume
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
        pod:
          annotations:
            prometheus.io/scrape: "true"
            prometheus.io/port: "19001"
      envoyHpa:
        minReplicas: 3        # TODO: Minimum replicas
        maxReplicas: 10       # TODO: Maximum replicas
        metrics:
          - type: Resource
            resource:
              name: cpu
              target:
                type: Utilization
                averageUtilization: 60  # Scale up at 60% CPU
  # Telemetry is configured in Phase 7
```

Use the `/eg-gateway` skill to create the GatewayClass (with `parametersRef` pointing to the `production-proxy` EnvoyProxy above) and Gateway with HTTP + HTTPS listeners. Use the `/eg-tls` skill for TLS termination and HTTP-to-HTTPS redirect.

### Phase 3: Security Hardening

Apply all threat model mitigations systematically. This phase covers the Envoy Gateway threat model findings (EGTM references).

#### 3a: TLS Hardening (EGTM-001, EGTM-002)

Use the `/eg-tls` skill. Configure minimum TLS version and strong cipher suites via ClientTrafficPolicy:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: tls-hardening
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
      sectionName: https          # Target only the HTTPS listener
  tls:
    minVersion: "1.2"             # Minimum TLS 1.2 (prefer 1.3 if clients support it)
    # TODO: For PCI-DSS, set minVersion to "1.2" and restrict ciphers
    ciphers:
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
      - ECDHE-ECDSA-AES256-GCM-SHA384
      - ECDHE-RSA-AES256-GCM-SHA384
    alpnProtocols:
      - h2
      - http/1.1
```

#### 3b: Path Normalization and Header Security

Configure path normalization to prevent path confusion attacks and reject headers with underscores:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: http-hardening
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
  path:
    # Normalize paths to prevent path traversal attacks
    escapedSlashesAction: UnescapeAndRedirect
    disableMergeSlashes: false
  headers:
    # Reject requests with underscores in header names to prevent
    # header injection via underscore-to-hyphen conversion
    withUnderscoresAction: RejectRequest
    # Preserve original path in x-envoy-original-path header for logging
    preserveXRequestID: true
  # Enable use_remote_address so Envoy uses the real client IP
  # for access logging, rate limiting, and authorization
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: 1  # TODO: Adjust based on your proxy chain depth
```

#### 3c: Authentication (EGTM-023)

Use the `/eg-auth` skill. Key requirements:
- Configure JWT/OIDC authentication -- never use Basic Auth in production (EGTM-023)
- Set `audiences` to prevent token confusion attacks
- Set `authorization.defaultAction: Deny` with explicit allow rules

#### 3d: IP Allowlisting and CORS

Use the `/eg-auth` skill for IP allowlisting on admin/internal routes (restrict by `clientCIDRs`) and CORS configuration (set explicit `allowOrigins`, never use wildcard `*` in production).

### Phase 4: Traffic Resilience

Use the `/eg-backend-policy` skill to configure backend resilience. Recommended production settings:

| Setting | Recommended Value | Notes |
|---------|-------------------|-------|
| Active health check | HTTP `/healthz`, interval 10s, unhealthy threshold 3 | Detect and remove unhealthy backends |
| Circuit breaker | maxConnections: 1024, maxRequests: 1024 | Prevent cascade failures |
| Retries | numRetries: 2, retryOn: connect-failure, refused-stream, 503 | With backoff (100ms base, 1s max) |
| Timeouts | connectionIdleTimeout: 60s, maxConnectionDuration: 300s | Adjust per service SLA |
| Load balancer | LeastRequest | Better than RoundRobin under variable load |
| TCP keepalive | probes: 3, idleTime: 60s, interval: 10s | Keep backend connections alive |

### Phase 5: Rate Limiting (EGTM-018)

Use the `/eg-rate-limit` skill to configure DoS protection. For production, apply both:

- **Global rate limits** (requires Redis): Consistent limits across all Envoy replicas for business-level quotas. Use the `/eg-rate-limit` skill to deploy Redis and configure global BackendTrafficPolicy with `rateLimit.type: Global`.
- **Local rate limits**: Per-replica limits as defense-in-depth. Protect individual Envoy instances from being overwhelmed.

Both can be applied simultaneously to the same Gateway.

### Phase 6: Client Policies

Use the `/eg-client-policy` skill to configure connection limits, HTTP/2 tuning, and keepalive.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: production-client-policy
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
  # Connection limits -- prevent a single client from exhausting resources
  connection:
    connectionLimit:
      value: 10000                  # TODO: Adjust based on expected concurrent connections
    bufferLimit: 32768              # 32 KiB buffer limit per connection
  # HTTP timeouts
  timeout:
    http:
      requestReceivedTimeout: 30s   # Max time to receive the complete request
  # HTTP/2 tuning
  http2:
    maxConcurrentStreams: 100       # Prevent a single connection from monopolizing resources
  # Keep-alive
  tcpKeepalive:
    probes: 3
    idleTime: 60s
    interval: 10s
```

### Phase 7: Observability

Use the `/eg-observability` skill to add telemetry to the `production-proxy` EnvoyProxy resource from Phase 2. Add a `spec.telemetry` section with:

- **Access logging**: JSON format to stdout with fields: start_time, method, path, response_code, response_flags, duration, upstream_host, request_id, x_forwarded_for, user_agent, authority. Add OTel sink if using OpenTelemetry.
- **Metrics**: Enable `enableVirtualHostStats: true`. Add OpenTelemetry sink to your OTel collector.
- **Tracing**: OpenTelemetry provider, `samplingRate: 5` for production (100 for staging). Add custom tags for environment and pod metadata.

Recommended Prometheus alerts to configure:
- **HighErrorRate** (critical): 5xx rate > 5% over 5m. Expr: `sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="5"}[5m])) / sum(rate(envoy_http_downstream_rq_total[5m])) > 0.05`
- **HighLatency** (warning): p99 latency > 5s. Expr: `histogram_quantile(0.99, sum(rate(envoy_http_downstream_rq_time_bucket[5m])) by (le)) > 5000`
- **HighConnectionCount** (warning): Active connections approaching limit. Expr: `envoy_http_downstream_cx_active > 9000`

### Phase 8: Operations

#### 8a: GitOps Manifests

Organize manifests: `infrastructure/envoy-gateway/` for controller-level resources (namespace, Helm release, EnvoyProxy, GatewayClass) and `apps/gateway-system/` for application-level resources (Gateway, policies, routes). Use ArgoCD or Flux with `ServerSideApply=true` for CRD management.

#### 8b: Upgrade Strategy

1. Review release notes for the target version
2. Update CRDs: `helm template eg oci://docker.io/envoyproxy/gateway-crds-helm --version <new-version> | kubectl apply --server-side -f -`
3. Upgrade controller: `helm upgrade eg oci://docker.io/envoyproxy/gateway-helm --version <new-version> -n envoy-gateway-system -f values-production.yaml`
4. Verify all Gateways show `Programmed: True` after upgrade

#### 8c: Verification Commands

```bash
kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
kubectl describe gateway production-gw -n gateway-system
kubectl get securitypolicy,backendtrafficpolicy,clienttrafficpolicy -A -o wide
export GATEWAY_HOST=$(kubectl get gateway production-gw -n gateway-system -o jsonpath='{.status.addresses[0].value}')
curl -v https://app.example.com --resolve "app.example.com:443:$GATEWAY_HOST"
```

## Output Requirements

Generate production-ready manifests in order: Helm install, cert-manager (if needed), EnvoyProxy, GatewayClass, Gateway, HTTP-to-HTTPS redirect, HTTPRoutes, ClientTrafficPolicy, SecurityPolicy, BackendTrafficPolicy, observability, GitOps manifests, and verification commands.

## Guidelines

- Always pin the Envoy Gateway Helm chart version explicitly (default: `v1.7.0`).
- Use `gateway.networking.k8s.io/v1` for Gateway API resources and `gateway.envoyproxy.io/v1alpha1` for Envoy Gateway extension CRDs.
- Use kebab-case for all resource names.
- Include TODO comments in YAML for values the user must customize.
- Reference specific EGTM threat model findings when applying security mitigations.
- For compliance (PCI-DSS, HIPAA, SOC2), explicitly call out which configuration satisfies which requirement.
- Never use self-signed certificates in the production configuration (EGTM-001).
- Never use Basic Auth (EGTM-023). Always prefer JWT/OIDC.
- Always set resource requests and limits on all containers.
- Always configure PodDisruptionBudgets for availability.
- When the user's cluster lacks a LoadBalancer implementation, mention MetalLB or suggest cloud-specific annotations.
