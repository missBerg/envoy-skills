---
name: aigw-contrib-pr-guide
description: PR conventions, commit format, mandatory import aliases, banned packages, review expectations, and common mistakes to avoid when contributing to envoyproxy/ai-gateway
---

# AI Gateway PR Guide

## PR Title Format

```
type(scope): short description in lowercase
```

### Types

| Type | When to Use |
|------|------------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `test` | Test-only changes |
| `api` | API type changes in `api/v1alpha1/` |
| `extproc` | ExtProc changes (translators, router, upstream) |
| `controller` | Controller reconciler changes |
| `translator` | Schema translator changes |
| `mcp` | MCP-related changes |
| `aigw` | CLI changes |
| `chore` | Maintenance (deps, CI, build) |
| `docs` | Documentation changes |
| `refactor` | Code restructuring without behavior change |

### Examples

- `feat(extproc): add Cohere chat completion translator`
- `fix(controller): handle nil BackendSecurityPolicy in reconciler`
- `api(api): add QuotaPolicy CRD types`
- `test(data-plane): add streaming SSE tests for AWS Bedrock`
- `translator(extproc): fix Azure OpenAI model name mapping`

## PR Description

- Must start with `**Description**`
- No HTML comments in PR body
- Use reference-style links only (not inline)
- Reference related issues: `Fixes #123` or `Related to #456`

## The API-First Rule

API changes (`api/v1alpha1/`) **must be in a separate PR** from implementation.

1. **PR 1 — API only**: Add types, run `make apigen && make codegen`, add CEL validation tests
2. **PR 2 — Implementation**: Controller/ExtProc + tests
3. **PR 3 — Docs** (if needed)

## Mandatory Import Aliases

These aliases are enforced by convention and linting. Using the wrong alias fails review.

| Package | Alias | Example |
|---------|-------|---------|
| `api/v1alpha1` | `aigv1a1` | `aigv1a1.AIGatewayRoute` |
| `gateway.networking.k8s.io/v1` | `gwapiv1` | `gwapiv1.Gateway` |
| `gateway.envoyproxy.io/v1alpha1` | `egv1a1` | `egv1a1.Backend` |
| `k8s.io/apimachinery/meta/v1` | `metav1` | `metav1.ObjectMeta` |
| `k8s.io/api/core/v1` | `corev1` | `corev1.Secret` |
| `k8s.io/api/apps/v1` | `appsv1` | `appsv1.Deployment` |
| `k8s.io/apimachinery/errors` | `apierrors` | `apierrors.IsNotFound(err)` |
| Schema packages | `<name>schema` | `anthropicschema`, `cohereschema` |
| `gateway-api-inference-extension` | `gwaiev1` | `gwaiev1.InferencePool` |

## Banned Imports

| Banned Package | Use Instead | Why |
|---------------|-------------|-----|
| `encoding/json` | `internal/json` | Sonic wrapper, ~3x faster |
| `gogo/protobuf` | `google.golang.org/protobuf` | gogo is deprecated |
| `gopkg.in/yaml.v2` | `sigs.k8s.io/yaml` | K8s standard |
| `gopkg.in/yaml.v3` | `sigs.k8s.io/yaml` | K8s standard |

## License Header

Every new Go file must have:

```go
// Copyright Envoy AI Gateway Authors
// SPDX-License-Identifier: Apache-2.0
// The full text of the Apache license is available in the LICENSE file at
// the root of the repo.
```

## Code Conventions

- **Formatter**: `gofumpt` (stricter than `gofmt`)
- **Import ordering**: `gci` — stdlib, external, internal (enforced by linter)
- **Assertions**: `github.com/stretchr/testify/require` for fatal, `assert` for non-fatal
- **Context in tests**: `t.Context()` — never `context.Background()`
- **Goroutine leak detection**: `goleak.VerifyNone(t)` in `TestMain`
- **DCO sign-off**: `git commit -s` on every commit
- **No force-push** during review — makes it hard for reviewers to track changes
- **No squash** during review — squash is done at merge time

## AI Usage Policy

If AI tools were used to generate code, disclose it in the PR description. Reviewers expect human understanding of every line.

