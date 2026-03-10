---
name: k8s-crd-lifecycle
description: CRD type definitions, kubebuilder markers, CEL validation, code generation, and versioning for Kubernetes control planes
---

# CRD Lifecycle Management

Design, validate, and evolve Custom Resource Definitions for Kubernetes control planes. Covers type definitions, validation with CEL (not webhooks), code generation, and version management.

## Type Definition Patterns

### Spec/Status Separation

Every CRD follows the Spec/Status convention:

```go
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Status",type=string,JSONPath=`.status.conditions[-1:].type`

// MyResource defines a managed resource.
type MyResource struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    // Spec defines the desired state of the resource.
    Spec MyResourceSpec `json:"spec"`

    // Status defines the observed state of the resource.
    // +optional
    Status MyResourceStatus `json:"status,omitempty"`
}

// MyResourceSpec defines the desired behavior.
type MyResourceSpec struct {
    // BackendRef identifies the target backend.
    BackendRef BackendRef `json:"backendRef"`

    // Timeout configures the request timeout.
    // +optional
    Timeout *metav1.Duration `json:"timeout,omitempty"`
}

// MyResourceStatus defines the observed state.
type MyResourceStatus struct {
    // Conditions describe the current conditions of the resource.
    // +optional
    // +listType=map
    // +listMapKey=type
    Conditions []metav1.Condition `json:"conditions,omitempty"`
}
```

### Field Convention Rules

| Rule | Example | Notes |
|------|---------|-------|
| Optional fields use pointers | `*string`, `*int32`, `*MyType` | `nil` means "not configured" |
| JSON tags are lowercase camelCase | `json:"backendRef,omitempty"` | Always include `omitempty` for optional |
| Doc comment on every exported type/field | `// Timeout configures...` | Required by linters and API docs |
| `+optional` marker for optional fields | `// +optional` | Goes before the field |
| Slice fields declare list type | `// +listType=map` | Enables strategic merge patch |

### Enum Types

```go
// ProtocolType defines the protocol used by a backend.
// +kubebuilder:validation:Enum=HTTP;HTTPS;gRPC;gRPCS
type ProtocolType string

const (
    // ProtocolHTTP indicates HTTP protocol.
    ProtocolHTTP ProtocolType = "HTTP"
    // ProtocolHTTPS indicates HTTPS protocol.
    ProtocolHTTPS ProtocolType = "HTTPS"
    // ProtocolGRPC indicates gRPC protocol.
    ProtocolGRPC ProtocolType = "gRPC"
    // ProtocolGRPCS indicates gRPC with TLS.
    ProtocolGRPCS ProtocolType = "gRPCS"
)
```

### Discriminated Unions

For fields where only one of several options should be set:

```go
// AuthConfig defines authentication configuration.
// Exactly one of APIKey, AWSCredentials, or OIDCToken must be set.
//
// +kubebuilder:validation:XValidation:rule="(has(self.apiKey) ? 1 : 0) + (has(self.awsCredentials) ? 1 : 0) + (has(self.oidcToken) ? 1 : 0) == 1",message="exactly one auth type must be specified"
type AuthConfig struct {
    // APIKey configures static API key authentication.
    // +optional
    APIKey *APIKeyAuth `json:"apiKey,omitempty"`

    // AWSCredentials configures AWS SigV4 authentication.
    // +optional
    AWSCredentials *AWSAuth `json:"awsCredentials,omitempty"`

    // OIDCToken configures OpenID Connect token authentication.
    // +optional
    OIDCToken *OIDCAuth `json:"oidcToken,omitempty"`
}
```

## Kubebuilder Markers

### Object Markers

```go
// +kubebuilder:object:root=true           // Top-level CRD type
// +kubebuilder:subresource:status         // Enable /status subresource
// +kubebuilder:resource:scope=Namespaced  // Or Cluster
// +kubebuilder:resource:shortName=mr      // kubectl get mr
```

### Validation Markers

```go
// +kubebuilder:validation:Required                  // Field is required
// +kubebuilder:validation:Optional                  // Field is optional
// +kubebuilder:validation:Enum=Value1;Value2;Value3 // Enum constraint
// +kubebuilder:validation:Minimum=0                 // Numeric min
// +kubebuilder:validation:Maximum=65535             // Numeric max
// +kubebuilder:validation:MinLength=1               // String min length
// +kubebuilder:validation:MaxLength=253             // String max length (DNS names)
// +kubebuilder:validation:Pattern=`^[a-z0-9-]+$`   // Regex pattern
// +kubebuilder:validation:MinItems=1                // Slice min items
// +kubebuilder:validation:MaxItems=16               // Slice max items
// +kubebuilder:validation:Format=uri                // Standard format
```

