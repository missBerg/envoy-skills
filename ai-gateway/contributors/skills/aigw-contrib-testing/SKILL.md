---
name: aigw-contrib-testing
description: Test hierarchy, go-vcr recording, testcontainers, func-e data plane tests, coverage thresholds, and anti-patterns for envoyproxy/ai-gateway
---

# AI Gateway Testing Guide

## Test Hierarchy

| Level | Location | Command | K8s Required | Purpose |
|-------|----------|---------|:------------:|---------|
| Unit | `*_test.go` (same package) | `make test` | No | Test individual functions and types |
| CEL validation | `tests/crdcel/` | `make test-crdcel` | envtest | Test CRD validation rules |
| Controller | `tests/controller/` | `make test-controller` | envtest | Test reconciler logic with fake K8s |
| Data plane | `tests/data-plane/` | `make test-data-plane` | No | Test ExtProc with real Envoy (func-e) |
| E2E | `tests/e2e/` | `make test-e2e` | kind cluster | Full stack: EG + AI Gateway + Envoy |

## Unit Test Conventions

### Test Structure

```go
// Copyright Envoy AI Gateway Authors
// SPDX-License-Identifier: Apache-2.0
// The full text of the Apache license is available in the LICENSE file at
// the root of the repo.

package translators

import (
    "testing"

    "github.com/stretchr/testify/require"
)

func TestTranslateRequest(t *testing.T) {
    tests := []struct {
        name           string
        input          []byte
        expOutput      []byte
        expErr         string
    }{
        {
            name:      "valid chat completion",
            input:     []byte(`{"model":"gpt-4o","messages":[...]}`),
            expOutput: []byte(`{"modelId":"anthropic.claude-v2",...}`),
        },
        {
            name:   "missing model field",
            input:  []byte(`{"messages":[...]}`),
            expErr: "missing model",
        },
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            output, err := translateRequest(tc.input)
            if tc.expErr != "" {
                require.ErrorContains(t, err, tc.expErr)
                return
            }
            require.NoError(t, err)
            require.JSONEq(t, string(tc.expOutput), string(output))
        })
    }
}
```

### Key Conventions

- Use `require` for fatal assertions (test cannot continue without this passing)
- Use `assert` for non-fatal assertions (test can still provide useful info)
- Use `t.Context()` — never `context.Background()` in tests
- Use `exp` prefix for expected values: `expBody`, `expStatus`, `expPath`
- Table-driven tests with `name` field and `t.Run`
- `TestMain` in every package for goroutine leak detection:

```go
func TestMain(m *testing.M) {
    goleak.VerifyNone(m)
}
```

## go-vcr (HTTP Recording/Replay)

AI Gateway uses go-vcr to record real HTTP interactions with LLM providers and replay them in CI. This avoids flaky tests that depend on external APIs.

### How It Works

1. **Record mode**: Tests run against real provider APIs, HTTP exchanges are saved as "cassettes" (YAML files)
2. **Replay mode**: Tests use saved cassettes — no real HTTP calls, deterministic
3. Cassettes are committed to the repo

### Recording a New Cassette

```go
import "gopkg.in/dnaeon/go-vcr.v4/pkg/recorder"

func TestWithVCR(t *testing.T) {
    r, err := recorder.New("testdata/fixtures/my-test")
    require.NoError(t, err)
    defer r.Stop()

    client := &http.Client{Transport: r}
    // Use client to make requests — responses are recorded
}
```

### Updating Cassettes

Delete the cassette file and re-run the test in record mode with real API credentials.

## testcontainers-go

Used for tests that need real infrastructure (Redis, databases, etc.):

```go
import "github.com/testcontainers/testcontainers-go"

func TestWithRedis(t *testing.T) {
    ctx := t.Context()
    container, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
        ContainerRequest: testcontainers.ContainerRequest{
            Image:        "redis:7",
            ExposedPorts: []string{"6379/tcp"},
        },
        Started: true,
    })
    require.NoError(t, err)
    defer container.Terminate(ctx)
    // ...
}
```

## CEL Validation Tests

Test CRD validation rules using envtest (real API server, no controllers):

```go
// tests/crdcel/aigatewayroute_test.go
func TestAIGatewayRouteCELValidation(t *testing.T) {
    // envtest is set up in TestMain
    tests := []struct {
        name      string
        route     *aigv1a1.AIGatewayRoute
        wantError bool
    }{
        {
            name: "valid route",
            route: &aigv1a1.AIGatewayRoute{
                // ...valid spec
            },
        },
        {
            name: "invalid: missing parentRefs",
            route: &aigv1a1.AIGatewayRoute{
                // ...missing required field
            },
            wantError: true,
        },
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            err := k8sClient.Create(t.Context(), tc.route)
            if tc.wantError {
                require.Error(t, err)
            } else {
                require.NoError(t, err)
            }
        })
    }
}
```

## Controller Integration Tests

Test reconciler logic with envtest (real API server, your controllers running):

```go
// tests/controller/ai_gateway_route_test.go
func TestAIGatewayRouteReconciler(t *testing.T) {
    // Create test resources
    route := &aigv1a1.AIGatewayRoute{...}
    require.NoError(t, k8sClient.Create(t.Context(), route))

    // Wait for reconciliation
    require.Eventually(t, func() bool {
        var result aigv1a1.AIGatewayRoute
        err := k8sClient.Get(t.Context(), client.ObjectKeyFromObject(route), &result)
        return err == nil && result.Status.Conditions != nil
    }, 10*time.Second, 100*time.Millisecond)
}
```

## Data Plane Tests (func-e)

Test ExtProc translation with a real Envoy binary — no Kubernetes needed:

### How func-e Works

1. `func-e` downloads and runs a real Envoy binary locally
2. Test configures Envoy with an ExtProc filter pointing to your test ExtProc server
3. Send HTTP requests through Envoy → ExtProc processes them → verify output

### Test Structure

```go
// tests/data-plane/translation_test.go
//go:build test_data_plane

func TestOpenAIToAWSBedrock(t *testing.T) {
    // 1. Write filterapi.Config to temp file
    // 2. Start ExtProc server reading that config
    // 3. Start Envoy via func-e with ExtProc filter
    // 4. Send OpenAI-format request through Envoy
    // 5. Verify backend receives AWS Bedrock format
    // 6. Verify response is translated back to OpenAI format
}
```

### Build Tag

Data plane tests use build tag `test_data_plane`:

```go
//go:build test_data_plane
```

## Coverage Thresholds

| Scope | Threshold |
|-------|-----------|
| Per file | 70% |
| Per package | 81% |
| Total | 86% |
| Patch (new/changed lines) | 80% |

Run coverage: `make test-coverage`

## Anti-Patterns

| Anti-Pattern | Fix |
|-------------|-----|
| Using `encoding/json` in tests | Use `internal/json` — still banned in test files |
| Using `context.Background()` | Use `t.Context()` |
| Missing `goleak.VerifyNone(t)` in TestMain | Add to every package |
| `time.Sleep` in integration/e2e tests | Use `require.Eventually` or polling |
| Hardcoded API keys in test files | Use environment variables or go-vcr cassettes |
| Not testing streaming responses | Every translator needs SSE streaming tests |
| Not testing error cases | Add invalid input, missing fields, malformed JSON |
| Testing with real providers in CI | Use go-vcr cassettes for deterministic replay |
| Large test functions without subtests | Use table-driven `t.Run` for each case |
| Not cleaning up test resources | Use `t.Cleanup()` or `defer` |
