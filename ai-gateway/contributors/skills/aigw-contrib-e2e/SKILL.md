---
name: aigw-contrib-e2e
description: Write end-to-end tests for envoyproxy/ai-gateway — kind cluster setup, test manifests, mock providers, streaming assertions
arguments:
  - name: Feature
    description: "Feature to test (e.g., openai-bedrock-translation, model-routing, token-ratelimit)"
    required: true
  - name: TestType
    description: "Type of e2e test: basic, streaming, failover, auth"
    required: false
---

# E2E Tests

Write end-to-end tests that run against a real Kubernetes cluster with Envoy Gateway and AI Gateway installed.

## E2E Structure

```
tests/e2e/
├── e2e_test.go          # Test suite setup (kind cluster, EG, AI Gateway)
├── testdata/
│   ├── gateway.yaml     # Shared Gateway resources
│   ├── *.yaml           # Test-specific manifests
│   └── ...
├── ${feature}_test.go   # Feature-specific tests
└── ...
```

## Prerequisites

- `kind` installed
- `helm` installed
- `kubectl` installed
- Docker running

## Step 1: Test File Structure

Create `tests/e2e/${feature}_test.go`:

```go
// Copyright Envoy AI Gateway Authors
// SPDX-License-Identifier: Apache-2.0
// The full text of the Apache license is available in the LICENSE file at
// the root of the repo.

//go:build test_e2e

package e2e

import (
    "testing"

    "github.com/stretchr/testify/require"

    aigv1a1 "github.com/envoyproxy/ai-gateway/api/v1alpha1"
)

func Test${Feature}(t *testing.T) {
    // 1. Apply test manifests
    // 2. Wait for resources to be ready
    // 3. Send test requests
    // 4. Verify responses
    // 5. Clean up
}
```

### Build Tag

E2E tests use the `test_e2e` build tag:

```go
//go:build test_e2e
```

## Step 2: Test Manifests

Create manifests in `tests/e2e/testdata/${feature}.yaml`:

```yaml
# Backend for mock provider
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: mock-${provider}
  namespace: default
spec:
  endpoints:
    - fqdn:
        hostname: mock-${provider}.default.svc.cluster.local
        port: 8080
---
# AIServiceBackend
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIServiceBackend
metadata:
  name: mock-${provider}
  namespace: default
spec:
  schema:
    name: ${Schema}  # OpenAI, Anthropic, AWSBedrock, etc.
  backendRef:
    name: mock-${provider}
    kind: Backend
    group: gateway.envoyproxy.io
---
# AIGatewayRoute
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIGatewayRoute
metadata:
  name: test-${feature}-route
  namespace: default
spec:
  parentRefs:
    - name: test-gateway
      kind: Gateway
      group: gateway.networking.k8s.io
  rules:
    - backendRefs:
        - name: mock-${provider}
```

### BackendSecurityPolicy (if testing auth)

```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: BackendSecurityPolicy
metadata:
  name: mock-${provider}-auth
  namespace: default
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: mock-${provider}
  type: APIKey
  apiKey:
    secretRef:
      name: mock-api-key
      namespace: default
---
apiVersion: v1
kind: Secret
metadata:
  name: mock-api-key
  namespace: default
type: Opaque
stringData:
  apiKey: "test-key-for-e2e"
```

## Step 3: Mock Providers

E2E tests use mock HTTP servers that simulate LLM provider APIs:

```go
func startMockProvider(t *testing.T) {
    mux := http.NewServeMux()
    mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
        // Verify request format matches expected schema
        body, _ := io.ReadAll(r.Body)
        // ... validate request body

        // Return mock response
        w.Header().Set("Content-Type", "application/json")
        w.Write([]byte(`{
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "choices": [{
                "message": {"role": "assistant", "content": "Hello from mock"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5}
        }`))
    })
    // Deploy as a K8s Service in the test namespace
}
```

### Mock Streaming Provider

```go
mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "text/event-stream")
    flusher := w.(http.Flusher)

    chunks := []string{
        `{"id":"chatcmpl-test","choices":[{"delta":{"content":"Hello"}}]}`,
        `{"id":"chatcmpl-test","choices":[{"delta":{"content":" world"}}]}`,
    }
    for _, chunk := range chunks {
        fmt.Fprintf(w, "data: %s\n\n", chunk)
        flusher.Flush()
    }
    fmt.Fprint(w, "data: [DONE]\n\n")
    flusher.Flush()
})
```

## Step 4: Test Assertions

### Basic Request/Response

```go
func Test${Feature}_BasicRequest(t *testing.T) {
    // Apply manifests
    applyManifests(t, "testdata/${feature}.yaml")

    // Wait for route to be ready
    waitForRoute(t, "test-${feature}-route")

    // Send request
    resp := sendChatCompletion(t, gatewayURL, map[string]interface{}{
        "model":    "test-model",
        "messages": []map[string]string{{"role": "user", "content": "test"}},
    })

    require.Equal(t, 200, resp.StatusCode)
    // Verify response body
}
```

### Streaming Assertions

```go
func Test${Feature}_Streaming(t *testing.T) {
    resp := sendChatCompletion(t, gatewayURL, map[string]interface{}{
        "model":    "test-model",
        "stream":   true,
        "messages": []map[string]string{{"role": "user", "content": "test"}},
    })

    require.Equal(t, 200, resp.StatusCode)
    require.Equal(t, "text/event-stream", resp.Header.Get("Content-Type"))

    // Read SSE events
    events := readSSEEvents(t, resp.Body)
    require.Greater(t, len(events), 0)

    // Verify last event is [DONE]
    require.Equal(t, "[DONE]", events[len(events)-1])
}
```

### Model-Based Routing

```go
func Test${Feature}_ModelRouting(t *testing.T) {
    // Request with model A → should route to backend A
    respA := sendChatCompletion(t, gatewayURL, map[string]interface{}{
        "model":    "gpt-4o",
        "messages": []map[string]string{{"role": "user", "content": "test"}},
    })
    // Verify routed to correct backend

    // Request with model B → should route to backend B
    respB := sendChatCompletion(t, gatewayURL, map[string]interface{}{
        "model":    "claude-3-5-sonnet",
        "messages": []map[string]string{{"role": "user", "content": "test"}},
    })
    // Verify routed to correct backend
}
```

## Step 5: Run

```bash
make test-e2e
```

This sets up a kind cluster, installs EG + AI Gateway, runs all e2e tests, and tears down.

## Anti-Patterns

| Anti-Pattern | Fix |
|-------------|-----|
| `time.Sleep` for waiting | Use `require.Eventually` with polling |
| Hardcoded timeouts | Use configurable timeouts with generous defaults |
| Not cleaning up resources | Use `t.Cleanup()` to remove test manifests |
| Testing against real providers | Use mock HTTP servers deployed in-cluster |
| Not testing streaming | Always test both streaming and non-streaming paths |
| Missing error response tests | Test 4xx/5xx responses from backends |
| Not verifying request body at backend | Mock server should validate incoming request format |

## Checklist

- [ ] Test file with `//go:build test_e2e` tag and license header
- [ ] Test manifests in `tests/e2e/testdata/`
- [ ] Mock provider deployed (or reuse existing mock)
- [ ] Tests cover: basic request, streaming, error cases
- [ ] Model routing tested if applicable
- [ ] Auth injection verified if BackendSecurityPolicy used
- [ ] `require.Eventually` for async operations (not `time.Sleep`)
- [ ] `t.Cleanup` for resource teardown
- [ ] `make test-e2e` passes
