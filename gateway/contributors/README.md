# Envoy Gateway - Contributor Skills

Skills for coding agents contributing to the [envoyproxy/gateway](https://github.com/envoyproxy/gateway) open source project. These skills encode architecture knowledge, PR conventions, testing patterns, and translation pipeline workflows that reviewers consistently enforce.

## Reference Skills

| Skill | Description |
|-------|-------------|
| `eg-contrib-architecture` | Codebase architecture map — translation pipeline, directory layout, runner pattern, key types |
| `eg-contrib-envoy-internals` | Envoy Proxy internals — request lifecycle, xDS resource types, filter chain order, go-control-plane imports |
| `eg-contrib-pr-guide` | PR conventions — title format, API-first rule, common review feedback, file checklist |
| `eg-contrib-testing` | Testing patterns — golden file tests, e2e framework, CEL validation, anti-patterns |

## Atomic Skills

| Skill | Description |
|-------|-------------|
| `eg-contrib-add-api` | Step-by-step guide to add or extend a CRD API type — type definitions, validation, code generation |
| `eg-contrib-translate` | Step-by-step guide to implement Gateway API to IR and IR to xDS translation for a new feature |
| `eg-contrib-e2e` | Step-by-step guide to write an end-to-end test — test manifests, conformance framework, traffic assertions |

## Orchestrator Skill

| Skill | Description |
|-------|-------------|
| `eg-contrib-orchestrator` | Interviews you about your contribution and guides you through the correct workflow using contributor skills |

## Common Workflows

| Scenario | Skill Sequence |
|----------|---------------|
| Add a BackendTrafficPolicy field | `eg-contrib-add-api` → `eg-contrib-translate` → `eg-contrib-e2e` |
| Fix a translation bug | `eg-contrib-architecture` → fix → `eg-contrib-testing` |
| Add missing test coverage | `eg-contrib-testing` or `eg-contrib-e2e` |
| Add a new HTTP filter | `eg-contrib-envoy-internals` → `eg-contrib-add-api` → `eg-contrib-translate` → `eg-contrib-e2e` |
