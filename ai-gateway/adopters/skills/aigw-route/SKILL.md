---
name: aigw-route
description: Create an AIGatewayRoute to bind AI backends to a Gateway with model-based routing
arguments:
  - name: GatewayName
    description: "Name of the Gateway to attach the route to"
    required: true
  - name: RouteName
    description: "Name for the AIGatewayRoute resource"
    required: false
  - name: ModelHeader
    description: "Value for x-ai-eg-model header match (e.g., gpt-4o-mini)"
    required: false
  - name: BackendNames
    description: "Comma-separated list of AIServiceBackend names"
    required: true
---

Create an AIGatewayRoute that attaches AI service backends to a Gateway. The route uses rules with matches (typically on `x-ai-eg-model` header) and backendRefs to route traffic. The AI Gateway ExtProc extracts the model name from the request body and injects it into `x-ai-eg-model` before routing—clients do not need to set this header. AI Gateway generates an HTTPRoute (same name) and HTTPRouteFilters (host rewrite, 404 fallback) from this.

## Instructions

### Step 1: Ensure Gateway has buffer limit for AI workloads

Envoy Gateway defaults to 32KiB buffer limit, which is too small for AI requests. Attach a ClientTrafficPolicy to your Gateway:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: client-buffer-limit
  namespace: default  # TODO: Match your Gateway namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GatewayName}  # TODO: Replace with your Gateway name
  connection:
    bufferLimit: 50Mi
```

### Step 2: Create the AIGatewayRoute

```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIGatewayRoute
metadata:
  name: ${RouteName}  # TODO: Replace with descriptive name (e.g., openai-route)
  namespace: default  # TODO: Match Gateway namespace
spec:
  parentRefs:
    - name: ${GatewayName}
      kind: Gateway
      group: gateway.networking.k8s.io
  rules:
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: ${ModelHeader}  # TODO: e.g., gpt-4o-mini, claude-3-5-sonnet
      backendRefs:
        - name: ${BackendNames}  # TODO: AIServiceBackend name(s)
```

### Step 3: Multiple backends (traffic splitting or failover)

**Traffic splitting** by weight:

```yaml
rules:
  - matches:
      - headers:
          - type: Exact
            name: x-ai-eg-model
            value: gpt-4o
    backendRefs:
      - name: openai-backend
        weight: 80
      - name: azure-openai-backend
        weight: 20
```

**Failover** by priority (lower number = higher priority):

```yaml
rules:
  - matches:
      - headers:
          - type: Exact
            name: x-ai-eg-model
            value: gpt-4o
    backendRefs:
      - name: primary-openai
        priority: 0
      - name: fallback-openai
        priority: 1
```

### Step 4: Catch-all for all models

To route all models to a single backend:

```yaml
rules:
  - backendRefs:
      - name: my-openai-backend
```

### Step 5: Timeouts for streaming

For streaming responses (e.g., chat completions with `stream: true`), increase the request timeout:

```yaml
rules:
  - matches:
      - headers:
          - type: Exact
            name: x-ai-eg-model
            value: gpt-4o
    timeouts:
      request: 300s  # 5 minutes for long streaming
    backendRefs:
      - name: openai-backend
```

### Step 6: Model name override

Override the model name sent to the backend:

```yaml
backendRefs:
  - name: azure-openai-backend
    modelNameOverride: gpt-4o  # Azure deployment name
```

### Step 7: InferencePool (self-hosted models)

For InferencePool backends (Gateway API Inference Extension; requires addon):

```yaml
backendRefs:
  - name: my-inference-pool
    group: inference.networking.k8s.io
    kind: InferencePool
```

**Constraints**: Only one InferencePool per rule; cannot mix InferencePool with AIServiceBackend in the same rule. Cross-namespace references require ReferenceGrant in the target namespace.

## Checklist

- [ ] ClientTrafficPolicy with bufferLimit (50Mi) attached to Gateway
- [ ] AIGatewayRoute parentRefs point to correct Gateway
- [ ] backendRefs reference existing AIServiceBackend (or InferencePool) resources
- [ ] Matches use x-ai-eg-model when routing by model
- [ ] Timeouts configured for streaming if needed
- [ ] Cross-namespace refs require ReferenceGrant in target namespace