### Print Columns

```go
// +kubebuilder:printcolumn:name="Status",type=string,JSONPath=`.status.conditions[-1:].type`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
// +kubebuilder:printcolumn:name="Backend",type=string,JSONPath=`.spec.backendRef.name`
```

## CEL Validation (Over Webhooks)

### Why CEL Over Webhooks

The Gateway API project successfully replaced **all** admission webhooks with CEL validation rules. Benefits:

- **No infrastructure**: No webhook server to deploy, certificate to manage, or availability concern
- **Declarative**: Rules live in the CRD schema, not external code
- **Version-safe**: Rules are part of the CRD manifest, not a running binary
- **Performance**: Evaluated in the API server, no network hop

Both Envoy Gateway and AI Gateway use CEL exclusively (no webhooks).

### CEL Rule Patterns

#### Mutual Exclusivity

```go
// +kubebuilder:validation:XValidation:rule="!(has(self.fieldA) && has(self.fieldB))",message="fieldA and fieldB are mutually exclusive"
```

#### Exactly One Of N Fields

```go
// +kubebuilder:validation:XValidation:rule="(has(self.a) ? 1 : 0) + (has(self.b) ? 1 : 0) + (has(self.c) ? 1 : 0) == 1",message="exactly one of a, b, or c must be set"
```

#### Conditional Required Fields

```go
// +kubebuilder:validation:XValidation:rule="self.type == 'APIKey' ? has(self.apiKey) : true",message="apiKey is required when type is APIKey"
```

#### Cross-Field Consistency

```go
// +kubebuilder:validation:XValidation:rule="has(self.minReplicas) && has(self.maxReplicas) ? self.minReplicas <= self.maxReplicas : true",message="minReplicas must be <= maxReplicas"
```

#### Immutable Fields

```go
// +kubebuilder:validation:XValidation:rule="self.name == oldSelf.name",message="name is immutable"
```

**Note**: Rules using `oldSelf` (transition rules) must be placed on the **type definition** that contains the field, not on the field itself. The `oldSelf` variable is only available in type-level `XValidation` markers, not field-level markers. Example:

```go
// Correct: XValidation on the type that contains the immutable field
// +kubebuilder:validation:XValidation:rule="self.name == oldSelf.name",message="name is immutable"
type MyResourceSpec struct {
    Name string `json:"name"`
}
```

### Real-World CEL Examples

From AI Gateway — BackendSecurityPolicy auth type mutual exclusivity:

```go
// +kubebuilder:validation:XValidation:rule="(self.type == 'APIKey' && has(self.apiKey)) || self.type != 'APIKey'",message="apiKey must be set when type is APIKey"
// +kubebuilder:validation:XValidation:rule="(self.type == 'AWSCredentials' && has(self.awsCredentials)) || self.type != 'AWSCredentials'",message="awsCredentials must be set when type is AWSCredentials"
```

### Testing CEL Rules

CEL rules are tested with envtest (real API server):

```go
func TestAuthConfigCELValidation(t *testing.T) {
    tests := []struct {
        name      string
        obj       *myv1.MyResource
        wantError bool
        errMsg    string
    }{
        {
            name: "valid: exactly one auth type",
            obj: &myv1.MyResource{
                // ObjectMeta is required for envtest — the API server needs name and namespace
                ObjectMeta: metav1.ObjectMeta{
                    Name:      "test-valid-auth",
                    Namespace: "default",
                },
                Spec: myv1.MyResourceSpec{
                    Auth: &myv1.AuthConfig{
                        APIKey: &myv1.APIKeyAuth{SecretRef: "my-secret"},
                    },
                },
            },
        },
        {
            name: "invalid: two auth types set",
            obj: &myv1.MyResource{
                ObjectMeta: metav1.ObjectMeta{
                    Name:      "test-invalid-two-auth",
                    Namespace: "default",
                },
                Spec: myv1.MyResourceSpec{
                    Auth: &myv1.AuthConfig{
                        APIKey:         &myv1.APIKeyAuth{SecretRef: "my-secret"},
                        AWSCredentials: &myv1.AWSAuth{Region: "us-east-1"},
                    },
                },
            },
            wantError: true,
            errMsg:    "exactly one auth type",
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

## Code Generation

### Pipeline

```bash
# 1. Generate DeepCopy methods and CRD manifests
controller-gen object crd paths="./api/..." output:crd:dir=config/crd/bases

