# Envoy Skills Repository

This repository contains coding agent skills for the Envoy ecosystem (Envoy Gateway, Envoy Proxy, Envoy AI Gateway).

## Structure

- `gateway/` - Envoy Gateway skills
  - `adopters/` - For developers deploying Envoy Gateway
  - `contributors/` - For developers contributing to the Envoy Gateway codebase
- `proxy/` - Envoy Proxy skills (planned)
- `ai-gateway/` - Envoy AI Gateway skills (planned)

Each audience directory contains:
- `skills/<name>/SKILL.md` - Atomic slash-command skills
- `agents/<name>.md` - Orchestrating agents that compose skills
- `rules/<name>.md` - Always-on context rules

## Conventions

- Skill names use lowercase with hyphens: `eg-install`, `eg-auth`
- Prefix skills by project: `eg-` (gateway), `ep-` (proxy), `eai-` (AI gateway)
- Skills generate working Kubernetes YAML targeting the latest stable release
- Rules reference the Envoy Gateway threat model and Gateway API spec
- Agents ask intake questions before generating configuration

## Key References

- Envoy Gateway docs: https://gateway.envoyproxy.io/docs/
- Envoy Gateway GitHub: https://github.com/envoyproxy/gateway
- Gateway API spec: https://gateway-api.sigs.k8s.io/
- Envoy Proxy docs: https://www.envoyproxy.io/docs/envoy/latest/
- Envoy AI Gateway docs: https://aigateway.envoyproxy.io/docs/

## When Editing Skills

- Use the kapa tool (search_envoy_knowledge_sources) to verify current best practices
- All YAML must use correct apiVersion for Gateway API v1 resources
- Include comments in generated YAML explaining non-obvious choices
- Reference the threat model (EGTM-xxx) when making security recommendations
