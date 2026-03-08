---
name: eg-extension
description: Extend Envoy Gateway with ExtProc, Wasm, or Lua extensions via EnvoyExtensionPolicy
arguments:
  - name: Type
    description: "Extension type: extproc, wasm, lua (default: extproc)"
    required: false
  - name: Name
    description: "Extension name for the resource"
    required: false
---

# Envoy Gateway Extensions

Generate EnvoyExtensionPolicy resources to extend Envoy Gateway's data plane with
External Processing (ExtProc), WebAssembly (Wasm), or Lua extensions. Also covers
EnvoyPatchPolicy for direct xDS patching as a last resort.

## Instructions

### Step 1: Determine Extension Type and Target

Ask the user:
1. Which extension type: **ExtProc** (recommended), **Wasm**, or **Lua**?
2. What should the extension do? (e.g., add headers, transform requests, custom auth)
3. What resource should it target: Gateway, HTTPRoute, or Backend?

### Step 2a: External Processing (ExtProc)

ExtProc is the most powerful and production-ready extension mechanism. It calls an
external gRPC service that can inspect and mutate requests and responses. AI Gateway
uses ExtProc for model routing and token tracking.

#### Deploy the ExtProc gRPC service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ext-proc-service  # TODO: rename to your service name
  labels:
    app: ext-proc-service
spec:
  replicas: 2  # TODO: adjust for your availability requirements
  selector:
    matchLabels:
      app: ext-proc-service
  template:
    metadata:
      labels:
        app: ext-proc-service
    spec:
      containers:
        - name: ext-proc
          image: my-registry/my-ext-proc:latest  # TODO: replace with your ExtProc image
          ports:
            - containerPort: 9002
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ext-proc-service  # TODO: match the Deployment name
spec:
  selector:
    app: ext-proc-service
  ports:
    - port: 9002
      targetPort: 9002
      protocol: TCP
```

#### Configure EnvoyExtensionPolicy for ExtProc

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: ext-proc-policy  # TODO: choose a descriptive name
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute          # Target: Gateway, HTTPRoute, or Backend
      name: my-route           # TODO: replace with your target resource name
  extProc:
    - backendRefs:
        - name: ext-proc-service  # Must match the Service name above
          port: 9002
      # Processing modes control what gets sent to the external processor.
      # By default, nothing is sent. An empty object {} sends headers only.
      processingMode:
        request: {}            # Send request headers to the processor
        response:
          body: Streamed       # Options: Buffered, Streamed, or omit to skip body
      # messageTimeout is the max time to wait for the processor to respond.
      # Default: 200ms. Increase for expensive processing (e.g., body inspection).
      messageTimeout: 1s       # TODO: tune based on your processor's latency
      # failOpen: true bypasses the processor on errors instead of returning 5xx.
      # Set to false (default) for critical processing like auth or compliance.
      failOpen: false          # TODO: set to true for non-critical extensions
```

**Processing mode options:**
- `request: {}` -- send request headers only
- `request: { body: Buffered }` -- buffer entire request body, send headers + body
- `request: { body: Streamed }` -- stream request body chunks to processor
- `response: {}` -- send response headers only
- `response: { body: Buffered }` -- buffer entire response body
- `response: { body: Streamed }` -- stream response body chunks

**Use cases for ExtProc:**
- Request transformation (rewrite headers, modify body)
- Custom authentication and authorization
- Content inspection and redaction (PII, compliance)
- AI Gateway model routing and token tracking
- Request/response logging and auditing

### Step 2b: Wasm Extension

Wasm extensions run in-process inside Envoy for high performance. They can be loaded
from an HTTP URL or an OCI image registry.

#### Wasm from HTTP URL

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: wasm-http-policy  # TODO: choose a descriptive name
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route       # TODO: replace with your target resource name
  wasm:
    - name: my-wasm-filter   # TODO: unique name for this Wasm extension
      rootID: my_root_id     # TODO: must match the root_id registered in your Wasm code
      code:
        type: HTTP
        http:
          url: https://example.com/path/to/my-filter.wasm  # TODO: replace with your Wasm URL
          sha256: abc123...  # TODO: sha256 checksum of the Wasm binary for integrity
      # Optional: pass JSON configuration to the Wasm extension
      # config:
      #   key: value
      failOpen: false  # TODO: set to true for non-critical extensions
```

#### Wasm from OCI Image

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: wasm-oci-policy  # TODO: choose a descriptive name
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route       # TODO: replace with your target resource name
  wasm:
    - name: my-wasm-filter
      rootID: my_root_id   # TODO: must match the root_id in your Wasm code
      code:
        type: Image
        image:
          url: my-registry.example.com/my-wasm:v1.0.0  # TODO: OCI image reference
          # For private registries, reference a pull secret:
          # pullSecretRef:
          #   name: my-registry-secret
      # config:
      #   key: value
      failOpen: false
```

**Wasm languages:** Rust, C++, AssemblyScript, TinyGo (any language that compiles to Wasm).

**Use cases for Wasm:**
- Custom header injection or modification
- Request/response body transformation
- Custom observability and metrics
- WAF rules (e.g., Coraza WAF via Wasm)

