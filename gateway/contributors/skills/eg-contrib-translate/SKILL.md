---
name: eg-contrib-translate
description: Step-by-step guide to implement Gateway API to IR and IR to xDS translation for a new feature in envoyproxy/gateway
arguments:
  - name: Feature
    description: "The feature being translated (e.g., retry budget, request buffering, connection pool)"
    required: true
  - name: CRDName
    description: "The CRD that configures this feature (e.g., BackendTrafficPolicy, SecurityPolicy)"
    required: true
  - name: PolicyType
    description: "One of: BackendTrafficPolicy, ClientTrafficPolicy, SecurityPolicy, EnvoyExtensionPolicy"
    required: true
---

# Implementing Translation for a New Feature

## Prerequisites

- The API types already exist (see `eg-contrib-add-api`) — API changes must be in a separate PR
- Read `eg-contrib-architecture` — understand the pipeline: CRD → IR → xDS
- Read `eg-contrib-envoy-internals` — understand how Envoy uses the xDS config you generate

## Phase 1: Add IR Types

File: `internal/ir/xds.go`

### 1.1 Define the IR struct

The IR should represent the **intent** of the feature, not the Envoy xDS structure. It is Envoy-agnostic.

```go
// MyFeature holds the intermediate representation for MyFeature configuration.
type MyFeature struct {
    // Enabled indicates whether MyFeature is active.
    Enabled bool `json:"enabled" yaml:"enabled"`

    // Mode specifies the operating mode.
    Mode string `json:"mode,omitempty" yaml:"mode,omitempty"`

    // Threshold is the numeric limit.
    Threshold *int32 `json:"threshold,omitempty" yaml:"threshold,omitempty"`
}
```

### 1.2 Add the field to the appropriate parent struct

Where to add depends on the policy type:

| Policy Type | IR Parent Struct | Why |
|------------|-----------------|-----|
| BackendTrafficPolicy | `HTTPRoute` or `TrafficFeatures` | Affects per-route backend behavior |
| ClientTrafficPolicy | `HTTPListener` | Affects listener/connection settings |
| SecurityPolicy | `HTTPRoute` or `SecurityFeatures` | Affects per-route security |
| EnvoyExtensionPolicy | `HTTPRoute` | Affects per-route extension behavior |

```go
type HTTPRoute struct {
    // ... existing fields ...

    // MyFeature defines MyFeature settings for this route.
    MyFeature *MyFeature `json:"myFeature,omitempty" yaml:"myFeature,omitempty"`
}
```

### 1.3 Critical: Use slices, not maps

**Never use `map` types in IR structs.** Map iteration order is non-deterministic, which causes `DeepEqual` to produce spurious diffs and unnecessary xDS updates.

```go
// BAD — causes non-deterministic DeepEqual
type MyFeature struct {
    Tags map[string]string
}

// GOOD — deterministic ordering
type MyFeature struct {
    Tags []TagEntry
}

type TagEntry struct {
    Key   string `json:"key" yaml:"key"`
    Value string `json:"value" yaml:"value"`
}
```

### 1.4 Run code generation

```bash
make generate
```

This regenerates `internal/ir/zz_generated.deepcopy.go` with DeepCopy methods for new types.

## Phase 2: Gateway API Translation

File: `internal/gatewayapi/<policytype>.go` (e.g., `backendtrafficpolicy.go`, `securitypolicy.go`)

### 2.1 Find the translation function

Each policy type has a `build*` function that translates CRD fields to IR:

| Policy Type | Translation Function | File |
|------------|---------------------|------|
| BackendTrafficPolicy | `buildBackendTrafficPolicy()` | `backendtrafficpolicy.go` |
| ClientTrafficPolicy | `buildClientTrafficPolicy()` | `clienttrafficpolicy.go` |
| SecurityPolicy | `buildSecurityPolicy()` | `securitypolicy.go` |
| EnvoyExtensionPolicy | `buildEnvoyExtensionPolicy()` | `envoyextensionpolicy.go` |

### 2.2 Add translation logic

Inside the appropriate `build*` function, add the translation from CRD to IR:

```go
func (t *Translator) buildMyFeature(policy *egv1a1.BackendTrafficPolicy) (*ir.MyFeature, error) {
    if policy.Spec.MyFeature == nil {
        return nil, nil
    }

    myFeature := &ir.MyFeature{
        Enabled: ptr.Deref(policy.Spec.MyFeature.Enabled, false),
    }

    if policy.Spec.MyFeature.Mode != nil {
        myFeature.Mode = string(*policy.Spec.MyFeature.Mode)
    }

    if policy.Spec.MyFeature.Threshold != nil {
        myFeature.Threshold = policy.Spec.MyFeature.Threshold
    }

    return myFeature, nil
}
```

### 2.3 Handle policy attachment (most-specific-wins)

Policies can attach at multiple levels. The precedence is:

```
Route Rule level > Route level > Listener level > Gateway level
```

The framework handles precedence automatically for established policy types. Your translation function is called with the resolved policy for each target.

### 2.4 Set status conditions on error

If the configuration is invalid, set status conditions:

