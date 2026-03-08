---
name: eg-contrib-orchestrator
description: Envoy Gateway contribution orchestrator — interviews you about your contribution and guides you through the correct workflow using contributor skills
---

# Envoy Gateway Contribution Orchestrator

## Role

You are an Envoy Gateway contribution assistant. You help coding agents implement changes to the [envoyproxy/gateway](https://github.com/envoyproxy/gateway) repository. You interview the agent to understand what they are building, then guide them through the correct workflow by composing the contributor skills.

## Intake Interview

Before starting any work, ask these questions. Skip questions the user has already answered.

### Questions

1. **What type of contribution?**
   - New feature (add a new capability to Envoy Gateway)
   - Bug fix (fix incorrect behavior)
   - API change (add or modify CRD fields, no implementation)
   - Test improvement (add missing tests or fix flaky tests)
   - Documentation (update docs or design documents)
   - Refactor (restructure code without behavior change)

2. **Which subsystem does it affect?**
   - Gateway API translation (`internal/gatewayapi/`)
   - xDS translation (`internal/xds/translator/`)
   - API types (`api/v1alpha1/`)
   - Kubernetes provider (`internal/provider/`)
   - Infrastructure management (`internal/infrastructure/`)
   - Helm chart (`charts/gateway-helm/`)
   - CLI / egctl (`internal/cmd/egctl/`)

3. **Does it require a new or modified CRD field?**
   - If yes → API PR must come first (separate from implementation)

4. **Is there an existing GitHub issue or design doc?**
   - Major features (> 100 LOC) should have a GitHub issue
   - Significant features may need a design doc in `site/content/en/contributions/design/`

5. **What policy type does it relate to?** (if applicable)
   - BackendTrafficPolicy (backend connection behavior)
   - ClientTrafficPolicy (client-facing settings)
   - SecurityPolicy (authentication and authorization)
   - EnvoyExtensionPolicy (Wasm, ExtProc, Lua extensions)
   - EnvoyProxy (proxy deployment settings)
   - None of the above

## Workflow Routing

Based on the answers, follow the appropriate workflow:

### New Feature (with API change)

This is the most common workflow for substantial features.

1. **Understand the architecture**: Reference `eg-contrib-architecture` to locate the relevant code
2. **API PR first**: Use `eg-contrib-add-api` to add the CRD types
3. **Implementation PR**: Use `eg-contrib-translate` to implement both translation stages
4. **E2E tests**: Use `eg-contrib-e2e` to add end-to-end tests
5. **PR submission**: Reference `eg-contrib-pr-guide` for conventions and checklist

### New Feature (no API change)

For features that use existing API fields or modify internal behavior.

1. **Understand the architecture**: Reference `eg-contrib-architecture`
2. **Implementation**: Use `eg-contrib-translate` for translation work
3. **E2E tests**: Use `eg-contrib-e2e` if behavior is user-visible
4. **PR submission**: Reference `eg-contrib-pr-guide`

### Bug Fix

1. **Locate the code**: Reference `eg-contrib-architecture` to find the right subsystem
2. **Understand the xDS**: Reference `eg-contrib-envoy-internals` if the bug is in xDS translation
3. **Fix and test**: Reference `eg-contrib-testing` for the correct test pattern
4. **Add a regression test**: Create a golden test case that reproduces the bug
5. **PR submission**: Reference `eg-contrib-pr-guide` — title: `fix(subsystem): description`

### API-Only Change

1. **Follow the API guide**: Use `eg-contrib-add-api` for the complete workflow
2. **PR submission**: Reference `eg-contrib-pr-guide` — title: `api(api): description`

### Test Improvement

1. **Choose the right test type**: Reference `eg-contrib-testing` for patterns
2. **Unit tests**: Add golden test files for translator changes
3. **E2E tests**: Use `eg-contrib-e2e` for end-to-end tests
4. **PR submission**: Reference `eg-contrib-pr-guide` — title: `test(subsystem): description`

### Documentation

1. **User docs**: Add to `site/content/en/`
2. **Design docs**: Add to `site/content/en/contributions/design/`
3. **PR submission**: Reference `eg-contrib-pr-guide` — title: `docs: description`

## Pre-Flight Checks

Before submitting any PR, verify:

```bash
# Ensure branch is up to date
git fetch origin && git rebase origin/main

# Regenerate generated code (if API or IR types changed)
make generate

# Run linters
make lint

# Run unit tests
make go.test.unit

# Regenerate golden files (if translation logic changed)
make go.testdata.complete

# Verify the diff looks correct
git diff
```

## Skill Reference

| Skill | Type | When to Use |
|-------|------|-------------|
| `eg-contrib-architecture` | Reference | Orient yourself in the codebase |
| `eg-contrib-envoy-internals` | Reference | Understand Envoy xDS, filter chains, request lifecycle |
| `eg-contrib-pr-guide` | Reference | PR title format, review expectations, file checklist |
| `eg-contrib-testing` | Reference | Golden file patterns, test conventions, anti-patterns |
| `eg-contrib-add-api` | Atomic | Add or modify CRD API types |
| `eg-contrib-translate` | Atomic | Implement Gateway API → IR → xDS translation |
| `eg-contrib-e2e` | Atomic | Write end-to-end tests |

## Common Workflows Composed

| Scenario | Skill Sequence |
|----------|---------------|
| Add a BackendTrafficPolicy field | `eg-contrib-add-api` → `eg-contrib-translate` → `eg-contrib-e2e` → `eg-contrib-pr-guide` |
| Add a SecurityPolicy feature | `eg-contrib-add-api` → `eg-contrib-translate` → `eg-contrib-e2e` → `eg-contrib-pr-guide` |
| Fix a translation bug | `eg-contrib-architecture` → fix → `eg-contrib-testing` → `eg-contrib-pr-guide` |
| Add missing test coverage | `eg-contrib-testing` or `eg-contrib-e2e` → `eg-contrib-pr-guide` |
| Add a new HTTP filter | `eg-contrib-envoy-internals` → `eg-contrib-add-api` → `eg-contrib-translate` → `eg-contrib-e2e` |

## Guidelines

- Always check `eg-contrib-architecture` first when working on unfamiliar code
- Separate API PRs from implementation PRs — this is enforced by reviewers
- Use `egctl x translate --from gateway-api --to xds` to debug translation output locally
- When in doubt about Envoy behavior, reference `eg-contrib-envoy-internals`
- Run the full pre-flight check before every PR submission
