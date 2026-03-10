---
name: eg-nginx-analyze
description: Analyze existing ingress-nginx configuration, infer intent, and confirm with the user before migration
---

# Analyze and Confirm Existing ingress-nginx Configuration

Analyze existing ingress-nginx Ingress resources and annotations, infer what they do, and confirm with the user before migration. Ensures no behavior is lost or misunderstood during the move to Envoy Gateway.

## Instructions

### Step 1: Obtain Ingress configuration

**Option A — From cluster** (user has kubectl access):

```bash
kubectl get ingress --all-namespaces -o yaml > ingress-backup.yaml
```

**Option B — From user-provided YAML**: User pastes or provides Ingress manifests.

Parse each Ingress resource and extract: `metadata.name`, `metadata.namespace`, `metadata.annotations`, `spec.rules`, `spec.tls`, `spec.ingressClassName`.

### Step 2: Interpret each Ingress

For each Ingress, produce a plain-language summary. Include:

| Aspect | What to extract | Example interpretation |
|--------|-----------------|-------------------------|
| **Hosts** | `spec.rules[].host` | "Traffic for `api.example.com` and `www.example.com`" |
| **Paths** | `spec.rules[].http.paths` | "`/api/*` → service `api-svc:8080`, `/` → service `web-svc:80`" |
| **TLS** | `spec.tls` | "TLS for `*.example.com` using secret `tls-secret`" |
| **Annotations** | All `nginx.ingress.kubernetes.io/*` | See annotation interpretation below |

### Step 3: Interpret common annotations

Map each annotation to human-readable intent. Use `eg-nginx-capability-map` for full reference.

| Annotation (prefix `nginx.ingress.kubernetes.io/`) | Interpretation |
|----------------------------------------------------|----------------|
| `whitelist-source-range` | "Only allow requests from IP ranges: ..." |
| `limit-rps`, `limit-connections` | "Rate limit: X requests/sec or Y connections" |
| `auth-type`, `auth-secret` | "Basic auth using secret ..." |
| `auth-url` | "External auth: validate each request via URL ..." |
| `enable-cors`, `cors-*` | "CORS: allow origin X, methods Y, ..." |
| `affinity`, `affinity-mode` | "Session affinity: cookie-based, sticky to same backend" |
| `canary`, `canary-by-header`, `canary-weight` | "Canary: X% traffic to canary when header Y present" |
| `force-ssl-redirect` | "Redirect HTTP → HTTPS" |
| `backend-protocol` | "Backend uses HTTPS" |
| `configuration-snippet`, `server-snippet` | "Custom NGINX config (⚠️ no direct EG equivalent)" |

### Step 4: Present summary and ask for confirmation

Output a structured summary like:

```
## Ingress Analysis Summary

### Ingress: <namespace>/<name>
- **Hosts**: [list]
- **Paths**: [path → service mapping]
- **TLS**: [yes/no, secret]
- **Annotations and inferred behavior**:
  - [annotation]: [interpretation]
  - ...
- **Migration notes**: [any gaps or manual work needed]

### Ingress: ...
```

Then ask:

> **Please confirm**: Does this accurately describe what your ingress-nginx setup does? Are there any behaviors (e.g., from ConfigMaps, controller flags, or custom config) not captured here?

### Step 5: Identify migration gaps

After confirmation, list:

1. **Features with direct EG equivalent** — Will use `eg-nginx-capability-map` during conversion
2. **Features needing workarounds** — Document the workaround
3. **Features with no equivalent** — Flag for manual handling or alternative design

### Step 6: Output for next step

Provide:

- Confirmed summary of current behavior
- List of features to migrate (with mapping to EG resources)
- Items requiring manual handling
- Recommendation to proceed to `eg-nginx-migration-approach` or `eg-nginx-capability-map` for unclear mappings

## Validation Checklist

- [ ] All Ingress resources parsed (from cluster or user YAML)
- [ ] Each Ingress has host, path, TLS, and annotation summary
- [ ] Annotations interpreted in plain language
- [ ] User asked to confirm or correct the summary
- [ ] Migration gaps (direct / workaround / unsupported) identified
- [ ] Next step (migration approach or capability map) suggested

## References

- [ingress-nginx Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [eg-nginx-capability-map](/gateway/adopters/skills/eg-nginx-capability-map/SKILL.md) — Annotation → Envoy Gateway mapping
