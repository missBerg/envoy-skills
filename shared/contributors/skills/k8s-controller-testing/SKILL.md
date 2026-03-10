---
name: k8s-controller-testing
description: Testing strategies for Kubernetes controllers — envtest, CEL validation testing, integration patterns, goroutine leak detection, and anti-patterns
---

# Kubernetes Controller Testing

Testing strategies for Kubernetes controllers using controller-runtime. Covers envtest (the recommended approach), CEL validation testing, integration patterns, and common pitfalls.

## Test Hierarchy

| Level | Tool | K8s Required | Purpose |
|-------|------|:------------:|---------|
| Unit | Standard Go `_test.go` | No | Test pure functions, business logic, transformations |
| CEL validation | envtest | API server only | Test CRD validation rules |
| Controller integration | envtest | API server + controllers | Test reconciler logic end-to-end |
| Data plane | Real binary (e.g., func-e) | No | Test data plane processing with real binaries |
| E2E | Kind cluster | Full stack | Test complete system with real infrastructure |

## envtest: The Recommended Approach

### envtest vs. Fake Client

Use **envtest for integration tests** (controllers, CEL validation, status subresource). The fake client is acceptable for **unit tests** of pure business logic that doesn't need server-side behavior, but should not be used for controller integration tests.

envtest provides:

| Feature | envtest | Fake Client |
|---------|---------|-------------|
| Server-side validation | Yes (real API server) | No |
| CEL rule evaluation | Yes | No |
| Field selectors | Yes | Limited |
| Watch events | Yes (real) | Simulated |
| Status subresource | Yes | Must configure |
| Admission webhooks | Yes | No |
| Index lookups | Yes | Must configure |
| Fidelity | Production-like | Approximation |

### envtest Setup

```go
package controller_test

import (
    "testing"

    "sigs.k8s.io/controller-runtime/pkg/envtest"
    "sigs.k8s.io/controller-runtime/pkg/client"

    myv1 "example.com/api/v1"
)

var (
    testEnv   *envtest.Environment
    k8sClient client.Client
)

func TestMain(m *testing.M) {
    // Start envtest
    testEnv = &envtest.Environment{
        CRDDirectoryPaths: []string{
            filepath.Join("..", "..", "config", "crd", "bases"),
        },
        ErrorIfCRDPathMissing: true,
    }

    cfg, err := testEnv.Start()
    if err != nil {
        panic(fmt.Sprintf("starting envtest: %v", err))
    }

    // Register scheme — always check errors
    scheme := runtime.NewScheme()
    if err := myv1.AddToScheme(scheme); err != nil {
        panic(fmt.Sprintf("adding custom scheme: %v", err))
    }
    if err := clientgoscheme.AddToScheme(scheme); err != nil {
        panic(fmt.Sprintf("adding client-go scheme: %v", err))
    }

    k8sClient, err = client.New(cfg, client.Options{Scheme: scheme})
    if err != nil {
        panic(fmt.Sprintf("creating client: %v", err))
    }

    // Run tests
    code := m.Run()

    // Teardown
    _ = testEnv.Stop()
    os.Exit(code)
}
```

### envtest with Controllers Running

For integration tests that need reconciliation:

```go
func TestMain(m *testing.M) {
    testEnv = &envtest.Environment{
        CRDDirectoryPaths: []string{"../../config/crd/bases"},
    }
    cfg, err := testEnv.Start()
    if err != nil {
        panic(fmt.Sprintf("starting envtest: %v", err))
    }

    // Start manager with controllers
    mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: scheme})
    if err != nil {
        panic(fmt.Sprintf("creating manager: %v", err))
    }
    if err := NewMyReconciler(mgr.GetClient(), mgr.GetScheme()).SetupWithManager(mgr); err != nil {
        panic(fmt.Sprintf("setting up reconciler: %v", err))
    }

    // NOTE: context.Background() is correct in TestMain — it runs before any
    // test function and t.Context() is not available. Use context.WithCancel
    // for clean shutdown.
    ctx, cancel := context.WithCancel(context.Background())
    go func() {
        if err := mgr.Start(ctx); err != nil {
            panic(fmt.Sprintf("starting manager: %v", err))
        }
    }()

    code := m.Run()

    cancel()
    _ = testEnv.Stop()
    os.Exit(code)
}
```

### Cross-Version Testing

