---
name: eg-contrib-add-api
description: Step-by-step guide to add or extend a CRD API type in envoyproxy/gateway — type definitions, validation, code generation, and API design rules
arguments:
  - name: CRDName
    description: "The CRD being modified (e.g., BackendTrafficPolicy, SecurityPolicy, ClientTrafficPolicy, EnvoyExtensionPolicy, EnvoyProxy, Backend)"
    required: true
  - name: FieldName
    description: "Name of the new field or sub-field being added"
    required: true
  - name: FieldDescription
    description: "What the field does — used to generate doc comments"
    required: true
---

# Adding or Extending an Envoy Gateway CRD API

## Prerequisites

- Read `eg-contrib-pr-guide` — API changes require a **separate PR** from implementation
- Familiarize yourself with `eg-contrib-architecture` — understand where API types fit in the pipeline

## Step 1: Identify the Types File

Map the CRD name to its file in `api/v1alpha1/`:

| CRD | Types File |
|-----|-----------|
| BackendTrafficPolicy | `backendtrafficpolicy_types.go` |
| ClientTrafficPolicy | `clienttrafficpolicy_types.go` |
| SecurityPolicy | `securitypolicy_types.go` |
| EnvoyExtensionPolicy | `envoyextensionpolicy_types.go` |
| EnvoyProxy | `envoyproxy_types.go` |
| EnvoyPatchPolicy | `envoypatchpolicy_types.go` |
| Backend | `backend_types.go` |
| HTTPRouteFilter | `httproutefilter_types.go` |

Pattern: lowercase CRD name + `_types.go`

## Step 2: Add the Go Type Definition

### For a new sub-type (complex field)

Create a new struct in the appropriate types file or in `shared_types.go` if used across CRDs:

```go
// MyFeatureSettings defines the settings for MyFeature.
type MyFeatureSettings struct {
    // Enabled controls whether MyFeature is active.
    //
    // +optional
    Enabled *bool `json:"enabled,omitempty"`

    // Mode specifies the operating mode.
    //
    // +kubebuilder:validation:Enum=Strict;Permissive
    // +optional
    Mode *MyFeatureMode `json:"mode,omitempty"`

    // Threshold sets the numeric limit.
    //
    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=1000
    // +optional
    Threshold *int32 `json:"threshold,omitempty"`
}

// MyFeatureMode defines the mode of MyFeature.
// +kubebuilder:validation:Enum=Strict;Permissive
type MyFeatureMode string

const (
    MyFeatureModeStrict     MyFeatureMode = "Strict"
    MyFeatureModePermissive MyFeatureMode = "Permissive"
)
```

### For a new field on an existing spec

Add the field to the parent spec struct:

```go
type BackendTrafficPolicySpec struct {
    // ... existing fields ...

    // MyFeature configures the MyFeature behavior for backend connections.
    //
    // +optional
    MyFeature *MyFeatureSettings `json:"myFeature,omitempty"`
}
```

### Naming and Tagging Rules

| Rule | Example |
|------|---------|
| Go field names: PascalCase | `MyFeature`, `RetryBudget` |
| JSON tags: camelCase | `json:"myFeature,omitempty"` |
| Optional fields: pointer type + `// +optional` | `*MyFeatureSettings` |
| Required fields: value type (no pointer) | `MyFeatureMode` (when required) |
| Enums: typed string with validation marker | `+kubebuilder:validation:Enum=A;B;C` |
| Numeric bounds: min/max markers | `+kubebuilder:validation:Minimum=1` |
| Default values: kubebuilder default marker | `+kubebuilder:default=100` |

## Step 3: Add Shared Types (If Cross-CRD)

If the type is used by multiple CRDs, place it in `api/v1alpha1/shared_types.go`:

```go
// shared_types.go

// Duration is a string representing a duration (e.g., "1s", "5m").
// +kubebuilder:validation:Pattern=`^([0-9]{1,5}(h|m|s|ms)){1,4}$`
type Duration string
```

Existing shared types you should reuse (do not reinvent):
- `Duration` — time durations
- `BackendRef` — backend references
- `KubernetesContainerSpec` — container resource settings
- `KubernetesPodSpec` — pod-level settings

