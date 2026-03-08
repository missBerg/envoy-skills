---
name: eg-contrib-e2e
description: Step-by-step guide to write an end-to-end test for an Envoy Gateway feature — test manifests, conformance framework, traffic assertions
arguments:
  - name: Feature
    description: "The feature to test (e.g., jwt authentication, circuit breaking, rate limiting)"
    required: true
  - name: TestType
    description: "One of: positive (happy path), negative (error handling), both"
    required: false
---

# Writing an Envoy Gateway E2E Test

## Prerequisites

- Read `eg-contrib-testing` for the overall testing patterns
- The feature implementation must be complete (translator + xDS translation + unit tests)
- E2E tests require a running Kubernetes cluster with Envoy Gateway installed

## Step 1: Create Test Manifests

File: `test/e2e/testdata/<feature>.yaml`

Include all Kubernetes resources needed for the test:

```yaml
# Gateway is typically already created by the test framework.
# Use the shared gateway "same-namespace" in "gateway-conformance-infra" namespace.

---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-feature-route
  namespace: gateway-conformance-infra
spec:
  parentRefs:
    - name: same-namespace
  rules:
    - matches:
        - path:
            value: /my-feature
      backendRefs:
        - name: infra-backend-v1
          port: 8080
---
# Add the policy resource that configures the feature
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: my-feature-policy
  namespace: gateway-conformance-infra
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-feature-route
  # feature-specific fields here
```

### Manifest Guidelines

- Use namespace `gateway-conformance-infra` — this is the standard test namespace
- Use gateway `same-namespace` — the shared test gateway
- Use backend `infra-backend-v1` on port 8080 — the standard echo backend
- Give resources unique names to avoid conflicts with other tests
- Include all policy resources that the test needs

## Step 2: Write the Test File

File: `test/e2e/tests/<feature>.go`

```go
// Copyright Envoy Gateway Authors
// SPDX-License-Identifier: Apache-2.0
// The full text of the Apache license is available in the LICENSE file at
// the root of the repo.

//go:build e2e

package tests

import (
    "testing"

    "k8s.io/apimachinery/pkg/types"
    gwapiv1 "sigs.k8s.io/gateway-api/apis/v1"
    "sigs.k8s.io/gateway-api/conformance/utils/http"
    "sigs.k8s.io/gateway-api/conformance/utils/kubernetes"
    "sigs.k8s.io/gateway-api/conformance/utils/suite"

    "github.com/envoyproxy/gateway/internal/gatewayapi"
    "github.com/envoyproxy/gateway/internal/gatewayapi/resource"
)

func init() {
    ConformanceTests = append(ConformanceTests, MyFeatureTest)
}

var MyFeatureTest = suite.ConformanceTest{
    ShortName:   "MyFeature",
    Description: "Test MyFeature behavior",
    Manifests:   []string{"testdata/my-feature.yaml"},
    Test: func(t *testing.T, suite *suite.ConformanceTestSuite) {
        ns := "gateway-conformance-infra"
        routeNN := types.NamespacedName{Name: "my-feature-route", Namespace: ns}
        gwNN := types.NamespacedName{Name: "same-namespace", Namespace: ns}

        // Wait for Gateway and Route to be accepted
        gwAddr := kubernetes.GatewayAndRoutesMustBeAccepted(
            t, suite.Client, suite.TimeoutConfig,
            suite.ControllerName,
            kubernetes.NewGatewayRef(gwNN),
            &gwapiv1.HTTPRoute{}, false, routeNN,
        )

        // If testing a policy, wait for it to be accepted
        ancestorRef := gwapiv1.ParentReference{
            Group:     gatewayapi.GroupPtr(gwapiv1.GroupName),
            Kind:      gatewayapi.KindPtr(resource.KindGateway),
            Namespace: gatewayapi.NamespacePtr(gwNN.Namespace),
            Name:      gwapiv1.ObjectName(gwNN.Name),
        }
        BackendTrafficPolicyMustBeAccepted(
            t, suite.Client,
            types.NamespacedName{Name: "my-feature-policy", Namespace: ns},
            suite.ControllerName, ancestorRef,
        )

        // Positive test: verify the feature works
        t.Run("should apply my feature correctly", func(t *testing.T) {
            expectedResponse := http.ExpectedResponse{
                Request: http.Request{
                    Path: "/my-feature",
                },
                Response: http.Response{
                    StatusCodes: []int{200},
                },
                Namespace: ns,
            }
            http.MakeRequestAndExpectEventuallyConsistentResponse(
                t, suite.RoundTripper, suite.TimeoutConfig,
                gwAddr, expectedResponse,
            )
        })

        // Negative test: verify error handling
        t.Run("should reject invalid request", func(t *testing.T) {
            expectedResponse := http.ExpectedResponse{
                Request: http.Request{
                    Path: "/my-feature",
                    Headers: map[string]string{
                        "X-Invalid": "true",
                    },
                },
                Response: http.Response{
                    StatusCodes: []int{403},
                },
                Namespace: ns,
            }
            http.MakeRequestAndExpectEventuallyConsistentResponse(
                t, suite.RoundTripper, suite.TimeoutConfig,
                gwAddr, expectedResponse,
            )
        })
    },
}
```

