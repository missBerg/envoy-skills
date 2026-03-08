---
name: eg-contrib-testing
description: Testing patterns in envoyproxy/gateway — golden file tests for translators, e2e tests, conformance tests, CEL validation tests, and common pitfalls
---

# Envoy Gateway Testing Patterns

## Overview

| Test Type | Location | Purpose | Run Command |
|-----------|----------|---------|-------------|
| Gateway API translator unit | `internal/gatewayapi/` | Verify CRD → IR translation | `make go.test.unit` |
| xDS translator unit | `internal/xds/translator/` | Verify IR → xDS translation | `make go.test.unit` |
| CEL validation | `test/cel-validation/` | Verify CRD validation rules | `make go.test.cel` |
| E2E | `test/e2e/` | Verify end-to-end proxy behavior | `make e2e` |
| Conformance | `test/conformance/` | Gateway API spec compliance | `make conformance` |
| Benchmark | `test/gobench/` | Translation performance | `make go.test.benchmark` |
| Fuzz | `test/fuzz/` | Fuzz testing for critical paths | `make go.test.fuzz` |

## Gateway API Translator Tests (Golden Files)

These are the most common tests you will write. They verify that Gateway API resources translate correctly to IR.

### File Layout

```
internal/gatewayapi/testdata/
├── my-feature.in.yaml          # Input: Gateway API resources
├── my-feature.out.yaml         # Expected output: IR + status
├── my-feature-invalid.in.yaml  # Input: invalid configuration
└── my-feature-invalid.out.yaml # Expected: error status conditions
```

### Input File Format (.in.yaml)

The input file contains a `Resources` struct with Gateway API and EG resources:

```yaml
gateways:
  - apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    metadata:
      name: my-gateway
      namespace: default
    spec:
      gatewayClassName: envoy-gateway-class
      listeners:
        - name: http
          port: 80
          protocol: HTTP
httpRoutes:
  - apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: my-route
      namespace: default
    spec:
      parentRefs:
        - name: my-gateway
      rules:
        - matches:
            - path:
                value: /test
          backendRefs:
            - name: my-service
              port: 8080
backendTrafficPolicies:
  - apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: BackendTrafficPolicy
    metadata:
      name: my-policy
      namespace: default
    spec:
      targetRef:
        group: gateway.networking.k8s.io
        kind: HTTPRoute
        name: my-route
```

Available top-level keys in `.in.yaml`:
- `gateways`, `gatewayClasses`, `httpRoutes`, `grpcRoutes`, `tlsRoutes`, `tcpRoutes`, `udpRoutes`
- `services`, `namespaces`, `secrets`, `configMaps`, `referenceGrants`
- `backendTrafficPolicies`, `clientTrafficPolicies`, `securityPolicies`
- `envoyExtensionPolicies`, `envoyPatchPolicies`, `backends`
- `endpointSlices`, `backendTLSPolicies`

### Output File Format (.out.yaml)

The output contains gateways with status, xDS IR, and infra IR:

```yaml
gateways:
  - apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    metadata:
      name: my-gateway
      namespace: default
    status:
      conditions:
        - type: Accepted
          status: "True"
          reason: Accepted
        - type: Programmed
          status: "True"
          reason: Programmed
xdsIR:
  default/my-gateway:
    http:
      - name: default/my-gateway/http
        address: 0.0.0.0
        port: 10080
        routes:
          - name: httproute/default/my-route/rule/0/match/0/my-gateway-http
            hostname: "*"
            pathMatch:
              exact: /test
            destination:
              name: httproute/default/my-route/rule/0
              settings:
                - endpoints:
                    - host: 10.0.0.1
                      port: 8080
infraIR:
  default/my-gateway:
    proxy:
      metadata:
        labels:
          gateway.envoyproxy.io/owning-gateway-name: my-gateway
          gateway.envoyproxy.io/owning-gateway-namespace: default
      listeners:
        - address: null
          ports:
            - name: http-80
              protocol: HTTP
              containerPort: 10080
```

### Adding a Test Case

1. Create `internal/gatewayapi/testdata/my-feature.in.yaml` with input resources
2. Run `go test ./internal/gatewayapi/ -run TestTranslate -update` to generate the `.out.yaml`
3. Review the generated output for correctness
4. If special translator config is needed, add a test case entry in `translator_test.go`:

```go
{
    name:  "my-feature",
    // These flags enable optional translator features:
    // BackendEnabled: true,
    // EnvoyPatchPolicyEnabled: true,
}
```

### Updating Golden Files

After changing translation logic, golden files may be stale:

```bash
# Regenerate ALL gateway API translator golden files
go test ./internal/gatewayapi/ -run TestTranslate -update

# Or regenerate all golden files project-wide
make go.testdata.complete
```

**Always review the diff** after updating golden files. Unexpected changes indicate a bug.

## xDS Translator Tests (Golden Files)

These verify that IR translates correctly to xDS protobuf resources.

### File Layout

```
internal/xds/translator/testdata/
├── in/xds-ir/
│   └── my-feature.yaml         # Input: xDS IR YAML
└── out/xds-ir/
    ├── my-feature.listeners.yaml    # Expected: LDS output
    ├── my-feature.routes.yaml       # Expected: RDS output
    ├── my-feature.clusters.yaml     # Expected: CDS output
    ├── my-feature.endpoints.yaml    # Expected: EDS output
    └── my-feature.secrets.yaml      # Expected: SDS output
```

### Input File Format

The input is the xDS IR representation (same structure as `xdsIR` in gateway API test output):

