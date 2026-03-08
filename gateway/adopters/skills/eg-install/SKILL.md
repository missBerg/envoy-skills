---
name: eg-install
description: Install Envoy Gateway via Helm with production-ready configuration
arguments:
  - name: Version
    description: "Envoy Gateway version (e.g., v1.3.0). Defaults to latest stable."
    required: false
  - name: Namespace
    description: "Namespace for Envoy Gateway controller (default: envoy-gateway-system)"
    required: false
---

Install Envoy Gateway into a Kubernetes cluster using the official Helm chart with a pinned version. This skill generates the Helm install command, verifies the deployment, and confirms the GatewayClass is accepted by the controller.

## Instructions

### Step 1: Set variables

Determine the version and namespace. If the user did not provide values, use these defaults:

- **Version**: `v1.3.0` (latest stable release targeting Gateway API v1.2)
- **Namespace**: `envoy-gateway-system`

### Step 2: Install Envoy Gateway via Helm

Generate the Helm install command. The chart is hosted as an OCI artifact on Docker Hub.

```bash
# Install Envoy Gateway with Gateway API CRDs included
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${Version} \
  -n ${Namespace} \
  --create-namespace
```

The Helm chart bundles both the Gateway API CRDs (from the experimental channel, which includes TCPRoute, UDPRoute, TLSRoute, and BackendTLSPolicy) and the Envoy Gateway CRDs (ClientTrafficPolicy, BackendTrafficPolicy, SecurityPolicy, EnvoyProxy, etc.).

> **Note on CRD management**: If you need to manage CRDs separately (for example, to control the Gateway API channel or handle upgrades independently), install the CRDs chart first:
>
> ```bash
> helm template eg oci://docker.io/envoyproxy/gateway-crds-helm \
>   --version ${Version} \
>   --set crds.gatewayAPI.enabled=true \
>   --set crds.gatewayAPI.channel=standard \
>   --set crds.envoyGateway.enabled=true \
>   | kubectl apply --server-side -f -
>
> helm install eg oci://docker.io/envoyproxy/gateway-helm \
>   --version ${Version} \
>   -n ${Namespace} \
>   --create-namespace \
>   --skip-crds
> ```

### Step 3: Wait for the controller to become available

```bash
kubectl wait --timeout=5m -n ${Namespace} \
  deployment/envoy-gateway --for=condition=Available
```

### Step 4: Verify the GatewayClass

Apply a GatewayClass that references the Envoy Gateway controller:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  # This is the default controller name for Envoy Gateway.
  # Each Envoy Gateway installation manages exactly one controller name.
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

Check that the GatewayClass is accepted:

```bash
kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
# Expected output: True
```

If the status is not `True`, inspect conditions for details:

```bash
kubectl describe gatewayclass eg
```

### Step 5: Verify all pods are running

```bash
kubectl get pods -n ${Namespace}
```

All pods should be in `Running` state with `Ready` status.

### Production Helm values

For production deployments, consider these Helm value overrides:

```yaml
# values-production.yaml
deployment:
  replicas: 2                    # Run multiple controller replicas for HA
  envoyGateway:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1024Mi
podDisruptionBudget:
  maxUnavailable: 1              # Ensure at least one replica during disruptions
config:
  envoyGateway:
    logging:
      level:
        default: info            # Use 'debug' only for troubleshooting
```

Install with the production values file:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${Version} \
  -n ${Namespace} \
  --create-namespace \
  -f values-production.yaml
```

### Upgrading from a previous version

To upgrade an existing installation:

```bash
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${Version} \
  -n ${Namespace}
```

> **Important**: Review the release notes for your target version before upgrading. CRD changes may require manual steps. If you manage CRDs separately, update them before upgrading the controller:
>
> ```bash
> helm template eg oci://docker.io/envoyproxy/gateway-crds-helm \
>   --version ${Version} \
>   | kubectl apply --server-side -f -
> ```

### Warnings

- **Self-signed certificates in quickstart**: The quickstart manifest (`quickstart.yaml`) uses self-signed certificates and is intended for testing only. Never use the quickstart configuration in production. Use the `/eg-tls` skill with cert-manager for proper TLS.
- **Privileged ports**: When a Gateway listener uses a privileged port (below 1024, such as 80 or 443), Envoy Gateway maps it internally to an unprivileged port. The Envoy proxy does not require additional privileges, but be aware of this mapping when debugging.
- **LoadBalancer requirement**: If your cluster does not have a LoadBalancer implementation, the Gateway will not receive an external address. Consider installing MetalLB for bare-metal clusters.

## Checklist

- [ ] Helm install command completed without errors
- [ ] `envoy-gateway` deployment is Available in the target namespace
- [ ] GatewayClass shows `Accepted: True` in its status
- [ ] All pods in the Envoy Gateway namespace are Running and Ready
- [ ] For production: replicas, resource limits, and PDB are configured
- [ ] For upgrades: release notes reviewed and CRDs updated if needed