## Step 3: Register the Test

Tests are registered in `init()` by appending to the appropriate test slice:

| Test Category | Variable | When to Use |
|--------------|----------|-------------|
| Standard tests | `ConformanceTests` | Most feature tests |
| Upgrade tests | `UpgradeTests` | Tests for upgrade scenarios |
| Merge gateway tests | `MergeGatewaysTests` | Tests for merged gateway mode |
| Multi-GatewayClass tests | `MultipleGCTests` | Tests requiring multiple GatewayClasses |

```go
func init() {
    ConformanceTests = append(ConformanceTests, MyFeatureTest)
}
```

## Step 4: Asserting Responses

### Basic Status Code Check

```go
expectedResponse := http.ExpectedResponse{
    Request: http.Request{
        Path: "/test",
    },
    Response: http.Response{
        StatusCodes: []int{200},
    },
    Namespace: ns,
}
```

### Check Response Headers

```go
expectedResponse := http.ExpectedResponse{
    Request: http.Request{
        Path:   "/test",
        Method: "GET",
    },
    Response: http.Response{
        StatusCodes: []int{200},
        Headers: map[string]string{
            "x-custom-header": "expected-value",
        },
    },
    Namespace: ns,
}
```

### Check Absent Headers

```go
Response: http.Response{
    StatusCodes:    []int{200},
    AbsentHeaders: []string{"x-should-not-exist"},
},
```

### Send Request with Headers

```go
Request: http.Request{
    Path: "/test",
    Headers: map[string]string{
        "Authorization": "Bearer my-token",
        "X-Custom":      "value",
    },
},
```

### Send Preflight (OPTIONS) Request

```go
Request: http.Request{
    Path:   "/test",
    Method: "OPTIONS",
    Headers: map[string]string{
        "Origin":                        "https://example.com",
        "access-control-request-method": "GET",
    },
},
```

## Step 5: Policy Acceptance Helpers

EG provides helper functions to wait for policies to be accepted:

```go
// Wait for BackendTrafficPolicy
BackendTrafficPolicyMustBeAccepted(t, suite.Client, policyNN, suite.ControllerName, ancestorRef)

// Wait for SecurityPolicy
SecurityPolicyMustBeAccepted(t, suite.Client, policyNN, suite.ControllerName, ancestorRef)

// Wait for ClientTrafficPolicy
ClientTrafficPolicyMustBeAccepted(t, suite.Client, policyNN, suite.ControllerName, ancestorRef)

// Wait for EnvoyExtensionPolicy
EnvoyExtensionPolicyMustBeAccepted(t, suite.Client, policyNN, suite.ControllerName, ancestorRef)
```

## Step 6: Run the Tests

```bash
# Run all e2e tests (requires running cluster with EG)
make e2e

# Run a specific test
go test -v -tags e2e ./test/e2e/ -run TestE2E/MyFeature
```

## E2E Anti-Patterns

| Anti-Pattern | Why It Is Bad | Do This Instead |
|-------------|-------------|-----------------|
| `time.Sleep()` | Slow, flaky, fails on slow CI | Use `MakeRequestAndExpectEventuallyConsistentResponse` |
| Assuming resource creation order | Resources may reconcile in any order | Wait for acceptance with `MustBeAccepted` helpers |
| Not cleaning up resources | Manifests are auto-cleaned by framework | Just list them in `Manifests` field |
| Testing multiple features in one test | Hard to debug, unclear which feature failed | One test per feature |
| Using hard-coded IPs or ports | Breaks across environments | Use `gwAddr` from `GatewayAndRoutesMustBeAccepted` |
| Skipping negative tests | Misses error-handling bugs | Always test both success and failure cases |

## Checklist

- [ ] Test manifests created in `test/e2e/testdata/`
- [ ] Test file created in `test/e2e/tests/` with `//go:build e2e` tag
- [ ] Copyright header included
- [ ] Test registered in `init()` by appending to appropriate test slice
- [ ] Uses `MakeRequestAndExpectEventuallyConsistentResponse` for traffic assertions
- [ ] Waits for policy acceptance before sending traffic
- [ ] Tests both positive and negative cases (if applicable)
- [ ] No `time.Sleep()` calls — uses polling
- [ ] PR title: `test(e2e): add Feature e2e test`