Envoy Gateway tests across Kubernetes versions 1.32-1.35. Use matrix builds:

```yaml
# CI matrix
strategy:
  matrix:
    k8s-version: ["1.32", "1.33", "1.34", "1.35"]
env:
  ENVTEST_K8S_VERSION: ${{ matrix.k8s-version }}
```

## CEL Validation Testing

Test that CRD validation rules accept valid objects and reject invalid ones:

```go
func TestMyResourceCELValidation(t *testing.T) {
    tests := []struct {
        name      string
        obj       *myv1.MyResource
        wantError bool
        errMsg    string
    }{
        {
            name: "valid: all required fields present",
            obj: &myv1.MyResource{
                ObjectMeta: metav1.ObjectMeta{
                    Name:      "test-valid",
                    Namespace: "default",
                },
                Spec: myv1.MyResourceSpec{
                    BackendRef: myv1.BackendRef{Name: "my-backend"},
                },
            },
        },
        {
            name: "invalid: mutually exclusive fields",
            obj: &myv1.MyResource{
                ObjectMeta: metav1.ObjectMeta{
                    Name:      "test-invalid-exclusive",
                    Namespace: "default",
                },
                Spec: myv1.MyResourceSpec{
                    FieldA: ptr.To("value"),
                    FieldB: ptr.To("value"), // mutually exclusive with FieldA
                },
            },
            wantError: true,
            errMsg:    "mutually exclusive",
        },
        {
            name: "invalid: missing conditional required field",
            obj: &myv1.MyResource{
                ObjectMeta: metav1.ObjectMeta{
                    Name:      "test-invalid-conditional",
                    Namespace: "default",
                },
                Spec: myv1.MyResourceSpec{
                    Type: "APIKey",
                    // Missing apiKey field required when type is APIKey
                },
            },
            wantError: true,
            errMsg:    "apiKey is required",
        },
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            err := k8sClient.Create(t.Context(), tc.obj)
            if tc.wantError {
                require.Error(t, err)
                require.Contains(t, err.Error(), tc.errMsg)
            } else {
                require.NoError(t, err)
                // Clean up
                t.Cleanup(func() {
                    _ = k8sClient.Delete(t.Context(), tc.obj)
                })
            }
        })
    }
}
```

## Controller Integration Testing

### Async Reconciliation

Controllers are asynchronous — use `require.Eventually` (NEVER `time.Sleep`):

```go
func TestReconcilerCreatesOwnedResources(t *testing.T) {
    // Create the parent resource
    parent := &myv1.MyResource{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "test-parent",
            Namespace: "default",
        },
        Spec: myv1.MyResourceSpec{
            BackendRef: myv1.BackendRef{Name: "my-backend"},
        },
    }
    require.NoError(t, k8sClient.Create(t.Context(), parent))
    t.Cleanup(func() { _ = k8sClient.Delete(t.Context(), parent) })

    // Wait for reconciliation to create owned ConfigMap
    require.Eventually(t, func() bool {
        var cm corev1.ConfigMap
        err := k8sClient.Get(t.Context(), types.NamespacedName{
            Name:      "test-parent-config",
            Namespace: "default",
        }, &cm)
        return err == nil
    }, 10*time.Second, 100*time.Millisecond, "expected ConfigMap to be created")

    // Verify the ConfigMap has correct owner reference
    var cm corev1.ConfigMap
    require.NoError(t, k8sClient.Get(t.Context(), types.NamespacedName{
        Name:      "test-parent-config",
        Namespace: "default",
    }, &cm))
    require.Len(t, cm.OwnerReferences, 1)
    require.Equal(t, parent.Name, cm.OwnerReferences[0].Name)
}
```

### Status Condition Verification

```go
func TestReconcilerSetsStatusConditions(t *testing.T) {
    // Create resource
    obj := &myv1.MyResource{...}
    require.NoError(t, k8sClient.Create(t.Context(), obj))
    t.Cleanup(func() { _ = k8sClient.Delete(t.Context(), obj) })

    // Wait for Accepted condition
    require.Eventually(t, func() bool {
        var result myv1.MyResource
        if err := k8sClient.Get(t.Context(), client.ObjectKeyFromObject(obj), &result); err != nil {
            return false
        }
        for _, c := range result.Status.Conditions {
            if c.Type == "Accepted" && c.Status == metav1.ConditionTrue {
                return true
            }
        }
        return false
    }, 10*time.Second, 100*time.Millisecond)

    // Verify observedGeneration matches
    var result myv1.MyResource
    require.NoError(t, k8sClient.Get(t.Context(), client.ObjectKeyFromObject(obj), &result))
    for _, c := range result.Status.Conditions {
        if c.Type == "Accepted" {
            require.Equal(t, result.Generation, c.ObservedGeneration)
        }
    }
}
```

