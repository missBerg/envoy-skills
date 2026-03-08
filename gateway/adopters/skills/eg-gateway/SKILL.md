---
name: eg-gateway
description: Create a Gateway resource with listeners for HTTP, HTTPS, or both
arguments:
  - name: Name
    description: "Gateway name (e.g., my-gateway)"
    required: true
  - name: Protocols
    description: "Comma-separated protocols: http, https, tls-passthrough, tcp, udp"
    required: false
---

Create a GatewayClass and Gateway resource for Envoy Gateway. The Gateway defines how traffic enters the cluster through one or more listeners. Each listener specifies a protocol, port, and optional hostname. This skill generates the correct listener configuration for HTTP, HTTPS, TLS passthrough, TCP, and UDP protocols.

## Instructions

### Step 1: Set variables

Determine the Gateway name and protocols. If the user did not provide values, use these defaults:

- **Name**: (required, no default)
- **Protocols**: `http` (if not specified)

Parse the `Protocols` argument into a list. Supported values: `http`, `https`, `tls-passthrough`, `tcp`, `udp`.

### Step 2: Generate the GatewayClass

Every Gateway references a GatewayClass. Generate this cluster-scoped resource if it does not already exist:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  # The controller name must match the Envoy Gateway installation.
  # This is the default value; change it only for multi-tenant deployments
  # where each tenant runs a separate Envoy Gateway controller.
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

> **When to use parametersRef**: If you need to customize the Envoy proxy configuration (resource limits, access logging, custom bootstrap), attach an EnvoyProxy resource via `parametersRef` on the GatewayClass or Gateway:
>
> ```yaml
> spec:
>   parametersRef:
>     group: gateway.envoyproxy.io
>     kind: EnvoyProxy
>     name: custom-proxy-config
>     namespace: default      # Required when set on GatewayClass
> ```

### Step 3: Generate the Gateway

Build the Gateway resource with listeners based on the requested protocols.

#### HTTP only

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${Name}
  namespace: default          # TODO: Change to your target namespace
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      # allowedRoutes controls which namespaces can attach Routes to this listener.
      # "Same" = only Routes in the Gateway's namespace. "All" = any namespace.
      allowedRoutes:
        namespaces:
          from: Same          # TODO: Change to "All" for cross-namespace routing
```

#### HTTPS only

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${Name}
  namespace: default          # TODO: Change to your target namespace
  annotations:
    # Uncomment to enable automatic certificate management with cert-manager.
    # See the /eg-tls skill for full cert-manager integration.
    # cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: eg
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      # hostname is required for cert-manager to issue certificates.
      # It also scopes which SNI values this listener accepts.
      hostname: "*.example.com"   # TODO: Set your domain
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: example-tls     # TODO: Name of the TLS Secret (cert-manager creates this)
      allowedRoutes:
        namespaces:
          from: All
```

#### HTTP + HTTPS (most common for production)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${Name}
  namespace: default          # TODO: Change to your target namespace
  annotations:
    # cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: eg
  listeners:
    # HTTP listener - typically used for HTTPS redirects
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    # HTTPS listener - primary traffic endpoint
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"   # TODO: Set your domain
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: example-tls     # TODO: Name of the TLS Secret
      allowedRoutes:
        namespaces:
          from: All
```

#### TLS Passthrough

For TLS passthrough, the Gateway does not terminate TLS. The encrypted stream passes directly to the backend, which handles TLS termination. Use TLSRoute (not HTTPRoute) with this mode.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${Name}
  namespace: default          # TODO: Change to your target namespace
spec:
  gatewayClassName: eg
  listeners:
    - name: tls-passthrough
      protocol: TLS
      port: 443
      hostname: "app.example.com" # TODO: SNI hostname for routing
      tls:
        mode: Passthrough
      allowedRoutes:
        kinds:
          - kind: TLSRoute       # Only TLSRoute is valid for Passthrough mode
        namespaces:
          from: All
```

#### TCP

TCP listeners forward raw TCP streams. Each TCP listener requires a unique port because there is no application-layer discriminator (no hostname or path matching).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${Name}
  namespace: default          # TODO: Change to your target namespace
spec:
  gatewayClassName: eg
  listeners:
    - name: tcp
      protocol: TCP
      port: 8088              # TODO: Set your TCP port
      allowedRoutes:
        kinds:
          - kind: TCPRoute    # Only TCPRoute is valid for TCP protocol
```

#### UDP

UDP listeners forward raw UDP datagrams. Like TCP, each listener requires a unique port.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${Name}
  namespace: default          # TODO: Change to your target namespace
spec:
  gatewayClassName: eg
  listeners:
    - name: udp
      protocol: UDP
      port: 5300              # TODO: Set your UDP port
      allowedRoutes:
        kinds:
          - kind: UDPRoute    # Only UDPRoute is valid for UDP protocol
```

### Step 4: Apply and verify

```bash
kubectl apply -f gateway.yaml
kubectl get gateway/${Name} -o yaml
```

Check the Gateway status. All listeners should show `Accepted: True` and `Programmed: True`:

```bash
kubectl describe gateway/${Name}
```

Get the Gateway's external address (once a LoadBalancer is provisioned):

```bash
export GATEWAY_HOST=$(kubectl get gateway/${Name} -o jsonpath='{.status.addresses[0].value}')
echo "Gateway address: $GATEWAY_HOST"
```

### Listener design guidance

**When to use multiple listeners on one Gateway:**
- HTTP + HTTPS on the same domain (common pattern for HTTPS redirect)
- Multiple HTTPS domains sharing the same external IP
- A mix of HTTP/HTTPS listeners on standard ports

**When to use separate Gateways:**
- Different security boundaries (e.g., public vs internal)
- Different infrastructure requirements (different EnvoyProxy configurations, different Service types)
- TCP/UDP services that need dedicated ports with no listener contention
- Multi-tenant isolation where each tenant manages their own Gateway

**Listener isolation**: Each listener has independent `allowedRoutes` configuration. You can restrict which Route types and namespaces can attach to each listener. This provides fine-grained access control:

```yaml
allowedRoutes:
  kinds:
    - kind: HTTPRoute         # Only allow HTTPRoute, not GRPCRoute
  namespaces:
    from: Selector
    selector:
      matchLabels:
        gateway-access: "true"  # Only namespaces with this label
```

### Cross-namespace references

If the TLS Secret referenced by `certificateRefs` is in a different namespace than the Gateway, you must create a ReferenceGrant in the Secret's namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-secret-ref
  namespace: cert-namespace   # TODO: Namespace where the Secret lives
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: default      # TODO: Namespace where the Gateway lives
  to:
    - group: ""
      kind: Secret
```

## Checklist

- [ ] GatewayClass exists and shows `Accepted: True`
- [ ] Gateway is created with listeners matching the requested protocols
- [ ] All Gateway listeners show `Accepted: True` and `Programmed: True`
- [ ] Gateway has an external address assigned (for LoadBalancer-backed clusters)
- [ ] HTTPS listeners reference a valid TLS Secret (or cert-manager annotation is set)
- [ ] `allowedRoutes` is configured appropriately for namespace and Route type restrictions
- [ ] For cross-namespace Secret references: ReferenceGrant is in place