## Step 4: Run Code Generation

```bash
make generate
```

This runs:
1. `controller-gen` — generates `zz_generated.deepcopy.go` (DeepCopy methods for all types)
2. CRD YAML generation — updates `charts/gateway-helm/crds/generated/`
3. Helm chart updates — ensures CRD manifests are in sync

**Always verify**: `git diff` after `make generate` to confirm the generated output looks correct.

## Step 5: Add Validation Rules

### CEL Validation (for field-level and cross-field rules)

Add validation rules as kubebuilder markers on the type:

```go
// +kubebuilder:validation:XValidation:rule="!(has(self.fieldA) && has(self.fieldB))",message="fieldA and fieldB are mutually exclusive"
type MyPolicySpec struct {
    // +optional
    FieldA *string `json:"fieldA,omitempty"`
    // +optional
    FieldB *string `json:"fieldB,omitempty"`
}
```

### Go Validation (for complex rules)

For rules too complex for CEL, add Go validation in `api/v1alpha1/validation/`:

```go
// validation/validate.go
func ValidateMyFeature(feature *MyFeatureSettings) error {
    if feature == nil {
        return nil
    }
    // complex validation logic
    return nil
}
```

### CEL Validation Tests

Add tests in `test/cel-validation/`:

```go
// test/cel-validation/backendtrafficpolicy_test.go
func TestMyFeatureValidation(t *testing.T) {
    tests := []struct {
        name    string
        policy  *egv1a1.BackendTrafficPolicy
        wantErr bool
    }{
        {
            name: "valid configuration",
            policy: &egv1a1.BackendTrafficPolicy{
                Spec: egv1a1.BackendTrafficPolicySpec{
                    MyFeature: &egv1a1.MyFeatureSettings{
                        Enabled: ptr.To(true),
                    },
                },
            },
            wantErr: false,
        },
        {
            name: "mutually exclusive fields",
            policy: &egv1a1.BackendTrafficPolicy{
                Spec: egv1a1.BackendTrafficPolicySpec{
                    MyFeature: &egv1a1.MyFeatureSettings{
                        FieldA: ptr.To("a"),
                        FieldB: ptr.To("b"),
                    },
                },
            },
            wantErr: true,
        },
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Create the resource and check if it validates
        })
    }
}
```

## Step 6: Update Helm Chart (If Needed)

If the new field needs to be configurable via Helm values:

1. Update `charts/gateway-helm/values.yaml` with the new field
2. Update the relevant template in `charts/gateway-helm/templates/`
3. CRD manifests in `charts/gateway-helm/crds/generated/` are auto-updated by `make generate`

## API Design Rules

### Do

- **Use nil to mean "not configured"** — if a field's absence has meaning, do not add a boolean to disable it
- **Align defaults with upstream Envoy** — unless there is a documented reason not to
- **Use enum types** for fixed sets of values — never use raw strings for known options
- **Mark optional fields correctly** — `// +optional` + pointer type + `omitempty` tag
- **Add doc comments** — every exported type and field needs a Go doc comment
- **Reuse shared types** — check `shared_types.go` before creating new types
- **Follow Gateway API conventions** — `targetRef` for policy attachment, standard status conditions

### Do Not

- **Do not add a field when nil already represents the behavior** — e.g., do not add `Enabled *bool` if the feature is disabled when the parent struct is nil
- **Do not create deeply nested types** — flatten when the nesting adds no semantic value
- **Do not use `interface{}`** — use typed alternatives
- **Do not hardcode version-specific values** — use constants or config-driven values
- **Do not skip validation** — every user-facing field should have bounds checked
- **Do not mix API changes with implementation** — they must be in separate PRs

## Checklist for API PRs

- [ ] Types defined with proper JSON/YAML tags
- [ ] Doc comments on all exported types and fields
- [ ] Kubebuilder validation markers added
- [ ] Optional fields use pointer type + `// +optional`
- [ ] `make generate` run successfully
- [ ] CEL validation tests added in `test/cel-validation/`
- [ ] CRD YAML in `charts/gateway-helm/crds/generated/` updated
- [ ] No implementation code — API-only PR
- [ ] PR title: `api(api): add FieldName to CRDName`
