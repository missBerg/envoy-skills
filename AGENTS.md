# Envoy Skills — Agent Instructions

This file is for AI agents working on the envoy-skills repository itself (not for end users).

## Repository Structure

```
envoy-skills/
├── .claude-plugin/
│   └── marketplace.json       # Skills.sh plugin registry
├── gateway/                   # Envoy Gateway skills
│   ├── adopters/              # For developers deploying Envoy Gateway
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json    # Plugin metadata
│   │   └── skills/            # All skills (atomic + orchestrators + guides)
│   │       └── <name>/SKILL.md
│   └── contributors/          # For EG contributors (planned)
├── proxy/                     # Envoy Proxy skills (planned)
├── ai-gateway/                # Envoy AI Gateway skills (planned)
├── AGENTS.md                  # This file
├── CLAUDE.md                  # Project context
├── README.md                  # User-facing documentation
├── install.sh                 # Manual installation script
└── LICENSE                    # Apache 2.0
```

## Skill Naming Conventions

- `eg-*` — Envoy Gateway adopter skills
- `egc-*` — Envoy Gateway contributor skills (future)
- `ep-*` — Envoy Proxy skills (future)
- `eai-*` — Envoy AI Gateway skills (future)

## Skill Categories

Skills fall into three categories (all use SKILL.md format):

| Category | Examples | Purpose |
|----------|----------|---------|
| **Atomic** | `eg-install`, `eg-auth`, `eg-tls` | Generate YAML for a single concern |
| **Orchestrator** | `eg-orchestrator`, `eg-webapp`, `eg-enterprise` | Interview user, compose atomic skills |
| **Reference** | `eg-fundamentals`, `eg-security-guide`, `eg-production-guide` | Provide context and best practices |

## SKILL.md Format

```yaml
---
name: skill-name
description: What this skill does and when to use it
---

# Skill Title

Body content with instructions, YAML templates, and checklists.
```

Required frontmatter: `name` and `description` only. The `name` must match the parent directory name.

## Adding a New Skill

1. Create `gateway/adopters/skills/<name>/SKILL.md`
2. Add YAML frontmatter with `name` and `description`
3. Write the skill body (keep under 500 lines; use references/ for longer content)
4. Verify correct apiVersions: `gateway.networking.k8s.io/v1` for Gateway API, `gateway.envoyproxy.io/v1alpha1` for EG CRDs
5. Use the EG version from `versions.yaml` (currently v1.7.0) — never hardcode without checking
6. Include TODO comments for user-customizable values
7. End with a validation checklist
8. Run `tests/validate-skills.sh` to check format and version consistency
9. Run `tests/extract-yaml.sh` on your skill to verify YAML extracts correctly

## Testing

Version configuration is centralized in `versions.yaml` at the repo root. All version references in skills should match `latest_stable` from that file.

```bash
# Validate all skills (format, naming, versions)
tests/validate-skills.sh

# Extract YAML from a specific skill
tests/extract-yaml.sh gateway/adopters/skills/<name>/SKILL.md

# Full E2E test (requires kind, kubectl, helm)
tests/setup-cluster.sh
tests/e2e/test-core.sh
tests/e2e/test-policies.sh
tests/e2e/test-dry-run.sh
tests/setup-cluster.sh --cleanup
```

## Key References

- Envoy Gateway docs: https://gateway.envoyproxy.io/docs/
- Gateway API spec: https://gateway-api.sigs.k8s.io/
- Envoy Gateway GitHub: https://github.com/envoyproxy/gateway
- Agent Skills spec: https://agentskills.io/specification
- Skills.sh: https://skills.sh