### Finalizer Testing

```go
func TestReconcilerHandlesFinalizer(t *testing.T) {
    obj := &myv1.MyResource{...}
    require.NoError(t, k8sClient.Create(t.Context(), obj))

    // Wait for finalizer to be added
    require.Eventually(t, func() bool {
        var result myv1.MyResource
        _ = k8sClient.Get(t.Context(), client.ObjectKeyFromObject(obj), &result)
        return ctrlutil.ContainsFinalizer(&result, "myresource.example.com/cleanup")
    }, 10*time.Second, 100*time.Millisecond)

    // Delete the object
    require.NoError(t, k8sClient.Delete(t.Context(), obj))

    // Wait for object to be fully removed (finalizer handled)
    require.Eventually(t, func() bool {
        var result myv1.MyResource
        err := k8sClient.Get(t.Context(), client.ObjectKeyFromObject(obj), &result)
        return apierrors.IsNotFound(err)
    }, 10*time.Second, 100*time.Millisecond)
}
```

## Goroutine Leak Detection

Both Envoy Gateway and AI Gateway enforce goroutine leak detection in every test package:

```go
import "go.uber.org/goleak"

func TestMain(m *testing.M) {
    goleak.VerifyNone(m)
}
```

This catches:
- Goroutines leaked by controllers that aren't properly shut down
- Unclosed channels or tickers
- Background goroutines started without proper lifecycle management

## Test Conventions

### Table-Driven Tests

```go
func TestTranslation(t *testing.T) {
    tests := []struct {
        name      string
        input     []byte
        expOutput []byte  // "exp" prefix for expected values
        expErr    string
    }{
        {
            name:      "valid input",
            input:     []byte(`{"model":"gpt-4o"}`),
            expOutput: []byte(`{"modelId":"gpt-4o"}`),
        },
        {
            name:   "missing required field",
            input:  []byte(`{}`),
            expErr: "missing model",
        },
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            output, err := translate(tc.input)
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

### Assertion Library

```go
// Use require for fatal assertions (test cannot continue without this)
require.NoError(t, err)
require.Equal(t, expected, actual)
require.Eventually(t, func() bool { ... }, timeout, interval)

// Use assert for non-fatal assertions (test can still provide useful info)
assert.Contains(t, output, "expected substring")

// Use t.Context() — never context.Background() in tests
ctx := t.Context()
```

### Naming Conventions

- Expected values use `exp` prefix: `expBody`, `expStatus`, `expPath`
- Test functions: `TestXxx_ScenarioDescription`
- Subtests: descriptive lowercase with spaces: `"valid: all fields present"`
- Test helpers: unexported, in `_test.go` files

## Anti-Patterns

| Anti-Pattern | Problem | Do This Instead |
|-------------|---------|----------------|
| `time.Sleep` for async operations | Slow, flaky | `require.Eventually` with polling |
| `context.Background()` in test functions | No timeout, no cancellation | `t.Context()` (except `TestMain` where `t` is unavailable) |
| Missing `goleak.VerifyNone` | Goroutine leaks go undetected | Add to `TestMain` in every package |
| Fake client for integration tests | Misses server-side validation, CEL | envtest for integration; fake acceptable for pure unit tests |
| Ignoring `AddToScheme` errors with `_` | Silent scheme registration failures | Check and `panic` on errors in `TestMain` |
| Hardcoded timeouts | Too short in CI, too long locally | Configurable with generous defaults |
| Not cleaning up test resources | State leaks between tests | `t.Cleanup()` or `defer` |
| Large test functions without subtests | Hard to identify failures | Table-driven `t.Run` |
| Not testing error paths | Only happy path covered | Include invalid input, missing fields |
| Real external services in CI | Flaky, slow, requires credentials | Mock servers or recorded responses |
| Checking exact error strings | Brittle across versions | `require.ErrorContains` for substrings |
