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

2. **Compliance**: What compliance requirements apply?
   - SOC2
   - PCI-DSS (requires strict TLS, audit logging, access control)
   - HIPAA (requires encryption in transit and at rest, audit trails)
   - FedRAMP
   - None / internal standards only

3. **PKI infrastructure**: Do you have an existing PKI or certificate infrastructure?
   - cert-manager already installed (which issuer: Let's Encrypt, Vault, AWS ACM, self-managed CA)
   - No cert-manager, need to set it up
   - Manual certificate management (existing process to provide certs)

4. **Observability stack**: What observability stack do you use?
   - Prometheus + Grafana
   - Datadog
   - OpenTelemetry Collector (to a backend like Jaeger, Tempo, or cloud provider)
   - Cloud-native (AWS CloudWatch, GCP Cloud Monitoring, Azure Monitor)
   - Other (describe)

5. **GitOps**: What GitOps tool do you use?
   - ArgoCD
   - Flux
   - None (manual kubectl apply or CI/CD pipeline)

6. **Backend mTLS**: Do you need mutual TLS (mTLS) between the gateway and backends?
   - Yes, with an existing service mesh CA (Istio, Linkerd)
   - Yes, with cert-manager-issued certificates
   - No, backends are trusted within the cluster network

7. **Traffic volume**: What is your expected peak traffic?
   - Low (< 1,000 rps) -- single replica may suffice for dev/staging
   - Medium (1,000 - 10,000 rps) -- 2-3 replicas with HPA
   - High (10,000 - 100,000 rps) -- dedicated node pool, tuned connection limits
   - Very high (100,000+ rps) -- requires careful resource planning, multiple Gateways

8. **WAF**: Do you need WAF capabilities?
   - Yes, via ExtAuth (integrate with existing WAF)
   - Yes, via Wasm (e.g., Coraza WAF)
   - No

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
      tag: v1.3.0                  # TODO: Pin to your target version
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
  --version v1.3.0 \
  -n envoy-gateway-system \
  --create-namespace \
  -f values-production.yaml
```

If cert-manager is not already installed, install it now:

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --version v1.17.1  # TODO: Pin to latest stable
```

Configure a production-grade ClusterIssuer:

```yaml
# Let's Encrypt production issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform-team@example.com  # TODO: Replace with your email
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: production-gw       # TODO: Replace with your Gateway name
                namespace: gateway-system  # TODO: Replace with your Gateway namespace
```

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

Create the Gateway with HTTPS listener:

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
    name: production-proxy
    namespace: envoy-gateway-system
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: production-gw
  namespace: gateway-system              # TODO: Replace with your namespace
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"          # TODO: Replace with your domain
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: wildcard-tls           # TODO: cert-manager creates this
      allowedRoutes:
        namespaces:
          from: All
```

Create an HTTP-to-HTTPS redirect route:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: gateway-system  # TODO: Replace
spec:
  parentRefs:
    - name: production-gw
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

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
    # TODO: For PCI-DSS, set minVersion to "1.2" and restrict cipherSuites
    cipherSuites:
      - TLS_AES_128_GCM_SHA256
      - TLS_AES_256_GCM_SHA384
      - TLS_CHACHA20_POLY1305_SHA256
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
    preserveXRequestId: true
  # Enable use_remote_address so Envoy uses the real client IP
  # for access logging, rate limiting, and authorization
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: 1  # TODO: Adjust based on your proxy chain depth
```

#### 3c: Authentication (EGTM-023)

Use the `/eg-auth` skill. Configure JWT/OIDC authentication (never Basic Auth in production):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: production-auth
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
  jwt:
    providers:
      - name: primary-idp
        issuer: "https://auth.example.com"           # TODO: Replace
        audiences:
          - "https://api.example.com"                 # TODO: Set audiences to prevent token confusion
        remoteJWKS:
          uri: "https://auth.example.com/.well-known/jwks.json"  # TODO: Replace
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-authenticated
        action: Allow
        principal:
          jwt:
            provider: primary-idp
```

#### 3d: IP Allowlisting (where appropriate)

For admin or internal-only routes:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: admin-ip-restrict
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: admin-route  # TODO: Replace with your admin route
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-internal
        action: Allow
        principal:
          clientCIDRs:
            - 10.0.0.0/8       # TODO: Replace with your internal CIDR ranges
            - 192.168.0.0/16
```

#### 3e: CORS Configuration

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: production-cors
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
  cors:
    allowOrigins:
      - "https://app.example.com"    # TODO: Replace with your allowed origins
    allowMethods:
      - GET
      - POST
      - PUT
      - DELETE
      - OPTIONS
    allowHeaders:
      - Authorization
      - Content-Type
      - X-Request-ID
    exposeHeaders:
      - X-Request-ID
    maxAge: 86400s
```

### Phase 4: Traffic Resilience

Use the `/eg-backend-policy` skill to configure backend resilience.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: production-backend-policy
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
  # Health checks -- detect and remove unhealthy backends
  healthCheck:
    active:
      type: HTTP
      http:
        path: /healthz             # TODO: Replace with your health check endpoint
        expectedStatuses:
          - 200
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 2
  # Circuit breaking -- prevent cascade failures
  circuitBreaker:
    maxConnections: 1024           # TODO: Adjust based on expected load
    maxPendingRequests: 1024
    maxRequests: 1024
    maxRetries: 3
  # Retries -- automatically retry transient failures
  retry:
    numRetries: 2
    retryOn:
      - connect-failure
      - refused-stream
      - unavailable
      - cancelled
      - retriable-status-codes
    retriableStatusCodes:
      - 503
    perRetry:
      timeout: 2s
      backOff:
        baseInterval: 100ms
        maxInterval: 1s
  # Timeouts
  timeout:
    http:
      connectionIdleTimeout: 60s
      maxConnectionDuration: 300s
  # Load balancing
  loadBalancer:
    type: LeastRequest              # Better distribution than RoundRobin under variable load
  # TCP keepalive for backend connections
  tcpKeepalive:
    probes: 3
    idleTime: 60s
    interval: 10s
```

### Phase 5: Rate Limiting (EGTM-018)

Use the `/eg-rate-limit` skill to configure DoS protection.

For production, use global rate limiting with Redis for consistent limits across all Envoy replicas:

```yaml
# Redis deployment for global rate limiting
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-rate-limit
  namespace: envoy-gateway-system
spec:
  replicas: 1  # TODO: Use Redis Sentinel or Cluster for HA in production
  selector:
    matchLabels:
      app: redis-rate-limit
  template:
    metadata:
      labels:
        app: redis-rate-limit
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis-rate-limit
  namespace: envoy-gateway-system
spec:
  selector:
    app: redis-rate-limit
  ports:
    - port: 6379
      targetPort: 6379
```

Configure the global rate limit in BackendTrafficPolicy:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: global-rate-limit
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
  rateLimit:
    type: Global
    global:
      rules:
        - clientSelectors:
            - headers:
                - name: ":path"
                  type: Distinct      # Rate limit per unique path
          limit:
            requests: 100             # TODO: Adjust based on expected traffic
            unit: Second
```

Also add local rate limits as a defense-in-depth measure:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: local-rate-limit
  namespace: gateway-system  # TODO: Replace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: production-gw
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 1000            # TODO: Adjust -- per Envoy replica limit
            unit: Second
```

Note: Both local and global rate limits can be applied simultaneously. Local limits protect individual Envoy instances from being overwhelmed, while global limits enforce business-level quotas.

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

Use the `/eg-observability` skill to configure comprehensive telemetry.

Update the EnvoyProxy resource from Phase 2 to include telemetry configuration:

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
        replicas: 3
        container:
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
        pod:
          annotations:
            prometheus.io/scrape: "true"
            prometheus.io/port: "19001"
      envoyHpa:
        minReplicas: 3
        maxReplicas: 10
        metrics:
          - type: Resource
            resource:
              name: cpu
              target:
                type: Utilization
                averageUtilization: 60
  telemetry:
    # Structured access logging
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
              response_flags: "%RESPONSE_FLAGS%"
              bytes_received: "%BYTES_RECEIVED%"
              bytes_sent: "%BYTES_SENT%"
              duration: "%DURATION%"
              upstream_service_time: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
              upstream_host: "%UPSTREAM_HOST%"
              upstream_cluster: "%UPSTREAM_CLUSTER%"
              x_forwarded_for: "%REQ(X-FORWARDED-FOR)%"
              request_id: "%REQ(X-REQUEST-ID)%"
              user_agent: "%REQ(USER-AGENT)%"
              authority: "%REQ(:AUTHORITY)%"
          sinks:
            - type: File
              file:
                path: /dev/stdout
            # TODO: Uncomment for OpenTelemetry log export
            # - type: OpenTelemetry
            #   openTelemetry:
            #     host: otel-collector.observability.svc.cluster.local
            #     port: 4317
    # Prometheus metrics
    metrics:
      sinks:
        - type: OpenTelemetry
          openTelemetry:
            host: otel-collector.observability.svc.cluster.local  # TODO: Replace
            port: 4317
      enableVirtualHostStats: true
      matches:
        - type: Prefix
          value: ""                # Export all metrics
    # Distributed tracing
    tracing:
      provider:
        host: otel-collector.observability.svc.cluster.local  # TODO: Replace
        port: 4317
        type: OpenTelemetry
      samplingRate: 5              # TODO: 1-10% for production, 100% for staging
      customTags:
        environment:
          type: Literal
          literal:
            value: production      # TODO: Replace with your environment
```

#### Prometheus Alerting Rules

Provide recommended alert rules for the user's monitoring stack:

```yaml
# PrometheusRule for Envoy Gateway alerts
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: envoy-gateway-alerts
  namespace: monitoring  # TODO: Replace with your monitoring namespace
spec:
  groups:
    - name: envoy-gateway
      rules:
        - alert: HighErrorRate
          expr: |
            sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="5"}[5m]))
            / sum(rate(envoy_http_downstream_rq_total[5m])) > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Envoy Gateway 5xx error rate above 5%"
        - alert: HighLatency
          expr: |
            histogram_quantile(0.99, sum(rate(envoy_http_downstream_rq_time_bucket[5m])) by (le))
            > 5000
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Envoy Gateway p99 latency above 5 seconds"
        - alert: HighConnectionCount
          expr: envoy_http_downstream_cx_active > 9000
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Envoy Gateway active connections approaching limit"
```

### Phase 8: Operations

#### 8a: GitOps Manifests

Organize manifests for GitOps. Recommend this directory structure:

```
infrastructure/
  envoy-gateway/
    namespace.yaml
    helm-release.yaml          # Or ArgoCD Application / Flux HelmRelease
    envoy-proxy.yaml           # EnvoyProxy customization
    gateway-class.yaml