**Building Wasm OCI images:**
```dockerfile
FROM scratch
COPY plugin.wasm ./
```
Build and push: `docker build -t my-registry/my-wasm:v1.0.0 . && docker push my-registry/my-wasm:v1.0.0`

### Step 2c: Lua Extension

Lua extensions provide lightweight inline scripting. They are the simplest extension
mechanism but have limited functionality compared to ExtProc and Wasm.

#### Inline Lua Script

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: lua-inline-policy  # TODO: choose a descriptive name
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route         # TODO: replace with your target resource name
  lua:
    - type: Inline
      inline: |
        function envoy_on_request(request_handle)
          -- TODO: add your request processing logic
          request_handle:headers():add("x-custom-header", "added-by-lua")
        end
        function envoy_on_response(response_handle)
          -- TODO: add your response processing logic
          response_handle:headers():add("x-response-custom", "added-by-lua")
        end
```

#### Lua Script from ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-lua-script  # TODO: choose a descriptive name
data:
  lua: |
    function envoy_on_response(response_handle)
      response_handle:headers():add("x-custom-header", "from-configmap")
    end
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: lua-valueref-policy
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route         # TODO: replace with your target resource name
  lua:
    - type: ValueRef
      valueRef:
        name: my-lua-script  # Must match the ConfigMap name
        kind: ConfigMap
        group: v1
```

**Lua limitations:**
- Only `envoy_on_request` and `envoy_on_response` entry points
- Limited API surface compared to ExtProc or Wasm
- No persistent state between requests
- Single-threaded execution within the Envoy worker thread
- Best suited for simple header manipulation and lightweight transforms

### Step 3: EnvoyPatchPolicy (Last Resort)

EnvoyPatchPolicy allows direct JSON Patch operations on Envoy xDS resources. Use this
only when the feature you need is not exposed by any higher-level CRD.

**WARNING:** EnvoyPatchPolicy can break Envoy functionality and poses serious security
risks. It must be explicitly enabled in the EnvoyGateway configuration and should be
restricted via Kubernetes RBAC.

#### Enable EnvoyPatchPolicy

```yaml
# Update the envoy-gateway-config ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-gateway-config
  namespace: envoy-gateway-system
data:
  envoy-gateway.yaml: |
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyGateway
    provider:
      type: Kubernetes
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
    extensionApis:
      enableEnvoyPatchPolicy: true
```

#### Example: Add custom local reply configuration

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyPatchPolicy
metadata:
  name: custom-response-patch  # TODO: choose a descriptive name
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: eg                   # TODO: replace with your Gateway name
  type: JSONPatch
  priority: 0                  # Lower number = higher priority
  jsonPatches:
    - type: "type.googleapis.com/envoy.config.listener.v3.Listener"
      name: "default/eg/http"  # TODO: use egctl x translate to find the xDS resource name
      operation:
        op: add
        path: "/default_filter_chain/filters/0/typed_config/local_reply_config"
        value:
          mappers:
            - filter:
                status_code_filter:
                  comparison:
                    op: EQ
                    value:
                      default_value: 404
              body:
                inline_string: "Resource not found"
```

**Finding xDS resource names:** Use `egctl x translate` to inspect the generated xDS
and identify the correct resource names and paths for your patches.

### Step 4: Choosing the Right Extension Mechanism

| Mechanism | Flexibility | Performance | Complexity | When to Use |
|-----------|------------|-------------|------------|-------------|
| **ExtProc** | Highest | Good (out-of-process gRPC) | Medium | Complex logic, any language, production-critical |
| **Wasm** | High | Best (in-process) | Higher (requires Wasm compilation) | Performance-sensitive, custom headers, WAF |
| **Lua** | Limited | Good (in-process) | Lowest | Simple header manipulation, quick prototyping |
| **EnvoyPatchPolicy** | Full xDS access | N/A | Highest (xDS expertise required) | Features not exposed by any other API |

**Recommendation:** Start with ExtProc for most use cases. It is language-agnostic,
runs out-of-process (so crashes do not affect Envoy), and is the mechanism used by
Envoy AI Gateway for production workloads.

## Checklist

- [ ] EnvoyExtensionPolicy targets the correct resource (Gateway, HTTPRoute, or Backend)
- [ ] Policy and target are in the **same namespace**
- [ ] For ExtProc: gRPC service Deployment and Service are deployed and healthy
- [ ] For ExtProc: `processingMode` explicitly declares which headers/bodies to send
- [ ] For ExtProc: `messageTimeout` is tuned for your processor's expected latency
- [ ] For ExtProc: `failOpen` is set appropriately (false for critical, true for optional)
- [ ] For Wasm: `rootID` matches the root_id registered in the Wasm code
- [ ] For Wasm from HTTP: `sha256` checksum is provided for integrity verification
- [ ] For Wasm from OCI: image URL and optional `pullSecretRef` are correct
- [ ] For Lua: script uses `envoy_on_request` and/or `envoy_on_response` entry points
- [ ] For EnvoyPatchPolicy: `enableEnvoyPatchPolicy: true` is set in EnvoyGateway config
- [ ] For EnvoyPatchPolicy: RBAC restricts who can create EnvoyPatchPolicy resources
- [ ] Verify policy status: `kubectl get envoyextensionpolicy <name> -o yaml` shows `Accepted: True`
- [ ] Test the extension by sending requests and verifying expected behavior
