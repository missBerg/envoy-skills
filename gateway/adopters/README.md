# Envoy Gateway - Adopter Skills

Skills for developers deploying and operating Envoy Gateway.

## Installation

```bash
# Via skills.sh
npx skills add envoyproxy/envoy-skills

# Or copy directly
cp -r skills/* /path/to/your-project/.claude/skills/
```

## Getting Started

1. Install these skills into your project
2. Use `/eg-orchestrator` for guided setup — it interviews you and delegates to the right skills
3. Or invoke individual skills directly: `/eg-install`, `/eg-auth`, `/eg-tls`, etc.

## All Skills

### Atomic (generate YAML for a single concern)

| Skill | Purpose |
|-------|---------|
| `/eg-install` | Install Envoy Gateway via Helm with production-ready defaults |
| `/eg-gateway` | Create Gateway and GatewayClass resources |
| `/eg-route` | Configure HTTP, gRPC, TCP, and UDP routing |
| `/eg-tls` | TLS termination with cert-manager integration |
| `/eg-auth` | Security policies: JWT, OIDC, API Key, ExtAuth |
| `/eg-rate-limit` | Local and global rate limiting |
| `/eg-backend-policy` | Load balancing, retries, health checks, circuit breaking |
| `/eg-extension` | ExtProc, Wasm, and Lua extensions |
| `/eg-observability` | Access logging, metrics, and tracing |
| `/eg-client-policy` | Client traffic policies, timeouts, connection limits |

### Orchestrators (guided workflows)

| Skill | Use Case |
|-------|----------|
| `/eg-orchestrator` | Interview-based setup guide — start here if unsure |
| `/eg-webapp` | Web application ingress with TLS and auth |
| `/eg-api-gateway` | API gateway with rate limiting and security |
| `/eg-multi-tenant` | Multi-tenant SaaS with namespace isolation |
| `/eg-enterprise` | Production-grade setup with full security and observability |
| `/eg-extend` | Build custom data plane extensions |
| `/eg-service-mesh` | Integrate with Istio or Cilium |

### Reference (best practices and context)

| Skill | Topic |
|-------|-------|
| `/eg-fundamentals` | Gateway API resource hierarchy, CRDs, naming conventions |
| `/eg-security-guide` | Threat model findings, RBAC, TLS hardening |
| `/eg-production-guide` | Deployment modes, performance tuning, operations |
