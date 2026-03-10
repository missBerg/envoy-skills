# Proposal: Migration from ingress-nginx to Envoy Gateway — Skill Category

This document proposes a new category of Envoy Gateway skills for migrating from **ingress-nginx** (Kubernetes Ingress Controller) to **Envoy Gateway**. It is based on web research, official documentation, and community migration guides.

> **Context**: ingress-nginx was retired by Kubernetes SIG-Network in March 2026. Existing deployments continue to work, but there are no further bug fixes or security patches. Envoy Gateway is a modern alternative implementing the Gateway API standard.

---

## Research Summary

### Key Sources

| Source | URL | Focus |
|--------|-----|-------|
| Envoy Gateway (official) | https://gateway.envoyproxy.io/latest/install/migrating-to-envoy/ | Migration from Ingress resources |
| Gateway API (official) | https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress-nginx/ | Ingress-NGINX → Gateway API |
| Tetrate | https://tetrate.io/blog/migrating-from-ingress-nginx-to-envoy-gateway | Migration guide, tools |
| OneUptime | https://oneuptime.com/blog/post/2026-02-09-nginx-to-envoy-gateway-migration/view | Step-by-step migration |
| infrascribbles | https://www.infrascribbles.com/blog/envoy-gateway-migration | Rate limiting, IP whitelist, OAuth2 mapping |
| ingress2gateway | https://github.com/kubernetes-sigs/ingress2gateway | Official SIG-Network conversion tool |
| ingress2eg | https://github.com/kkk777-7/ingress2eg | NGINX annotations → Envoy Gateway CRDs |
| ingress-nginx annotations | https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/ | Full annotation reference |

### Migration Tools

- **ingress2gateway**: Official Kubernetes SIG-Network tool. Converts Ingress → Gateway API (Gateway, HTTPRoute). Does not handle NGINX-specific annotations.
- **ingress2eg**: Unofficial fork. Converts 16+ NGINX annotation categories (session affinity, auth, rate limiting, CORS, canary, etc.) into Envoy Gateway CRDs (BackendTrafficPolicy, SecurityPolicy, etc.).

### Architectural Differences

| Aspect | ingress-nginx | Envoy Gateway |
|--------|---------------|---------------|
| Config model | Monolithic Ingress + annotations | Gateway API (Gateway, HTTPRoute) + policy CRDs |
| Policies | Annotation-based, scattered | Separate resources (SecurityPolicy, BackendTrafficPolicy, ClientTrafficPolicy) |
| Rate limiting | Annotations | BackendTrafficPolicy |
| IP whitelisting | `whitelist-source-range` | SecurityPolicy |
| TLS | Ingress spec + annotations | ClientTrafficPolicy + cert-manager |
| gRPC | Special config | Native GRPCRoute |
| Multi-tenancy | Monolithic | Role-oriented (Gateway vs HTTPRoute) |

---

## Proposed Skills

Skills use the prefix `eg-nginx-` to distinguish them from `eg-migrate` (which is for Envoy Gateway version upgrades).

### 1. `eg-nginx-readiness` — Evaluate Readiness to Migrate

**Type**: Reference / Orchestrator  
**Description**: Assess whether the cluster, team, and configuration are ready to migrate from ingress-nginx to Envoy Gateway.

**Covers**:
- **Cluster readiness**: Kubernetes version (check `versions.yaml` for EG support), available resources, LoadBalancer/NodePort support
- **Environment type**: Local (kind/minikube), managed (EKS, GKE, AKS), bare metal, on-prem
- **Configuration complexity**: Number of Ingress resources, annotation density, use of NGINX-specific features
- **Team readiness**: Familiarity with Gateway API, time for testing, rollback plan
- **Dependency checks**: cert-manager, external auth, monitoring/observability stack
- **Risk factors**: Unsupported annotations, custom `configuration-snippet`, TLS client cert auth

**Output**: Readiness score, gap list, recommended preparation steps, and whether to proceed or defer.

---

### 2. `eg-nginx-analyze` — Understand and Confirm Existing ingress-nginx Config

**Type**: Orchestrator  
**Description**: Analyze existing ingress-nginx configuration, infer intent, and confirm with the user what each Ingress and annotation does before migration.

**Covers**:
- **Discovery**: Extract Ingress resources and annotations from the cluster or provided YAML
- **Interpretation**: Explain each Ingress rule, host, path, backend, and annotation in plain language
- **Confirmation flow**: Present a summary and ask the user to confirm or correct:
  - Hosts and paths
  - TLS/HTTPS behavior
  - Auth (basic, OAuth2, external auth)
  - Rate limiting, CORS, redirects
  - Session affinity, canary
  - Custom snippets or non-standard usage
- **Gap identification**: Flag annotations or patterns that may not have a direct Envoy Gateway equivalent

**Output**: Human-readable summary of current behavior, list of features to migrate, and any items requiring manual handling.

---

### 3. `eg-nginx-capability-map` — Map ingress-nginx Capabilities to Envoy Gateway

**Type**: Reference  
**Description**: Reference skill mapping ingress-nginx annotations and behaviors to Envoy Gateway resources and patterns.

