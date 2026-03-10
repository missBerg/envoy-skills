# Envoy Skills for Coding Agents

Agent skills that help developers adopt and contribute to the Envoy ecosystem. Install these into your coding agent (Claude Code, Cursor, Copilot, etc.) to get best-practice guidance when working with Envoy projects.

## Installation

### Via skills.sh (recommended)

```bash
# Install all Envoy Gateway adopter skills
npx skills add missBerg/envoy-skills

# Preview available skills first
npx skills add missBerg/envoy-skills --list

# Install a specific skill
npx skills add missBerg/envoy-skills --skill eg-install

# Install to a specific agent
npx skills add missBerg/envoy-skills -a cursor
```

### Via install script

```bash
# From within your project directory
/path/to/envoy-skills/install.sh gateway/adopters
```

### Manual

```bash
cp -r /path/to/envoy-skills/gateway/adopters/skills/* .claude/skills/
```

## Projects

| Project | Status | Description |
|---------|--------|-------------|
| [Envoy Gateway](gateway/) | Active | Kubernetes-native API gateway built on Envoy Proxy |
| [Envoy Proxy](proxy/) | Planned | Core Envoy Proxy data plane |
| [Envoy AI Gateway](ai-gateway/) | Active | AI-specific traffic management and model routing for LLM providers |

## Audiences

Each project separates skills by audience:

- **Adopters** - Developers deploying and configuring the project in their infrastructure
- **Contributors** - Developers contributing to the open source codebase

## Envoy Gateway Adopter Skills

### Atomic Skills (generate working YAML for a single concern)

| Skill | Purpose |
|-------|---------|
| `/eg-install` | Install Envoy Gateway via Helm |
| `/eg-gateway` | Create Gateway + GatewayClass |
| `/eg-route` | HTTP/gRPC/TCP/UDP routing |
| `/eg-tls` | TLS termination + cert-manager |
| `/eg-auth` | JWT, OIDC, API Key, ExtAuth security policies |
| `/eg-rate-limit` | Local and global rate limiting |
| `/eg-backend-policy` | Load balancing, retries, health checks |
| `/eg-extension` | ExtProc, Wasm, Lua extensions |
| `/eg-observability` | Access logging, metrics, tracing |
| `/eg-client-policy` | Client traffic policies, timeouts |

### Orchestrator Skills (interview you, then compose atomic skills)

| Skill | Use Case |
|-------|----------|
| `/eg-orchestrator` | **Start here** - interviews you about your use case and guides you |
| `/eg-webapp` | Web application ingress with TLS and auth |
| `/eg-api-gateway` | API gateway with rate limiting and security |
| `/eg-multi-tenant` | Multi-tenant SaaS with namespace isolation |
| `/eg-enterprise` | Production-grade setup with full security and observability |
| `/eg-extend` | Build custom data plane extensions |
| `/eg-service-mesh` | Integration with Istio or Cilium |

### Version and Migration Skills

| Skill | Purpose |
|-------|---------|
| `/eg-version` | Version compatibility matrix, upgrade readiness checks |
| `/eg-migrate` | Step-by-step migration between Envoy Gateway versions |

### Reference Skills (best practices and context)

| Skill | Topic |
|-------|-------|
| `/eg-fundamentals` | Gateway API resource hierarchy, CRDs, naming conventions |
| `/eg-security-guide` | Threat model findings, RBAC, TLS hardening |
| `/eg-production-guide` | Deployment modes, performance tuning, operations |

## Envoy AI Gateway Adopter Skills

Envoy AI Gateway extends Envoy Gateway to provide a unified API gateway for generative AI services (OpenAI, Anthropic, AWS Bedrock, Azure OpenAI, GCP Vertex AI, Cohere, etc.).

### Atomic Skills

| Skill | Purpose |
|-------|---------|
| `/eai-install` | Install Envoy AI Gateway and Envoy Gateway with AI integration |
| `/eai-route` | Create AIGatewayRoute with model-based routing |
| `/eai-backend` | Create AIServiceBackend and Backend for an AI provider |
| `/eai-auth` | Configure BackendSecurityPolicy for provider authentication |

### Reference Skills

| Skill | Topic |
|-------|-------|
| `/eai-fundamentals` | CRDs, API schemas, resource hierarchy, provider auth types |

### Orchestrator Skills

| Skill | Use Case |
|-------|----------|
| `/eai-orchestrator` | **Start here** — interviews you and composes eai-install, eai-route, eai-backend, eai-auth |

### Installation

```bash
# Install AI Gateway adopter skills
/path/to/envoy-skills/install.sh ai-gateway/adopters

# Or copy manually
cp -r /path/to/envoy-skills/ai-gateway/adopters/skills/* .claude/skills/
```

## Knowledge Sources

These skills are built from:
- [Envoy Gateway documentation](https://gateway.envoyproxy.io/docs/)
- [Envoy Proxy documentation](https://www.envoyproxy.io/docs/envoy/latest/)
- [Kubernetes Gateway API specification](https://gateway-api.sigs.k8s.io/)
- [envoyproxy/gateway](https://github.com/envoyproxy/gateway) source code
- [envoyproxy/envoy](https://github.com/envoyproxy/envoy) source code
- [envoyproxy/ai-gateway](https://github.com/envoyproxy/ai-gateway) source code
- [Envoy AI Gateway documentation](https://aigateway.envoyproxy.io/docs/)
- Community discussions, Q&A, and real-world deployment patterns

## Target Versions

Skills currently target **Envoy Gateway v1.7.0** (Gateway API v1.4.1) and **Envoy AI Gateway v0.5.0**. Version information is centralized in `versions.yaml`.

## Testing

### Validate skill format and version consistency

```bash
tests/validate-skills.sh
```

### Extract and inspect YAML from skills

```bash
tests/extract-yaml.sh gateway/adopters/skills/eg-install/SKILL.md
```

### Run E2E tests in a kind cluster

```bash
# Set up kind cluster with Envoy Gateway
tests/setup-cluster.sh

# Run tests
tests/e2e/test-core.sh
tests/e2e/test-policies.sh
tests/e2e/test-dry-run.sh

# Clean up
tests/setup-cluster.sh --cleanup
```

Requires: [kind](https://kind.sigs.k8s.io/), [kubectl](https://kubernetes.io/docs/tasks/tools/), [helm](https://helm.sh/)

## Contributing

See individual project READMEs for contribution guidelines. Skills should be tested against the latest stable release of each project.

## License

Apache License 2.0
