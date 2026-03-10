---
name: aigw-contrib-add-api
description: Add or extend CRD types in envoyproxy/ai-gateway — type definition, validation, code generation, and filterapi update
arguments:
  - name: CRDName
    description: "CRD to modify (AIGatewayRoute, AIServiceBackend, BackendSecurityPolicy, GatewayConfig, MCPRoute, QuotaPolicy)"
    required: true
  - name: FieldName
    description: "Name of the new field to add"
    required: true
  - name: FieldDescription
    description: "Purpose and behavior of the new field"
    required: true
---

# Add API Types

Add or modify CRD types in the AI Gateway API. API changes must be in a **separate PR** from implementation — this is enforced by reviewers.

## CRD-to-File Mapping

| CRD | Type File | FilterAPI Impact |
|-----|-----------|-----------------|
| AIGatewayRoute | `api/v1alpha1/ai_gateway_route_types.go` | Yes — routes affect filterapi.Config |
| AIServiceBackend | `api/v1alpha1/ai_service_backend_types.go` | Yes — schema/backend config |
| BackendSecurityPolicy | `api/v1alpha1/backend_security_policy_types.go` | Yes — auth config |
| GatewayConfig | `api/v1alpha1/gateway_config_types.go` | Indirect — ExtProc container config |
| MCPRoute | `api/v1alpha1/mcp_route_types.go` | Yes |
| QuotaPolicy | `api/v1alpha1/quota_policy_types.go` | Yes |

## Step 1: Define the Go Type

Add the field to the appropriate `*_types.go` file:

```go
// ${FieldName} configures ${FieldDescription}.
// +optional
${FieldName} *${FieldType} `json:"${jsonFieldName},omitempty"`
```

### Rules

- **License header** on every new file
- **JSON tags**: lowercase camelCase, always include `omitempty` for optional fields
- **Pointer types**: use pointers for optional fields (`*string`, `*int32`, `*MyType`)
- **Doc comments**: required on all exported types and fields
- **Kubebuilder markers**:
  - `// +optional` for optional fields
  - `// +kubebuilder:validation:Enum=Value1;Value2` for enums
  - `// +kubebuilder:validation:Minimum=0` for numeric bounds
  - `// +kubebuilder:validation:MaxLength=253` for string bounds

### Example

```go
// RetryBudget configures the retry budget for this backend.
// When set, limits the rate of retries to prevent cascading failures.
// +optional
RetryBudget *RetryBudgetConfig `json:"retryBudget,omitempty"`
```

## Step 2: Add CEL Validation Rules (if needed)

For mutually exclusive fields, cross-field validation, or complex constraints, add CEL rules:

```go
// +kubebuilder:validation:XValidation:rule="!(has(self.fieldA) && has(self.fieldB))",message="fieldA and fieldB are mutually exclusive"
type MySpec struct {
    // ...
}
```

## Step 3: Run Code Generation

```bash
# Generate deepcopy methods and CRD manifests
make apigen

# Full code generation (includes filterapi if needed)
make codegen

# Regenerate API documentation
make apidoc
```

This generates:
- `zz_generated.deepcopy.go` — DeepCopy methods
- CRD YAML manifests for Helm
- API reference documentation

## Step 4: Write CEL Validation Tests

Add tests in `tests/crdcel/`:

```go
// tests/crdcel/${crd}_test.go
func TestMyFieldValidation(t *testing.T) {
    tests := []struct {
        name      string
        obj       *aigv1a1.${CRDName}
        wantError bool
        errMsg    string
    }{
        {
            name: "valid: field set correctly",
            obj:  &aigv1a1.${CRDName}{
                // ... valid spec with new field
            },
        },
        {
            name:      "invalid: mutually exclusive fields",
            obj:       &aigv1a1.${CRDName}{
                // ... both exclusive fields set
            },
            wantError: true,
            errMsg:    "mutually exclusive",
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
            }
        })
    }
}
```

Run: `make test-crdcel`

## Step 5: Update filterapi.Config (if field affects data plane)

If the new field changes behavior at the data plane level, update `api/v1alpha1/filterapi/filterapi.go`:

1. Add the corresponding field to the filterapi struct
2. Update the controller reconciler to populate it
3. Update ExtProc to read and act on it

**Note**: filterapi changes in the API PR are fine if they are type-only. The controller/ExtProc logic goes in the implementation PR.

## API Design Rules

### Do

- Use nil to mean "not configured" — do not add a field if omitted behavior is the same
- Align defaults with upstream Envoy defaults
- Use enum types with `+kubebuilder:validation:Enum` for fixed value sets
- Mark optional fields with `// +optional` and pointer types
- Add CEL validation for mutually exclusive fields
- Flatten types when nesting adds no semantic meaning
- Follow existing naming patterns in the same CRD

### Don't

- Add defaults that differ from Envoy without documenting why
- Use raw strings where enums are appropriate
- Create deeply nested types (more than 2 levels)
- Add fields without doc comments
- Skip CEL tests for validation rules
- Mix API changes with implementation in the same PR

## Checklist

- [ ] Field added to correct `*_types.go` with doc comment and JSON tag
- [ ] Kubebuilder markers for validation, optional, enum
- [ ] CEL validation rules for complex constraints
- [ ] `make apigen` — deepcopy and CRDs regenerated
- [ ] `make codegen` — full code generation
- [ ] `make apidoc` — API docs regenerated
- [ ] CEL validation tests in `tests/crdcel/`
- [ ] filterapi.Config updated (if field affects data plane)
- [ ] License header on new files
- [ ] PR title: `api(api): add ${FieldName} to ${CRDName}`
