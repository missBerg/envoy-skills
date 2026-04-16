---
name: eg-service-mesh
description: Integrate Envoy Gateway with Istio ambient mesh or Cilium for unified ingress and service mesh
---

# Envoy Gateway Service Mesh Integration

## Role

You help developers integrate Envoy Gateway with their service mesh (Istio or Cilium) for a unified traffic management experience. You assess the current state, configure the integration, and address the known challenges of running Envoy Gateway alongside a service mesh.

## Intake Interview

Before generating any configuration, ask the user these questions. Skip questions the user has already answered. Ask in a conversational tone, grouping related questions when it makes sense.

### Questions

1. **Service mesh**: Which service mesh are you using?
   - Istio sidecar mode (traditional sidecar proxy injection)
   - Istio ambient mode (ztunnel + waypoint proxies, no sidecars)
   - Cilium (eBPF-based service mesh)
   - Not yet decided (want guidance on which to choose)

2. **Current state**: Is the service mesh already installed, or are you setting up both?
   - Mesh is installed and running, adding Envoy Gateway
   - Setting up both from scratch
   - Migrating from another ingress controller to Envoy Gateway

3. **Gateway role**: Do you want Envoy Gateway as the ingress only, or also as a waypoint proxy for the mesh?
   - Ingress only (Envoy Gateway handles north-south traffic, mesh handles east-west)
   - Ingress + waypoint (Envoy Gateway serves both roles, ambient mode only)
   - Not sure (want guidance)

4. **mTLS**: Do you need mTLS between the gateway and mesh-managed services?
   - Yes, the gateway should participate in the mesh identity (SPIFFE/mTLS)
   - Yes, using BackendTLSPolicy with the mesh CA
   - No, trust the cluster network

5. **Observability**: What observability integration do you need?
   - Shared distributed tracing (same collector, correlated traces)
   - Shared metrics (same Prometheus, unified dashboards)
   - Separate observability stacks (gateway and mesh monitored independently)
   - Both shared tracing and metrics

## Workflow for Istio

### Phase 1: Current State Assessment

Check the cluster state to understand what is already installed.

```bash
# Check if Istio is installed
kubectl get namespace istio-system 2>/dev/null && echo "Istio namespace exists" || echo "No Istio namespace"

# Check Istio version and mode
istioctl version 2>/dev/null || echo "istioctl not found"

# Check for ambient mode (ztunnel DaemonSet)
kubectl get daemonset -n istio-system ztunnel 2>/dev/null && echo "Ambient mode detected" || echo "Ambient mode not detected"

# Check for sidecar injection
kubectl get namespace -l istio-injection=enabled 2>/dev/null

# Check if Envoy Gateway is already installed
kubectl get namespace envoy-gateway-system 2>/dev/null && echo "Envoy Gateway namespace exists" || echo "No EG namespace"
helm list -n envoy-gateway-system 2>/dev/null
```

### Phase 2: Install Envoy Gateway alongside Istio

Envoy Gateway and Istio can coexist in the same cluster. They use different controller names and manage different GatewayClass resources.

Use the `/eg-install` skill to install Envoy Gateway:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  -n envoy-gateway-system \
  --create-namespace
```

Verify both GatewayClasses exist and are accepted:

```bash
# Envoy Gateway's GatewayClass
kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
# Expected: True

# Istio's GatewayClass (if using Istio's Gateway API implementation)
kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null
```

Important: Envoy Gateway and Istio use different GatewayClass resources. Routes attached to a Gateway with `gatewayClassName: eg` are managed by Envoy Gateway. Routes attached to a Gateway with `gatewayClassName: istio` are managed by Istio. They do not conflict.

### Phase 3: Configure Gateway -- Sidecar vs Ambient

The traffic path differs significantly between Istio sidecar mode and ambient mode.

#### Istio Sidecar Mode

In sidecar mode, traffic flows through a double-proxy chain:

```
Client -> Envoy Gateway Proxy -> Istio Sidecar -> Application Pod
```

The Envoy Gateway proxy handles north-south concerns (TLS termination, auth, rate limiting), and the Istio sidecar handles east-west concerns (mTLS, authorization policy, telemetry).

**Gateway configuration (sidecar mode):**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress-gw
  namespace: gateway-system  # TODO: Replace with your namespace
spec:
  gatewayClassName: eg       # Managed by Envoy Gateway, NOT Istio
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"  # TODO: Replace
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: wildcard-tls
      allowedRoutes:
        namespaces:
          from: All
```

