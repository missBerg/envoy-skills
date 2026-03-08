---
name: eg-contrib-pr-guide
description: PR conventions, commit format, review expectations, and common mistakes to avoid when contributing to envoyproxy/gateway
---

# Envoy Gateway PR Guide

## PR Title Format

```
type(subsystem): short description in lowercase
```

### Types

| Type | When to Use |
|------|------------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `chore` | Maintenance (deps, CI, build) |
| `docs` | Documentation changes |
| `api` | API type changes in `api/v1alpha1/` |
| `refactor` | Code restructuring without behavior change |
| `test` | Test-only changes |
| `style` | Formatting, linting fixes |

### Subsystems

| Subsystem | Directory |
|-----------|-----------|
| `translator` | `internal/gatewayapi/` |
| `xds` | `internal/xds/translator/` |
| `provider` | `internal/provider/` |
| `infra` | `internal/infrastructure/` |
| `ir` | `internal/ir/` |
| `api` | `api/v1alpha1/` |
| `extension` | `internal/extension/` |
| `helm` | `charts/gateway-helm/` |
| `e2e` | `test/e2e/` |
| `ci` | `.github/` |
| `egctl` | `internal/cmd/egctl/` |
| `bootstrap` | `internal/xds/bootstrap/` |

### Examples

- `feat(translator): add retry budget support for BackendTrafficPolicy`
- `fix(xds): correct filter chain order for ext_authz with CORS`
- `api(api): add RetryBudget field to BackendTrafficPolicySpec`
- `test(e2e): add circuit breaker e2e test`
- `chore(ci): update Go version to 1.23`

## The API-First Rule

API changes (`api/v1alpha1/`) **must be in a separate PR** from the implementation.

**Workflow for features requiring new API fields:**

1. **PR 1 — API only**: Add types in `api/v1alpha1/`, run `make generate`, add CEL validation tests
2. **PR 2 — Implementation**: Translator + IR + xDS translation + golden tests + e2e tests
3. **PR 3 — Docs** (if needed): User-facing documentation and examples

This separation makes review easier and avoids monolithic PRs.

## Code Quality Expectations

### Must-Have for Every PR

- **100% test coverage** for new code (explain in PR description if truly impossible)
- **Copyright header** on every new file:
  ```go
  // Copyright Envoy Gateway Authors
  // SPDX-License-Identifier: Apache-2.0
  // The full text of the Apache license is available in the LICENSE file at
  // the root of the repo.
  ```
- **DCO sign-off** on every commit: `git commit -s`
- **Doc comments** on all exported types, functions, and interfaces
- **Inclusive language**: use allowlist/denylist (not whitelist/blacklist), primary/replica (not master/slave)

### Code Conventions

- Use `k8s.io/utils/ptr` for pointer helpers — never write custom `ptrTo()` functions
- Use `sigs.k8s.io/yaml` for YAML marshaling — not `encoding/json` or `gopkg.in/yaml.v3`
- Use `github.com/stretchr/testify/require` for fatal test assertions, `assert` for non-fatal
- Use `errors.Join()` for accumulating multiple errors — not custom error slices
- Use structured logging with `internal/logging` — not `fmt.Printf` or `log`
- Variables: use short, descriptive names; avoid Hungarian notation

### What Reviewers Look For

- **Comments explaining non-obvious choices** — why, not what
- **Error messages with context** — include namespace, name, resource kind
- **Consistent naming** — follow existing patterns in the same file
- **No unnecessary exported symbols** — keep the public API surface small
- **No unused imports or variables** — `make lint` catches this

## Common Review Feedback

These are real patterns from PR reviews. Avoiding these saves review cycles.

### API Design

| Issue | Fix |
|-------|-----|
| Adding a field when nil/omitted represents the same behavior | Do not add it — use nil to mean "not configured" |
| Defaults that differ from upstream Envoy | Align with Envoy defaults unless there is a strong reason not to (document why) |
| Using string for a fixed set of values | Use an enum type with `+kubebuilder:validation:Enum` |
| Missing validation for mutually exclusive fields | Add CEL `x-kubernetes-validations` rules |
| Not marking optional fields as optional | Add `// +optional` comment and use pointer type |
| Overly nested types | Flatten when the nesting does not add semantic meaning |

### Translation

