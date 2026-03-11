---
name: eg-nginx-readiness
description: Evaluate readiness to migrate from ingress-nginx to Envoy Gateway — cluster, environment, config complexity, and risk factors
---

# Evaluate Readiness to Migrate from ingress-nginx to Envoy Gateway

Assess whether your cluster, team, and configuration are ready to migrate from ingress-nginx to Envoy Gateway. Produces a readiness score, gap list, and recommended preparation steps.

> **Context**: ingress-nginx was retired by Kubernetes SIG-Network in March 2026. Envoy Gateway implements the Gateway API standard and is a recommended replacement.

## Instructions

### Step 1: Gather information

Before evaluating readiness, collect the following. Ask the user if not provided:

1. **Cluster access**: Can you run `kubectl` against the cluster?
2. **Environment type**: Local (kind/minikube), managed (EKS, GKE, AKS), bare metal, on-prem
3. **Ingress resources**: Number of Ingress resources and whether they use NGINX-specific annotations

### Step 2: Run cluster checks

If the user has cluster access, run these commands and interpret the results.

**Kubernetes version** (Envoy Gateway v1.7.0 supports K8s v1.31–v1.34):

```bash
kubectl version --short 2>/dev/null || kubectl version -o json | jq -r '.serverVersion.gitVersion'
```

**Existing Ingress resources**:

```bash
kubectl get ingress --all-namespaces -o wide
```

**Annotation density** (count annotations per Ingress):

```bash
kubectl get ingress --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.metadata.annotations | keys | length) annotations"'
```

**LoadBalancer / external IP support**:

```bash
kubectl get svc -n ingress-nginx 2>/dev/null || kubectl get svc --all-namespaces | grep -E 'LoadBalancer|NodePort'
```

**cert-manager** (if TLS is used):

```bash
kubectl get pods -n cert-manager 2>/dev/null || echo "cert-manager not found"
```

### Step 3: Evaluate readiness dimensions

Score each dimension (Ready / Needs work / Blocked). Provide a brief rationale.

| Dimension | Check | Ready | Needs work | Blocked |
|-----------|-------|-------|------------|---------|
| **Kubernetes version** | K8s v1.31+ for EG v1.7.0 | Version supported | Upgrade cluster first | Version too old |
| **Environment** | Managed K8s has LoadBalancer; bare metal needs MetalLB | LB available | Document LB setup | No LB option |
| **Config complexity** | Few Ingress, few annotations | &lt; 10 Ingress, &lt; 5 annotations each | Many Ingress or heavy annotations | Custom `configuration-snippet` |
| **NGINX features** | Auth, rate limit, CORS, canary | All have EG equivalents | Some need workarounds | Unsupported (e.g. Lua) |
| **TLS** | cert-manager or manual certs | cert-manager installed or certs ready | Need to install cert-manager | No cert strategy |
| **Team** | Familiarity with Gateway API | Team has time to test | Need training | No rollback plan |

### Step 4: Identify risk factors

Flag these explicitly:

- **`configuration-snippet`** or **`server-snippet`**: Custom NGINX config has no direct equivalent; requires EnvoyExtensionPolicy or manual Envoy config
- **TLS client certificate auth**: Supported via SecurityPolicy but requires different setup
- **External auth (`auth-url`)**: Maps to ExtAuth; verify ExtAuth service compatibility
- **Lua or other NGINX modules**: No direct port; may need Envoy Lua filter or alternative
- **Bare metal without MetalLB**: Need NodePort or host networking; different operational model

### Step 5: Produce readiness summary

Output a summary in this format:

```
## Readiness Summary

- **Overall**: [Ready to proceed | Prepare first | Defer migration]
- **Score**: X/6 dimensions ready

### Gaps
- [List specific gaps and remediation steps]

### Recommended preparation
1. [Action item]
2. [Action item]

### Next steps
- If ready: Proceed to eg-nginx-analyze to understand your config
- If not ready: [Specific remediation before re-evaluating]
```

## Validation Checklist

- [ ] Kubernetes version checked against versions.yaml (EG v1.7.0 → K8s v1.31+)
- [ ] Ingress count and annotation density assessed
- [ ] Environment type (managed vs bare metal vs local) considered
- [ ] Risk factors (snippets, Lua, etc.) flagged
- [ ] Clear recommendation: proceed, prepare, or defer
- [ ] Next step (eg-nginx-analyze or remediation) provided

## References

- [Envoy Gateway: Migrating from Ingress](https://gateway.envoyproxy.io/latest/install/migrating-to-envoy/)
- [Gateway API: Migrating from Ingress-NGINX](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress-nginx/)
- versions.yaml (repo root) — Envoy Gateway and Kubernetes version compatibility