apps/
  gateway-system/
    gateway.yaml
    client-traffic-policy.yaml
    security-policy.yaml
    backend-traffic-policy.yaml
  app-namespace/
    httproute.yaml
    security-policy.yaml       # Route-level overrides
```

For ArgoCD:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: envoy-gateway
  namespace: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/your-org/your-repo  # TODO: Replace
    path: infrastructure/envoy-gateway
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: envoy-gateway-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true  # Required for CRDs
```

#### 8b: Upgrade Strategy

Document the upgrade procedure:

1. Review release notes for the target Envoy Gateway version
2. Update CRDs first (if managing separately):
   ```bash
   helm template eg oci://docker.io/envoyproxy/gateway-crds-helm \
     --version <new-version> \
     | kubectl apply --server-side -f -
   ```
3. Upgrade the controller:
   ```bash
   helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
     --version <new-version> \
     -n envoy-gateway-system \
     -f values-production.yaml
   ```
4. Monitor controller logs and Gateway status during rollout
5. Verify all Gateways show `Programmed: True` after upgrade

#### 8c: Verification Commands

Provide a comprehensive verification checklist:

```bash
# 1. Controller health
kubectl get deployment envoy-gateway -n envoy-gateway-system
kubectl get pods -n envoy-gateway-system

# 2. GatewayClass accepted
kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'

# 3. Gateway programmed
kubectl describe gateway production-gw -n gateway-system

# 4. Envoy Proxy replicas
kubectl get deployment -l gateway.envoyproxy.io/owning-gateway-name=production-gw -n envoy-gateway-system

# 5. TLS certificate valid
kubectl get secret wildcard-tls -n gateway-system -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# 6. Policy status
kubectl get securitypolicy -A -o wide
kubectl get backendtrafficpolicy -A -o wide
kubectl get clienttrafficpolicy -A -o wide

# 7. End-to-end test
export GATEWAY_HOST=$(kubectl get gateway production-gw -n gateway-system -o jsonpath='{.status.addresses[0].value}')
curl -v https://app.example.com --resolve "app.example.com:443:$GATEWAY_HOST"
```

## Output Requirements

Generate a complete, production-ready set of Kubernetes manifests in this order:

1. Helm install command with production values file
2. cert-manager ClusterIssuer (if needed)
3. EnvoyProxy resource with scaling, resources, and telemetry
4. GatewayClass with parametersRef to EnvoyProxy
5. Gateway with HTTP + HTTPS listeners
6. HTTP-to-HTTPS redirect HTTPRoute
7. Application HTTPRoutes
8. ClientTrafficPolicy (TLS hardening, path normalization, connection limits)
9. SecurityPolicy (authentication, authorization, CORS)
10. BackendTrafficPolicy (health checks, circuit breaking, retries, rate limits)
11. Observability (access logging, metrics, tracing, alerting rules)
12. GitOps structure and ArgoCD/Flux manifests (if applicable)
13. Verification commands

## Guidelines

- Always pin the Envoy Gateway Helm chart version explicitly (default: `v1.3.0`).
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