**Sidecar injection for the Envoy Gateway proxy itself:**

By default, Istio may inject a sidecar into the Envoy Gateway proxy pods. This creates an unnecessary triple-proxy scenario. Disable sidecar injection for the Envoy Gateway namespace:

```bash
kubectl label namespace envoy-gateway-system istio-injection=disabled --overwrite
```

Or use pod annotations on the EnvoyProxy resource:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: no-sidecar-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        pod:
          annotations:
            sidecar.istio.io/inject: "false"
```

#### Istio Ambient Mode

In ambient mode, there are no sidecars. Traffic flows through the ztunnel (L4) and optional waypoint proxies (L7):

```
Client -> Envoy Gateway Proxy -> ztunnel -> Application Pod
```

Or with a waypoint proxy:

```
Client -> Envoy Gateway Proxy -> ztunnel -> Waypoint Proxy -> Application Pod
```

Envoy Gateway can also serve as a waypoint proxy in ambient mode, providing a unified Envoy-based data plane for both ingress and in-mesh L7 processing.

Use the same Gateway configuration as sidecar mode above (the Gateway resource is identical for both modes).

**Enroll the application namespace in ambient mesh:**

```bash
kubectl label namespace app-namespace istio.io/dataplane-mode=ambient
```

### Phase 4: mTLS Integration

Configure the Envoy Gateway proxy to participate in the mesh's mTLS identity or to trust the mesh CA.

#### Option A: BackendTLSPolicy (trust the mesh CA)

Use BackendTLSPolicy so Envoy Gateway trusts the Istio CA when connecting to mesh-managed backends:

```yaml
# First, export the Istio root CA certificate
kubectl get secret istio-ca-secret -n istio-system -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > istio-root-ca.pem

# Create a ConfigMap with the Istio CA cert in the backend namespace.
# BackendTLSPolicy.caCertificateRefs is a LocalObjectReference, so the
# ConfigMap must live in the same namespace as the BackendTLSPolicy.
kubectl create configmap istio-root-ca \
  --from-file=ca.crt=istio-root-ca.pem \
  -n app-namespace  # TODO: Replace with backend namespace
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: mesh-backend-tls
  namespace: app-namespace  # TODO: Replace with backend namespace
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: my-app-service    # TODO: Replace with your backend service
      sectionName: "8080"     # TODO: Replace with your service port name
  validation:
    caCertificateRefs:
      - group: ""
        kind: ConfigMap
        name: istio-root-ca
    hostname: my-app-service.app-namespace.svc.cluster.local  # TODO: Replace with SPIFFE-compatible hostname
```

#### Option B: Mesh Identity Participation (ambient mode)

In Istio ambient mode, enroll the Envoy Gateway proxy namespace in the mesh so the ztunnel handles mTLS automatically:

```bash
kubectl label namespace envoy-gateway-system istio.io/dataplane-mode=ambient
```

This allows the Envoy Gateway proxy to communicate with mesh services through the ztunnel, which handles the mTLS handshake transparently.

### Phase 5: Shared Observability

Configure Envoy Gateway and Istio to use the same observability backends for correlated telemetry.

#### Shared Distributed Tracing

Both Envoy Gateway and Istio support OpenTelemetry. Configure them to export traces to the same collector.

**Envoy Gateway tracing (via EnvoyProxy):**

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: mesh-integrated-proxy
  namespace: envoy-gateway-system
spec:
  telemetry:
    tracing:
      provider:
        host: otel-collector.observability.svc.cluster.local  # TODO: Replace
        port: 4317
        type: OpenTelemetry
      samplingRate: 100  # TODO: Match Istio's sampling rate
      customTags:
        mesh.component:
          type: Literal
          literal:
            value: "envoy-gateway"
```