```yaml
http:
  - name: default/my-gateway/http
    address: 0.0.0.0
    port: 10080
    hostnames:
      - "*"
    routes:
      - name: httproute/default/my-route/rule/0/match/0
        hostname: "*"
        pathMatch:
          exact: /test
        destination:
          name: httproute/default/my-route/rule/0
          settings:
            - endpoints:
                - host: 10.0.0.1
                  port: 8080
```

### Adding and Updating

```bash
# Create input file, then generate output
go test ./internal/xds/translator/ -run TestTranslateXds -update

# Output files are split by resource type (listeners, routes, clusters, endpoints, secrets)
```

The test uses `//go:embed testdata/out/*` and `//go:embed testdata/in/*` to load test fixtures.

## E2E Tests

E2E tests verify complete proxy behavior against a live Kubernetes cluster.

### File Structure

```go
// test/e2e/tests/my_feature.go
//go:build e2e

package tests

import (
    "testing"
    "k8s.io/apimachinery/pkg/types"
    gwapiv1 "sigs.k8s.io/gateway-api/apis/v1"
    "sigs.k8s.io/gateway-api/conformance/utils/http"
    "sigs.k8s.io/gateway-api/conformance/utils/kubernetes"
    "sigs.k8s.io/gateway-api/conformance/utils/suite"
)

func init() {
    ConformanceTests = append(ConformanceTests, MyFeatureTest)
}

var MyFeatureTest = suite.ConformanceTest{
    ShortName:   "MyFeature",
    Description: "Tests my feature behavior",
    Manifests:   []string{"testdata/my-feature.yaml"},
    Test: func(t *testing.T, suite *suite.ConformanceTestSuite) {
        ns := "gateway-conformance-infra"
        routeNN := types.NamespacedName{Name: "my-route", Namespace: ns}
        gwNN := types.NamespacedName{Name: "same-namespace", Namespace: ns}

        gwAddr := kubernetes.GatewayAndRoutesMustBeAccepted(
            t, suite.Client, suite.TimeoutConfig,
            suite.ControllerName,
            kubernetes.NewGatewayRef(gwNN),
            &gwapiv1.HTTPRoute{}, false, routeNN,
        )

        t.Run("should do expected behavior", func(t *testing.T) {
            expectedResponse := http.ExpectedResponse{
                Request: http.Request{
                    Path: "/test",
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
    },
}
```

### Key Functions

| Function | Purpose |
|----------|---------|
| `kubernetes.GatewayAndRoutesMustBeAccepted()` | Wait for Gateway + Route to be accepted |
| `http.MakeRequestAndExpectEventuallyConsistentResponse()` | Send request, poll until expected response |
| `SecurityPolicyMustBeAccepted()` | Wait for SecurityPolicy to be accepted (EG-specific) |

### E2E Registration

Tests are registered in `init()` by appending to one of:
- `ConformanceTests` — standard tests run in the main suite
- `UpgradeTests` — tests for upgrade scenarios
- `MergeGatewaysTests` — tests for merged gateway mode
- `MultipleGCTests` — tests for multiple GatewayClass scenarios

## CEL Validation Tests

Test CRD validation rules written in CEL expressions:

```go
// test/cel-validation/backendtrafficpolicy_test.go
func TestBackendTrafficPolicyValidation(t *testing.T) {
    tests := []struct {
        name    string
        policy  *egv1a1.BackendTrafficPolicy
        wantErr string
    }{
        {
            name: "mutually exclusive fields",
            policy: &egv1a1.BackendTrafficPolicy{
                // ... set mutually exclusive fields
            },
            wantErr: "only one of",
        },
    }
    // ...
}
```

## General Testing Conventions

### Libraries

```go
import (
    "github.com/stretchr/testify/require"  // Fatal assertions
    "github.com/stretchr/testify/assert"   // Non-fatal assertions
    "github.com/google/go-cmp/cmp"         // Detailed diffs
    "sigs.k8s.io/yaml"                     // YAML marshaling
    "k8s.io/utils/ptr"                     // Pointer helpers: ptr.To("value")
)
```

### Table-Driven Test Pattern

```go
func TestMyFeature(t *testing.T) {
    tests := []struct {
        name     string
        input    *ir.HTTPRoute
        expected *routev3.Route
    }{
        {
            name:     "basic case",
            input:    &ir.HTTPRoute{...},
            expected: &routev3.Route{...},
        },
        {
            name:     "nil optional field",
            input:    &ir.HTTPRoute{OptionalField: nil},
            expected: &routev3.Route{...},
        },
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result := translateRoute(tt.input)
            require.Equal(t, tt.expected, result)
        })
    }
}
```

## Testing Anti-Patterns

| Anti-Pattern | Why It Is Bad | Do This Instead |
|-------------|-------------|-----------------|
| `time.Sleep(5 * time.Second)` | Slow and flaky — fails on slow CI | Use `wait.PollImmediate` or conformance framework polling |
| Testing only the happy path | Reviewers reject insufficient coverage | Test invalid input, nil fields, missing references, edge cases |
| Not updating golden files | Tests pass with stale expectations | Run `make go.testdata.complete` after translation changes |
| Hard-coded resource names in e2e | Conflicts with parallel test runs | Use unique names per test or use the conformance namespace |
| Asserting exact error strings | Fragile — strings change | Assert error type or use `strings.Contains` for key phrases |
| Large test files (1000+ lines) | Hard to review and maintain | Split into helper functions or separate test files |
| Not testing policy at all levels | Policies can attach to Gateway OR Route | Test at both levels and verify most-specific-wins precedence |
