---
name: aigw-backend
description: Create an AIServiceBackend and Envoy Gateway Backend for an AI provider
arguments:
  - name: BackendName
    description: "Name for the AIServiceBackend and Backend resources"
    required: true
  - name: Schema
    description: "API schema: OpenAI, Anthropic, AWSBedrock, AzureOpenAI, GCPVertexAI, Cohere, etc."
    required: true
  - name: Hostname
    description: "FQDN or hostname for the backend (e.g., api.openai.com, bedrock-runtime.us-east-1.amazonaws.com)"
    required: true
  - name: Port
    description: "Port number (default: 443 for HTTPS)"
    required: false
---

Create an AIServiceBackend and the corresponding Envoy Gateway Backend resource. The AIServiceBackend defines the API schema (OpenAI, Anthropic, AWS Bedrock, etc.) and **must** reference an Envoy Gateway Backend via `backendRef`. It cannot reference a Kubernetes Service directly—use a Backend with FQDN endpoints (e.g., `my-svc.default.svc.cluster.local`) for in-cluster targets.

## Instructions

### Step 1: Create the Backend (Envoy Gateway)

The Backend specifies the external endpoint. For cloud providers, use HTTPS (port 443):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: ${BackendName}  # TODO: Replace with your backend name
  namespace: default
spec:
  endpoints:
    - fqdn:
        hostname: ${Hostname}  # TODO: e.g., api.openai.com, bedrock-runtime.us-east-1.amazonaws.com
        port: ${Port}  # TODO: 443 for HTTPS
```

### Step 2: Create the AIServiceBackend

```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
metadata:
  name: ${BackendName}
  namespace: default
spec:
  schema:
    name: ${Schema}  # TODO: OpenAI, Anthropic, AWSBedrock, AzureOpenAI, GCPVertexAI, Cohere, etc.
  backendRef:
    name: ${BackendName}
    kind: Backend
    group: gateway.envoyproxy.io
```

### Step 3: Add BackendTLSPolicy for HTTPS backends

For external HTTPS endpoints, attach a BackendTLSPolicy (use `gateway.networking.k8s.io/v1` with Envoy Gateway v1.6+):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: ${BackendName}-tls
  namespace: default
spec:
  targetRefs:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: ${BackendName}
  validation:
    wellKnownCACertificates: "System"
    hostname: ${Hostname}  # Must match the Backend hostname
```

### Step 4: Schema-specific notes

| Schema | Hostname examples | Notes |
|--------|-------------------|-------|
| OpenAI | api.openai.com | |
| Anthropic | api.anthropic.com | |
| AWSBedrock | bedrock-runtime.us-east-1.amazonaws.com | Region in hostname |
| AzureOpenAI | your-resource.openai.azure.com | |
| GCPVertexAI | {region}-aiplatform.googleapis.com | Requires BackendSecurityPolicy for region/project |
| Cohere | api.cohere.ai | |
| GCPAnthropic | {region}-aiplatform.googleapis.com | Anthropic on Vertex AI |
| AWSAnthropic | bedrock-runtime.us-east-1.amazonaws.com | Anthropic on Bedrock |

### Step 5: In-cluster backend (Kubernetes Service via Backend)

For a self-hosted model served by a Kubernetes Service, create a Backend with FQDN endpoints pointing to the service DNS. AIServiceBackend always references Backend, never Service directly:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: my-ollama-backend
  namespace: default
spec:
  endpoints:
    - fqdn:
        hostname: my-ollama-service.default.svc.cluster.local
        port: 80
---
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
metadata:
  name: my-ollama-backend
  namespace: default
spec:
  schema:
    name: OpenAI
  backendRef:
    name: my-ollama-backend
    kind: Backend
    group: gateway.envoyproxy.io
```

### Step 6: Custom prefix (e.g., Gemini OpenAI-compatible)

For backends with non-standard prefixes (e.g., Gemini uses `/v1beta/openai`):

```yaml
spec:
  schema:
    name: OpenAI
    prefix: "/v1beta/openai"
  backendRef:
    name: my-vertex-backend
    kind: Backend
    group: gateway.envoyproxy.io
```

### Step 7: Header and body mutation

Add header or body mutations at the backend level:

```yaml
spec:
  schema:
    name: OpenAI
  backendRef:
    name: my-backend
    kind: Backend
    group: gateway.envoyproxy.io
  headerMutation:
    set:
      - name: X-Custom-Header
        value: "custom-value"
  bodyMutation:
    set:
      - path: "model"
        value: "\"gpt-4o\""
```

## Checklist

- [ ] Backend created first; AIServiceBackend.backendRef references it (not K8s Service)
- [ ] Backend hostname and port correct
- [ ] AIServiceBackend schema matches provider API
- [ ] BackendTLSPolicy for HTTPS external endpoints
- [ ] BackendSecurityPolicy attached for cloud provider auth (see `/aigw-auth`)
- [ ] Prefix set if backend uses non-standard path