**Istio tracing (via MeshConfig or Telemetry API):**

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-tracing
  namespace: istio-system
spec:
  tracing:
    - providers:
        - name: otel
      randomSamplingPercentage: 100  # TODO: Match EG's sampling rate
```

Important: Both Envoy Gateway and Istio must propagate the same trace context headers (`traceparent`, `tracestate` for W3C Trace Context, or `x-b3-*` for Zipkin B3). Ensure your application also propagates these headers for end-to-end trace correlation.

#### Shared Metrics

Add Prometheus scrape annotations to the EnvoyProxy resource (`prometheus.io/scrape: "true"`, `prometheus.io/port: "19001"`) and enable `enableVirtualHostStats: true` in `spec.telemetry.metrics`. Istio metrics are already scraped by Prometheus if installed with default monitoring. Envoy Gateway metrics (prefixed with `envoy_`) can be correlated with Istio metrics by upstream/downstream cluster names.

### Phase 6: Known Limitations and Workarounds

Address the known challenges of running Envoy Gateway with a service mesh.

#### Double Proxying in Sidecar Mode

In Istio sidecar mode, traffic passes through two Envoy proxies: the Envoy Gateway proxy and the Istio sidecar. This adds latency (typically 1-3ms per hop) and complicates debugging.

**Mitigations:**
- Use Istio ambient mode instead of sidecar mode to eliminate the double-proxy pattern
- If sidecar mode is required, disable the sidecar on the Envoy Gateway proxy pods (as shown in Phase 3)
- Monitor the additional latency via tracing and adjust timeouts accordingly

#### Feature Overlap

Envoy Gateway and Istio both provide L7 traffic management features (routing, auth, rate limiting). Establish clear ownership:

| Concern | Owner | Rationale |
|---------|-------|-----------|
| TLS termination | Envoy Gateway | Edge responsibility |
| External authentication (JWT, OIDC) | Envoy Gateway | North-south concern |
| Rate limiting | Envoy Gateway | Edge protection |
| mTLS between services | Istio | East-west concern |
| Service-to-service authorization | Istio | Mesh identity-based |
| Retries, circuit breaking | Either | Choose one to avoid double retries |

Important: Do not configure retries in both Envoy Gateway and Istio for the same request path. This causes retry amplification (e.g., 3 retries x 3 retries = 9 total attempts). Choose one layer for retry logic.

#### Native Service Mesh Integration

As of Envoy Gateway v1.7.0, there is no native service mesh integration feature. The integration patterns described here use standard Kubernetes networking and Gateway API resources. For updates on native integration, see GitHub issue #7500 in the Envoy Gateway repository.

Istio ambient mode provides the best integration path because:
- No sidecar injection conflicts
- ztunnel handles mTLS transparently
- Envoy Gateway can potentially serve as a waypoint proxy
- Reduces the double-proxy overhead

## Workflow for Cilium

### Phase 1: Current State Assessment

```bash
# Check if Cilium is installed
kubectl get pods -n kube-system -l k8s-app=cilium
cilium status 2>/dev/null || echo "Cilium CLI not found"

# Check Cilium version and features
kubectl get configmap cilium-config -n kube-system -o yaml 2>/dev/null | grep -E "enable-|kube-proxy"
```

### Phase 2: Install Envoy Gateway with Cilium

Envoy Gateway works alongside Cilium as the CNI. If Cilium is providing LoadBalancer IPs via BGP, configure the EnvoyProxy to use Cilium's LoadBalancer class.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  -n envoy-gateway-system \
  --create-namespace
```

If using Cilium BGP for LoadBalancer IP allocation:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: cilium-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        # Use Cilium's BGP control plane for LoadBalancer IP allocation
        loadBalancerClass: io.cilium/bgp-control-plane  # TODO: Only if using Cilium BGP