# 2. Project-specific targets (examples)
make apigen    # AI Gateway: controller-gen + CRD manifests
make generate  # Envoy Gateway: controller-gen + client-gen + lister-gen + informer-gen
make codegen   # Full code generation including filterapi
make apidoc    # Regenerate API reference documentation
```

### Generated Files

| File | Generator | Purpose |
|------|-----------|---------|
| `zz_generated.deepcopy.go` | `controller-gen object` | DeepCopy/DeepCopyInto/DeepCopyObject methods |
| `config/crd/bases/*.yaml` | `controller-gen crd` | CRD YAML manifests with OpenAPI schema |

The two files above are **required for all controller-runtime projects**.

The following generators are used by Envoy Gateway but are **not needed for most new controller-runtime projects** — controller-runtime's `client.Client` handles typed operations directly:

| File | Generator | Purpose |
|------|-----------|---------|
| `*_client.go` | `client-gen` | Typed Kubernetes clients (used by Envoy Gateway) |
| `*_lister.go` | `lister-gen` | Resource listers |
| `*_informer.go` | `informer-gen` | Shared informers |

**Why EG uses these**: Envoy Gateway adopted these generators early in its development for typed client access patterns that predated controller-runtime's improvements. They remain in use because EG's translation pipeline uses typed listers for efficient resource lookups during IR construction. AI Gateway, started later, uses only controller-runtime's `client.Client` and does not need these generators.

### When to Regenerate

Always regenerate after:
- Adding or modifying a type in `*_types.go`
- Changing kubebuilder markers
- Adding or removing fields
- Modifying validation rules

Verify: `git diff` should show changes in generated files matching your type changes.

## Versioning Strategy

### Hub-Spoke Pattern

For multi-version CRDs, designate one version as the "hub" (storage version) and implement conversion between hub and spoke versions:

```go
// Hub version — the storage version
// +kubebuilder:storageversion
type MyResourceV1 struct { ... }

// Spoke version — converts to/from hub
type MyResourceV1Beta1 struct { ... }

// ConvertTo converts to the hub version
func (src *MyResourceV1Beta1) ConvertTo(dstRaw conversion.Hub) error {
    dst := dstRaw.(*MyResourceV1)
    // ... conversion logic ...
    return nil
}

// ConvertFrom converts from the hub version
func (dst *MyResourceV1Beta1) ConvertFrom(srcRaw conversion.Hub) error {
    src := srcRaw.(*MyResourceV1)
    // ... conversion logic ...
    return nil
}
```

### Version Graduation

1. **v1alpha1** → experimental, breaking changes expected
2. **v1beta1** → feature-complete, API may change with deprecation notice
3. **v1** → stable, backward-compatible changes only

When graduating:
- Add the new version as hub
- Keep the old version as spoke with conversion
- Mark old version as deprecated with `+kubebuilder:deprecatedversion`
- Set `+kubebuilder:storageversion` on the new version

## API Design Rules

### Do

- Use `nil` to mean "not configured" — don't add a field if omitted behavior is the same as default
- Align defaults with upstream project defaults (Envoy, Gateway API)
- Use enum types with `+kubebuilder:validation:Enum` for fixed value sets
- Flatten types when nesting adds no semantic meaning
- Follow existing naming patterns in the same CRD
- Add CEL validation for mutually exclusive or cross-field constraints
- Separate API PRs from implementation PRs
- Use `metav1.Duration` for duration fields (not raw string or int)
- Use `resource.Quantity` for resource amounts

### Don't

- Add defaults that differ from upstream without documenting why
- Use raw strings where enums are appropriate
- Create deeply nested types (more than 2 levels)
- Add fields without doc comments
- Skip CEL tests for validation rules
- Mix API changes with implementation in the same PR
- Use `map[string]string` for structured data (use typed structs)
- Add boolean fields (prefer enums for future extensibility)

## Checklist

- [ ] Field added to correct `*_types.go` with doc comment and JSON tag
- [ ] Kubebuilder markers for validation, optional, enum
- [ ] Pointer type for optional fields
- [ ] CEL validation rules for complex constraints
- [ ] Code generation run (`controller-gen object crd`)
- [ ] Generated files committed (deepcopy, CRD manifests)
- [ ] CEL validation tests with envtest
- [ ] API docs regenerated
- [ ] License header on new files
- [ ] PR is API-only (no implementation logic mixed in)