**Covers**:
- **Annotation → Resource mapping table**:
  - `whitelist-source-range` → SecurityPolicy (IP allow/deny)
  - `limit-rps`, `limit-connections` → BackendTrafficPolicy (rate limit)
  - `auth-type`, `auth-secret` → SecurityPolicy (basic auth) or JWT/OIDC
  - `auth-url` → ExtAuth / external auth
  - `enable-cors`, `cors-*` → BackendTrafficPolicy or ClientTrafficPolicy
  - `affinity`, `affinity-mode` → BackendTrafficPolicy (session affinity)
  - `canary-*` → HTTPRoute (header/cookie/weight-based routing)
  - `force-ssl-redirect` → HTTPRoute redirect filters
  - `backend-protocol` → BackendTrafficPolicy (HTTPS backends)
  - `configuration-snippet` → EnvoyExtensionPolicy or manual Envoy config (with caveats)
- **Direct equivalents vs. workarounds vs. unsupported**
- **Links to relevant skills**: eg-auth, eg-rate-limit, eg-backend-policy, eg-client-policy, eg-tls

**Output**: Lookup table and guidance for each feature category.

---

### 4. `eg-nginx-migration-approach` — Choose and Execute Migration Strategy

**Type**: Orchestrator / Reference  
**Description**: Help the user choose a migration approach (big-bang, incremental, parallel) and provide step-by-step execution guidance.

**Covers**:
- **Approach options**:
  - **Parallel run**: Install Envoy Gateway alongside ingress-nginx; different external IPs; migrate routes incrementally; cut over per-host or per-namespace
  - **Incremental**: Convert one Ingress at a time; use ingress2gateway/ingress2eg; validate; switch DNS or LB
  - **Big-bang**: Convert all Ingress resources; test in staging; cut over in one window
- **Environment-specific guidance**:
  - **Managed K8s (EKS, GKE, AKS)**: LoadBalancer services, Ingress classes, DNS
  - **Bare metal / on-prem**: MetalLB, NodePort, host networking
  - **Local (kind/minikube)**: Port-forward, Ingress controller setup
- **Tool usage**: When to use ingress2gateway vs. ingress2eg; dry-run and validation
- **Cutover**: DNS TTL, health checks, rollback triggers

**Output**: Chosen approach, checklist, and concrete commands for the user’s environment.

---

### 5. `eg-nginx-migrate-orchestrator` — Migration Orchestrator

**Type**: Orchestrator  
**Description**: Entry point for migration. Interviews the user, delegates to readiness → analyze → capability-map → migration-approach, and coordinates the full flow.

**Intake questions**:
1. Do you have access to the cluster or can you provide Ingress YAML?
2. What type of Kubernetes cluster? (managed, bare metal, local)
3. What is your risk tolerance? (parallel run vs. big-bang)
4. Do you use cert-manager or another certificate solution?
5. Which NGINX features do you rely on? (auth, rate limit, CORS, canary, etc.)

**Workflow**:
1. Run `eg-nginx-readiness` (or delegate)
2. Run `eg-nginx-analyze` to understand and confirm config
3. Use `eg-nginx-capability-map` for any unclear mappings
4. Use `eg-nginx-migration-approach` to choose and execute strategy
5. Generate or validate converted manifests (ingress2gateway/ingress2eg + manual tweaks)

---

## Skill Dependency Graph

```
eg-nginx-migrate-orchestrator (entry point)
    ├── eg-nginx-readiness
    ├── eg-nginx-analyze
    ├── eg-nginx-capability-map (reference)
    └── eg-nginx-migration-approach
```

---

## Naming and Placement

| Skill | Path | Category |
|-------|------|----------|
| eg-nginx-readiness | `gateway/adopters/skills/eg-nginx-readiness/SKILL.md` | Reference |
| eg-nginx-analyze | `gateway/adopters/skills/eg-nginx-analyze/SKILL.md` | Orchestrator |
| eg-nginx-capability-map | `gateway/adopters/skills/eg-nginx-capability-map/SKILL.md` | Reference |
| eg-nginx-migration-approach | `gateway/adopters/skills/eg-nginx-migration-approach/SKILL.md` | Orchestrator |
| eg-nginx-migrate-orchestrator | `gateway/adopters/skills/eg-nginx-migrate-orchestrator/SKILL.md` | Orchestrator |

---

## Implementation Checklist

- [x] Create `eg-nginx-readiness` — readiness evaluation
- [x] Create `eg-nginx-analyze` — config analysis and user confirmation
- [x] Create `eg-nginx-capability-map` — annotation → EG mapping reference
- [x] Create `eg-nginx-migration-approach` — migration strategy and execution
- [x] Create `eg-nginx-migrate-orchestrator` — migration entry point
- [x] Update `eg-orchestrator` to mention migration path and delegate to `eg-nginx-migrate-orchestrator` when user says they are migrating from ingress-nginx
- [x] Add migration keywords to `plugin.json` (e.g. `ingress-nginx`, `migration`, `ingress`)
- [x] Run `tests/validate-skills.sh` and `tests/extract-yaml.sh` on new skills

---

## References

- [Envoy Gateway: Migrating from Ingress](https://gateway.envoyproxy.io/latest/install/migrating-to-envoy/)
- [Gateway API: Migrating from Ingress-NGINX](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress-nginx/)
- [ingress-nginx Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway)
- [ingress2eg](https://github.com/kkk777-7/ingress2eg)
- [Tetrate: Migrating from ingress-nginx to Envoy Gateway](https://tetrate.io/blog/migrating-from-ingress-nginx-to-envoy-gateway)