```

### Phase 3: L4 vs L7 Considerations

Cilium's eBPF datapath handles L4 traffic very efficiently (kernel-level packet processing). Envoy Gateway adds L7 capabilities on top.

**Architecture:**
```
Client -> Cilium eBPF (L3/L4) -> Envoy Gateway Proxy (L7) -> Cilium eBPF (L3/L4) -> Application Pod
```

**When to use Envoy Gateway vs Cilium's built-in L7:**
- Use **Envoy Gateway** for: HTTP routing, JWT/OIDC auth, rate limiting, gRPC routing, request transformation, access logging, Wasm/ExtProc extensions
- Use **Cilium** for: L3/L4 network policies, DNS-aware policies, transparent encryption (WireGuard), service mesh without sidecars

Cilium also has its own Gateway API implementation (CEC - Cilium Envoy Config). If you only need basic HTTP routing, Cilium's built-in Gateway API support may be sufficient. Use Envoy Gateway when you need the full Envoy Gateway extension CRDs (SecurityPolicy, BackendTrafficPolicy, ClientTrafficPolicy, EnvoyExtensionPolicy).

### Phase 4: Network Policy Integration

Cilium NetworkPolicies complement Envoy Gateway SecurityPolicies at different layers.

**Cilium NetworkPolicy (L3/L4):**
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-gateway-to-app
  namespace: app-namespace  # TODO: Replace
spec:
  endpointSelector:
    matchLabels:
      app: my-app            # TODO: Replace with your app labels
  ingress:
    - fromEndpoints:
        - matchLabels:
            # Allow traffic only from Envoy Gateway proxy pods
            gateway.envoyproxy.io/owning-gateway-name: ingress-gw  # TODO: Replace
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```

For L7 authentication and authorization, use the `/eg-auth` skill to create SecurityPolicy resources targeting your HTTPRoutes.

**Defense in depth:** Use Cilium NetworkPolicies for L3/L4 network restrictions and Envoy Gateway SecurityPolicies for L7 authentication/authorization. This ensures that even if one layer is misconfigured, the other provides protection.

### Phase 5: Observability with Cilium

Cilium provides Hubble for network-level observability. Combine Hubble with Envoy Gateway's telemetry for full-stack visibility.

```bash
# Enable Hubble (if not already enabled)
cilium hubble enable --ui

# Observe traffic flowing through the gateway
hubble observe --namespace app-namespace --protocol http
```

Configure Envoy Gateway to export metrics and traces alongside Cilium:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: cilium-proxy
  namespace: envoy-gateway-system
spec:
  telemetry:
    metrics:
      enableVirtualHostStats: true
      sinks:
        - type: OpenTelemetry
          openTelemetry:
            host: otel-collector.observability.svc.cluster.local  # TODO: Replace
            port: 4317
    tracing:
      provider:
        host: otel-collector.observability.svc.cluster.local  # TODO: Replace
        port: 4317
        type: OpenTelemetry
      samplingRate: 10  # TODO: Adjust for production
```

## Output Requirements

Generate a complete set of Kubernetes manifests for the chosen integration:

1. Assessment commands to verify current cluster state
2. Envoy Gateway installation (Helm command)
3. Gateway and GatewayClass resources
4. EnvoyProxy customization for mesh integration
5. HTTPRoutes for application traffic
6. mTLS configuration (BackendTLSPolicy, ReferenceGrant, CA certificates)
7. Network policies (Cilium or Istio, as applicable)
8. Observability configuration (shared tracing, metrics)
9. Verification commands for end-to-end traffic flow
10. Documentation of known limitations and workarounds

## Guidelines

- Always pin the Envoy Gateway Helm chart version explicitly (default: `v1.7.0`).
- Use `gateway.networking.k8s.io/v1` for Gateway API resources and `gateway.envoyproxy.io/v1alpha1` for Envoy Gateway extension CRDs.
- Use kebab-case for all resource names.
- Include TODO comments in YAML for values the user must customize.
- Clearly identify which layer (Envoy Gateway vs. mesh) owns each concern to prevent overlap and conflict.
- Warn about retry amplification when both Envoy Gateway and the mesh configure retries.
- For Istio integration, recommend ambient mode over sidecar mode for better integration and lower latency.
- For Cilium integration, explain the L4/L7 boundary and when Envoy Gateway adds value over Cilium's built-in Gateway API support.
- Always disable Istio sidecar injection on the Envoy Gateway proxy pods to avoid triple-proxying.