| Issue | Fix |
|-------|-----|
| Using `map` types in IR structs | Use `[]MapEntry` slices — maps break `DeepEqual` determinism |
| Changing a filter name | Never change filter names — it breaks downstream consumers and causes listener drains |
| Not handling nil IR fields | Always nil-check optional IR fields before xDS translation |
| Missing `patchResources` implementation | If your filter needs auxiliary clusters (JWKS, token endpoints), add them via `patchResources` |
| Hardcoded values that should come from config | Make them configurable via CRD fields or use upstream Envoy defaults |

### Testing

| Issue | Fix |
|-------|-----|
| Happy-path-only test coverage | Add tests for invalid input, missing references, edge cases |
| Missing golden file updates | Run `go test -run TestTranslate -update` after changing translation logic |
| Flaky e2e tests with `time.Sleep` | Use `wait.PollImmediate` or `MakeRequestAndExpectEventuallyConsistentResponse` |
| Not testing policy at multiple attachment levels | Test policy on Gateway, Route, and Route rule when applicable |

### Infrastructure

| Issue | Fix |
|-------|-----|
| Helm values not updated | Update `charts/gateway-helm/values.yaml` if adding new config |
| Missing release notes | Add entry to `release-notes/current.yaml` for user-facing changes |
| Not running `make generate` | Always run after API or IR changes — it regenerates deepcopy, CRDs, Helm |

## Makefile Targets

| Target | What It Does | When to Run |
|--------|-------------|-------------|
| `make generate` | Regenerate deepcopy, CRDs, Helm CRDs, protobuf | After changing `api/` or `internal/ir/` types |
| `make lint` | Run golangci-lint and other linters | Before pushing — CI will fail otherwise |
| `make go.test.unit` | Run unit tests with race detection | After any code change |
| `make go.testdata.complete` | Regenerate all golden test files | After changing translator logic |
| `make go.test.coverage` | Run tests with coverage report | Verify 100% coverage on new code |
| `make go.test.cel` | Run CEL validation tests | After changing CRD validation rules |

## Complete PR File Checklist

A typical feature PR touches these files. Use this checklist to ensure nothing is missed:

### For API changes (separate PR)

- [ ] `api/v1alpha1/<crd>_types.go` — new type definition
- [ ] `api/v1alpha1/shared_types.go` — shared types (if cross-CRD)
- [ ] `api/v1alpha1/validation/*.go` — Go validation (if complex rules)
- [ ] `test/cel-validation/<crd>_test.go` — CEL validation tests
- [ ] Run `make generate` — updates deepcopy, CRDs, Helm CRDs

### For implementation (separate PR)

- [ ] `internal/ir/xds.go` — IR type additions
- [ ] `internal/gatewayapi/<policy>.go` — Gateway API → IR translation
- [ ] `internal/gatewayapi/testdata/<feature>.in.yaml` — translator test input
- [ ] `internal/gatewayapi/testdata/<feature>.out.yaml` — translator test output
- [ ] `internal/xds/translator/<feature>.go` — IR → xDS translation
- [ ] `internal/xds/translator/testdata/in/xds-ir/<feature>.yaml` — xDS test input
- [ ] `internal/xds/translator/testdata/out/xds-ir/<feature>.*.yaml` — xDS test output
- [ ] `test/e2e/tests/<feature>.go` — e2e test
- [ ] `test/e2e/testdata/<feature>.yaml` — e2e test manifests
- [ ] `release-notes/current.yaml` — release notes entry
- [ ] Run `make generate` — if IR types changed
- [ ] Run `make lint` — verify linting passes
- [ ] Run `make go.test.unit` — verify unit tests pass

### For documentation changes

- [ ] `site/content/en/` — user-facing documentation
- [ ] `site/content/en/contributions/design/` — design document (for significant features)

## PR Size Guidelines

- **Small PRs** (< 200 lines): Bug fixes, test improvements, doc updates — typically reviewed same day
- **Medium PRs** (200-500 lines): New feature implementation — 1-2 day review
- **Large PRs** (500+ lines): Break into smaller PRs — API first, then implementation, then docs
- **Major features** (> 100 LOC of new logic): Discuss in a GitHub issue first; may need a design doc

## Review Process

- A maintainer from a **different company affiliation** must review and approve
- PRs not actively worked on for **7 days** will be closed
- If your PR changes behavior, add a **deprecation notice** before removing old behavior
- **Non-breaking is preferred** — additive changes that do not affect existing users
