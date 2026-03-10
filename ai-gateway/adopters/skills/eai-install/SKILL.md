---
name: eai-install
description: Install Envoy AI Gateway and Envoy Gateway with production-ready configuration for AI workloads
arguments:
  - name: AIGatewayVersion
    description: "Envoy AI Gateway version (e.g., v0.5.0). Defaults to latest stable."
    required: false
  - name: EnvoyGatewayVersion
    description: "Envoy Gateway version (e.g., v1.7.0). Must be v1.6.x+ for AI Gateway."
    required: false
  - name: Namespace
    description: "Namespace for AI Gateway controller (default: envoy-ai-gateway-system)"
    required: false
---

Install Envoy AI Gateway into a Kubernetes cluster. Envoy AI Gateway is built on top of Envoy Gateway and requires Envoy Gateway to be installed first. This skill generates the Helm install commands, verifies deployments, and confirms the setup is ready for AI workloads.

## Prerequisites

- Kubernetes cluster v1.32 or higher
- `kubectl` and `helm` installed
- Envoy Gateway is **not** yet installed (or use a clean cluster)

## Instructions

### Step 1: Set variables

Determine versions and namespace. If the user did not provide values, use these defaults:

- **AIGatewayVersion**: `v0.5.0` (latest stable)
- **EnvoyGatewayVersion**: `v1.7.0` (Envoy Gateway latest stable; AI Gateway requires v1.6.x+)
- **Namespace**: `envoy-ai-gateway-system`

### Step 2: Install Envoy Gateway with AI Gateway integration

Envoy AI Gateway extends Envoy Gateway. Install Envoy Gateway first with the AI Gateway-specific values file that enables the Backend API and extension manager:

```bash
helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${EnvoyGatewayVersion} \
  --namespace envoy-gateway-system \
  --create-namespace \
  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/manifests/envoy-gateway-values.yaml

kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

> **Note**: The `envoy-gateway-values.yaml` file enables `enableBackend: true`, `enableEnvoyPatchPolicy: true`, and configures the extension manager to connect to the AI Gateway controller. If you cannot fetch from GitHub, download the file locally and use `-f ./envoy-gateway-values.yaml`.

### Step 3: Install AI Gateway CRDs

Install the CRD Helm chart first:

```bash
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version ${AIGatewayVersion} \
  --namespace ${Namespace} \
  --create-namespace
```

### Step 4: Install AI Gateway controller

Install the AI Gateway Helm chart:

```bash
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version ${AIGatewayVersion} \
  --namespace ${Namespace} \
  --create-namespace

kubectl wait --timeout=5m -n ${Namespace} deployment/ai-gateway-controller --for=condition=Available
```

### Step 5: Update Envoy Gateway values for your environment

The `envoy-gateway-values.yaml` references the AI Gateway controller service. Ensure the FQDN matches your setup. Default:

```
ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local:1063
```

If you use a different namespace for AI Gateway, update the `config.envoyGateway.extensionManager.service.fqdn.hostname` in the Envoy Gateway values before or during install.

### Step 6: Verify installation

```bash
kubectl get pods -n envoy-gateway-system
kubectl get pods -n ${Namespace}
```

All pods should be in `Running` state with `Ready` status.

### Optional: Enable addons

For **token-based rate limiting** or **InferencePool** (self-hosted model routing), add the corresponding values when installing Envoy Gateway:

```bash
# With rate limiting and InferencePool addons
helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${EnvoyGatewayVersion} \
  -n envoy-gateway-system \
  --create-namespace \
  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/manifests/envoy-gateway-values.yaml \
  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/examples/token_ratelimit/envoy-gateway-values-addon.yaml \
  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/examples/inference-pool/envoy-gateway-values-addon.yaml
```

### Production Helm values for AI Gateway

For production, consider these overrides:

```yaml
# values-production.yaml
controller:
  replicas: 2
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1024Mi
extProc:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

Install with production values:

```bash
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version ${AIGatewayVersion} \
  -n ${Namespace} \
  --create-namespace \
  -f values-production.yaml
```

### Upgrading

To upgrade AI Gateway:

```bash
# Upgrade CRDs first
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version ${AIGatewayVersion} \
  -n ${Namespace}

# Then upgrade controller
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version ${AIGatewayVersion} \
  -n ${Namespace}
```

> **Important**: If you previously installed only `ai-gateway-helm` (without separate CRDs), first install the CRD chart with `--take-ownership` to transfer CRD ownership before upgrading.

### Warnings

- **Buffer limits**: AI workloads often need larger request/response buffers. Use Envoy Gateway's ClientTrafficPolicy to set `connection.bufferLimit` (e.g., `50Mi`) on your Gateway. See `/eai-route` for an example.
- **Envoy Gateway conflict**: Do not install Envoy AI Gateway alongside an existing Envoy Gateway that was installed without the AI Gateway values file. Use a fresh cluster or uninstall first.

## Checklist

- [ ] Envoy Gateway installed with `envoy-gateway-values.yaml`
- [ ] AI Gateway CRDs installed
- [ ] AI Gateway controller deployed and Available
- [ ] All pods in both namespaces are Running and Ready
- [ ] For production: replicas and resource limits configured
- [ ] For AI workloads: ClientTrafficPolicy with increased buffer limit applied to Gateway
