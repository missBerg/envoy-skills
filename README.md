# Envoy Skills for Coding Agents

Agent skills that help developers adopt and contribute to the Envoy ecosystem. Install these into your coding agent (Claude Code, Cursor, Copilot, etc.) to get best-practice guidance when working with Envoy projects.

## Installation

### Via skills.sh (recommended)

```bash
# Install all Envoy Gateway adopter skills
npx skills add envoyproxy/envoy-skills

# Preview available skills first
npx skills add envoyproxy/envoy-skills --list

# Install a specific skill
npx skills add envoyproxy/envoy-skills --skill eg-install

# Install to a specific agent
npx skills add envoyproxy/envoy-skills -a cursor
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
| [Envoy AI Gateway](ai-gateway/) | Planned | AI-specific traffic management and model routing |

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

### Reference Skills (best practices and context)

| Skill | Topic |
|-------|-------|
| `/eg-fundamentals` | Gateway API resource hierarchy, CRDs, naming conventions |
| `/eg-security-guide` | Threat model findings, RBAC, TLS hardening |
| `/eg-production-guide` | Deployment modes, performance tuning, operations |

## Knowledge Sources

These skills are built from:
- [Envoy Gateway documentation](https://gateway.envoyproxy.io/docs/)
- [Envoy Proxy documentation](https://www.envoyproxy.io/docs/envoy/latest/)
- [Kubernetes Gateway API specification](https://gateway-api.sigs.k8s.io/)
- [envoyproxy/gateway](https://github.com/envoyproxy/gateway) source code
- [envoyproxy/envoy](https://github.com/envoyproxy/envoy) source code
- Community discussions, Q&A, and real-world deployment patterns

## Contributing

See individual project READMEs for contribution guidelines. Skills should be tested against the latest stable release of each project.

## License

Apache License 2.0