## Makefile Targets

| Target | What It Does | When to Run |
|--------|-------------|-------------|
| `make precommit` | Runs all linters and formatters | Before every commit |
| `make test` | Run all unit tests | After any code change |
| `make test-coverage` | Run tests with coverage thresholds | Before pushing |
| `make test-crdcel` | Run CEL validation tests | After API type changes |
| `make test-controller` | Run controller integration tests | After controller changes |
| `make test-data-plane` | Run data plane tests with func-e | After ExtProc/translator changes |
| `make test-e2e` | Run end-to-end tests (kind cluster) | Before final PR push |
| `make apigen` | Regenerate API code (deepcopy, CRDs) | After `api/v1alpha1/` changes |
| `make codegen` | Full code generation | After API or filterapi changes |
| `make apidoc` | Regenerate API documentation | After API type changes |

## Common Review Feedback

### API Design

| Issue | Fix |
|-------|-----|
| Adding a field when nil/omitted means the same | Do not add it — use nil for "not configured" |
| Missing CEL validation for mutually exclusive fields | Add `x-kubernetes-validations` rules |
| Not marking optional fields as optional | Add `// +optional` and use pointer type |
| Using string for a fixed set of values | Use an enum type with `+kubebuilder:validation:Enum` |

### Controller

| Issue | Fix |
|-------|-----|
| Not handling deleted resources | Check if object is being deleted (DeletionTimestamp) |
| Missing RBAC markers | Add `//+kubebuilder:rbac` comments for new resources |
| Not updating filterapi.Config | Changes must flow through to the Secret |
| Reconciler not re-queuing on transient errors | Return `ctrl.Result{RequeueAfter: ...}` |

### ExtProc / Translators

| Issue | Fix |
|-------|-----|
| Using `encoding/json` | Use `internal/json` — linter enforced |
| Allocating per-request in hot path | Pre-allocate at init; reuse buffers |
| Not handling streaming responses | Every translator needs both paths |
| Using `map[string]interface{}` for JSON | Use `gjson`/`sjson` for byte-level ops |
| Missing error context | `fmt.Errorf("translating %s to %s: %w", src, tgt, err)` |
| Changing filter name string | Never change — breaks downstream, causes listener drains |

### Testing

| Issue | Fix |
|-------|-----|
| Using `context.Background()` in tests | Use `t.Context()` |
| Missing `goleak.VerifyNone(t)` | Add to `TestMain` in every package |
| Happy-path-only tests | Add invalid input, missing refs, edge cases |
| Flaky e2e with `time.Sleep` | Use polling or eventual consistency helpers |
| Using `encoding/json` in test files | Still banned — use `internal/json` |

## PR File Checklists

### For API Changes (separate PR)

- [ ] `api/v1alpha1/<crd>_types.go` — new type definition
- [ ] Run `make apigen` — regenerate deepcopy, CRDs
- [ ] Run `make codegen` — full code generation
- [ ] `tests/crdcel/<crd>_test.go` — CEL validation tests
- [ ] `api/v1alpha1/filterapi/filterapi.go` — update if field affects data plane
- [ ] Run `make apidoc` — regenerate API docs

### For Translator Changes

- [ ] `internal/extproc/translators/<src>_<tgt>.go` — translator implementation
- [ ] `internal/extproc/translators/<src>_<tgt>_test.go` — unit tests
- [ ] Register translator in EndpointSpec lookup
- [ ] `tests/data-plane/` — data plane tests with func-e
- [ ] License header on new files
- [ ] Run `make precommit` — linting passes
- [ ] Run `make test` — unit tests pass

### For Controller Changes

- [ ] `internal/controller/<reconciler>.go` — controller logic
- [ ] `tests/controller/<reconciler>_test.go` — integration tests
- [ ] RBAC markers updated if new resources watched
- [ ] filterapi.Config updated if config shape changes
- [ ] Run `make test-controller` — controller tests pass

## Review Process

- Maintainer review required — @mathetake reviews most PRs
- PRs not actively worked on for **7 days** may be closed
- Non-breaking changes preferred — additive, backward-compatible
- Single-purpose PRs only — do not conflate unrelated changes