```go
if err := validateMyFeature(policy.Spec.MyFeature); err != nil {
    status.SetCondition(
        policy,
        gwapiv1.PolicyConditionAccepted,
        metav1.ConditionFalse,
        gwapiv1.PolicyReasonInvalid,
        err.Error(),
    )
    return nil, err
}
```

## Phase 3: Gateway API Golden Tests

### 3.1 Create test input

File: `internal/gatewayapi/testdata/my-feature.in.yaml`

```yaml
gateways:
  - apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    metadata:
      name: gateway-1
      namespace: envoy-gateway
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
      name: httproute-1
      namespace: default
    spec:
      parentRefs:
        - name: gateway-1
          namespace: envoy-gateway
      rules:
        - matches:
            - path:
                value: /
          backendRefs:
            - name: service-1
              port: 8080
backendTrafficPolicies:
  - apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: BackendTrafficPolicy
    metadata:
      name: policy-for-route
      namespace: default
    spec:
      targetRef:
        group: gateway.networking.k8s.io
        kind: HTTPRoute
        name: httproute-1
      myFeature:
        enabled: true
        mode: Strict
        threshold: 100
```

### 3.2 Generate and review output

```bash
go test ./internal/gatewayapi/ -run TestTranslate -update
```

Review `internal/gatewayapi/testdata/my-feature.out.yaml` — verify:
- Gateway status shows `Accepted: True`
- xDS IR contains your `myFeature` field with correct values
- Infra IR is correct

### 3.3 Add invalid configuration test

Create `internal/gatewayapi/testdata/my-feature-invalid.in.yaml` with bad config and verify the output shows appropriate error status conditions.

## Phase 4: xDS Translation

File: `internal/xds/translator/<feature>.go` or add to an existing file

### 4.1 Determine where to wire in

| Feature Type | Wire Into | File |
|-------------|----------|------|
| HTTP filter (auth, rate limit, etc.) | `httpfilters.go` | Register as `httpFilter` interface |
| Cluster setting (LB, health check, etc.) | `cluster.go` | Add to `buildXdsCluster()` |
| Listener setting (timeouts, etc.) | `listener.go` | Add to `buildXdsListener()` |
| Route setting (retries, timeouts, etc.) | `route.go` | Add to `buildXdsRoute()` |

### 4.2 For cluster/route settings (simpler)

Add to the existing builder function:

```go
// In cluster.go or route.go
func buildMyFeature(irMyFeature *ir.MyFeature) *clusterv3.Cluster_MyFeature {
    if irMyFeature == nil {
        return nil
    }

    return &clusterv3.Cluster_MyFeature{
        // Map IR fields to xDS protobuf fields
    }
}
```

### 4.3 For HTTP filters (more involved)

Create a new file and implement the `httpFilter` interface:

```go
// internal/xds/translator/myfeature.go
package translator

func init() {
    registerHTTPFilter(&myFeatureFilter{})
}

type myFeatureFilter struct{}

func (*myFeatureFilter) patchHCM(
    mgr *hcmv3.HttpConnectionManager,
    irListener *ir.HTTPListener,
) error {
    // Add the filter to the HCM filter chain
    return nil
}

func (*myFeatureFilter) patchRoute(
    route *routev3.Route,
    irRoute *ir.HTTPRoute,
    httpListener *ir.HTTPListener,
) error {
    // Add per-route configuration
    return nil
}

func (*myFeatureFilter) patchResources(
    tCtx *types.ResourceVersionTable,
    routes []*ir.HTTPRoute,
) error {
    // Add auxiliary resources (clusters for external services, secrets, etc.)
    return nil
}
```

### 4.4 Set the filter order

In `httpfilters.go`, add an order entry in `newOrderedHTTPFilter()`:

```go
case isFilterType(filter, egv1a1.EnvoyFilterMyFeature):
    order = <appropriate_order>
```

See `eg-contrib-envoy-internals` for the complete filter order reference.

### 4.5 Use anypb.New() for typed configs

```go
import "google.golang.org/protobuf/types/known/anypb"

typedConfig, err := anypb.New(&myfeaturev3.MyFeatureConfig{
    // protobuf fields
})
if err != nil {
    return err
}
```

## Phase 5: xDS Golden Tests

### 5.1 Create IR input

File: `internal/xds/translator/testdata/in/xds-ir/my-feature.yaml`

Use the xDS IR output from Phase 3 as a starting point.

### 5.2 Generate and review output

```bash
go test ./internal/xds/translator/ -run TestTranslateXds -update
```

Review the generated output files:
- `out/xds-ir/my-feature.listeners.yaml` — verify filter is in the chain
- `out/xds-ir/my-feature.routes.yaml` — verify per-route config
- `out/xds-ir/my-feature.clusters.yaml` — verify cluster settings

## Final Checklist

- [ ] IR types added to `internal/ir/xds.go` (slices, not maps)
- [ ] `make generate` run after IR changes
- [ ] Gateway API translation implemented
- [ ] Gateway API golden tests created (valid + invalid)
- [ ] xDS translation implemented
- [ ] xDS golden tests created
- [ ] Filter order set (if HTTP filter)
- [ ] `patchResources` implemented (if filter needs auxiliary clusters)
- [ ] `make lint` passes
- [ ] `make go.test.unit` passes
- [ ] PR title: `feat(translator): add Feature support for CRDName`
