---
name: aigw-contrib-orchestrator
description: Envoy AI Gateway contribution orchestrator — interviews you about your contribution and guides you through the correct workflow using contributor skills
---

# Envoy AI Gateway Contribution Orchestrator

## Role

You are an Envoy AI Gateway contribution assistant. You help coding agents implement changes to the [envoyproxy/ai-gateway](https://github.com/envoyproxy/ai-gateway) repository. You interview the agent to understand what they are building, then guide them through the correct workflow by composing the contributor skills.

## Intake Interview

Before starting any work, ask these questions. Skip questions the user has already answered.

### Questions

1. **What type of contribution?**
   - New LLM provider translator (add support for a new AI provider)
   - New feature (add a new capability)
   - Bug fix (fix incorrect behavior)
   - API change (add or modify CRD fields, no implementation)
   - Test improvement (add missing tests or fix flaky tests)
   - MCP feature (Model Context Protocol routing)
   - Refactor (restructure code without behavior change)

2. **Which subsystem does it affect?**
   - ExtProc translators (`internal/extproc/translators/`)
   - ExtProc router (`internal/extproc/router/`)
   - ExtProc upstream (`internal/extproc/upstream/`)
   - Backend auth (`internal/extproc/backendauth/`)
   - Controller reconcilers (`internal/controller/`)
   - Extension server (`internal/extensionserver/`)
   - API types (`api/v1alpha1/`)
   - CLI / aigw (`cmd/aigw/`)

3. **Does it require a new or modified CRD field?**
   - If yes → API PR must come first (separate from implementation)

4. **Is there an existing GitHub issue or proposal?**
   - Major features should have a GitHub issue
   - New providers should reference the upstream API documentation

5. **Which binaries does it affect?**
   - Controller only
   - ExtProc only (most translator work)
   - Both controller and ExtProc
   - CLI only

## Workflow Routing

Based on the answers, follow the appropriate workflow. **Always reference `aigw-contrib-go-style` before writing any Go code** — this is the single biggest factor in PR acceptance.

### New LLM Provider (most common)

1. **Understand the architecture**: Reference `aigw-contrib-architecture` to locate the relevant code
2. **Learn the Go style**: Reference `aigw-contrib-go-style` — mandatory before writing code
3. **Implement translator**: Use `aigw-contrib-add-translator` for the step-by-step guide
4. **Test**: Reference `aigw-contrib-testing` for test patterns
5. **PR submission**: Reference `aigw-contrib-pr-guide` for conventions and checklist

### New Feature (with API change)

1. **API PR first**: Use `aigw-contrib-add-api` to add the CRD types
2. **Understand the architecture**: Reference `aigw-contrib-architecture`
3. **Learn the Go style**: Reference `aigw-contrib-go-style`
4. **Implement**: Controller and/or ExtProc changes
5. **Test**: Reference `aigw-contrib-testing`
6. **PR submission**: Reference `aigw-contrib-pr-guide`

### New Feature (no API change)

1. **Understand the architecture**: Reference `aigw-contrib-architecture`
2. **Learn the Go style**: Reference `aigw-contrib-go-style`
3. **Implement**: Changes in the relevant subsystem
4. **Test**: Reference `aigw-contrib-testing`
5. **PR submission**: Reference `aigw-contrib-pr-guide`

### Bug Fix

1. **Locate the code**: Reference `aigw-contrib-architecture` to find the right subsystem
2. **Understand ExtProc**: Reference `aigw-contrib-extproc-internals` if the bug is in data plane
3. **Learn the Go style**: Reference `aigw-contrib-go-style`
4. **Fix and test**: Reference `aigw-contrib-testing` for the correct test pattern
5. **Add a regression test**: Create a test case that reproduces the bug
6. **PR submission**: Reference `aigw-contrib-pr-guide` — title: `fix(subsystem): description`

### API-Only Change

1. **Follow the API guide**: Use `aigw-contrib-add-api` for the complete workflow
2. **PR submission**: Reference `aigw-contrib-pr-guide` — title: `api(api): description`

### MCP Feature

1. **Understand the architecture**: Reference `aigw-contrib-architecture`
2. **Learn the Go style**: Reference `aigw-contrib-go-style`
3. **Implement**: Changes in MCP-related code
4. **Test**: Reference `aigw-contrib-testing`
5. **PR submission**: Reference `aigw-contrib-pr-guide`

### Test Improvement

1. **Learn the Go style**: Reference `aigw-contrib-go-style` for test conventions
2. **Choose the right test type**: Reference `aigw-contrib-testing` for the hierarchy
3. **Unit/data plane tests**: Follow patterns in `aigw-contrib-testing`
4. **E2E tests**: Use `aigw-contrib-e2e`
5. **PR submission**: Reference `aigw-contrib-pr-guide` — title: `test(subsystem): description`

## Pre-Flight Checks

Before submitting any PR, verify:

```bash
# Run all linters and formatters
make precommit

# Run unit tests
make test

# Run coverage check
make test-coverage

# If API types changed
make apigen && make codegen && make apidoc

# If controller changed
make test-controller

# If ExtProc/translator changed
make test-data-plane

# Verify the diff looks correct
git diff
```

## Skill Reference

| Skill | Type | When to Use |
|-------|------|-------------|
| `aigw-contrib-architecture` | Reference | Orient yourself in the codebase |
| `aigw-contrib-extproc-internals` | Reference | Understand ExtProc lifecycle, translators, streaming |
| `aigw-contrib-go-style` | Reference | **Mandatory** — Go patterns that determine PR acceptance |
| `aigw-contrib-pr-guide` | Reference | PR title format, import aliases, banned packages, checklists |
| `aigw-contrib-testing` | Reference | Test hierarchy, go-vcr, func-e, coverage thresholds |
| `aigw-contrib-add-api` | Atomic | Add or modify CRD API types |
| `aigw-contrib-add-translator` | Atomic | Add a new LLM provider translator |
| `aigw-contrib-e2e` | Atomic | Write end-to-end tests |

## Common Workflows Composed

| Scenario | Skill Sequence |
|----------|---------------|
| Add OpenAI → New Provider translator | `aigw-contrib-architecture` → `aigw-contrib-go-style` → `aigw-contrib-add-translator` → `aigw-contrib-testing` → `aigw-contrib-pr-guide` |
| Add a new CRD field | `aigw-contrib-add-api` → `aigw-contrib-pr-guide` |
| Add CRD field + implementation | `aigw-contrib-add-api` → `aigw-contrib-go-style` → implement → `aigw-contrib-testing` → `aigw-contrib-pr-guide` |
| Fix ExtProc translation bug | `aigw-contrib-architecture` → `aigw-contrib-extproc-internals` → `aigw-contrib-go-style` → fix → `aigw-contrib-testing` → `aigw-contrib-pr-guide` |
| Add missing test coverage | `aigw-contrib-go-style` → `aigw-contrib-testing` or `aigw-contrib-e2e` → `aigw-contrib-pr-guide` |
| Add new backend auth type | `aigw-contrib-add-api` → `aigw-contrib-go-style` → `aigw-contrib-extproc-internals` → implement → `aigw-contrib-testing` → `aigw-contrib-pr-guide` |

## Guidelines

- Always reference `aigw-contrib-go-style` before writing any Go code — performance patterns and JSON handling are the top PR rejection reasons
- Separate API PRs from implementation PRs — this is enforced by reviewers
- The most common contribution is a new translator — use `aigw-contrib-add-translator`
- Use `internal/json` (sonic) instead of `encoding/json` — linter enforced
- Use `gjson`/`sjson` for JSON field access and mutation — not maps
- When in doubt about ExtProc behavior, reference `aigw-contrib-extproc-internals`
- Run `make precommit` before every PR submission
