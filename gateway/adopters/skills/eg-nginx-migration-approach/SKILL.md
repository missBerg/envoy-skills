---
name: eg-nginx-migration-approach
description: Choose and execute migration strategy from ingress-nginx to Envoy Gateway — parallel, incremental, or big-bang
---

# Choose and Execute Migration Strategy

Help the user choose a migration approach (parallel run, incremental, or big-bang) and provide step-by-step execution guidance tailored to their environment.

## Instructions

### Step 1: Understand context

Gather from the user or prior steps (`eg-nginx-readiness`, `eg-nginx-analyze`):

- **Environment**: Managed K8s (EKS, GKE, AKS), bare metal, local
- **Risk tolerance**: Prefer parallel testing vs. fast cutover
- **Ingress count**: Few vs. many
- **Downtime tolerance**: Zero vs. acceptable maintenance window

### Step 2: Recommend approach

| Approach | When to use | Pros | Cons |
|----------|-------------|-----|------|
| **Parallel run** | Production, low risk tolerance | Test EG alongside NGINX; no prod impact until cutover | Two controllers; more resources |
| **Incremental** | Many Ingress, can migrate per-host/namespace | Migrate one at a time; validate each | Longer timeline; DNS/LB per cutover |
| **Big-bang** | Few Ingress, staging first, maintenance window OK | Single cutover; simpler | Higher risk; requires staging validation |

Default recommendation: **Parallel run** for production.

### Step 3: Environment-specific guidance

#### Managed Kubernetes (EKS, GKE, AKS)

- Envoy Gateway gets its own LoadBalancer Service (different external IP from ingress-nginx)
- Use DNS or LB routing to switch traffic: point host to new LB when ready
- IngressClass: Create `envoy` IngressClass; Gateway uses its own GatewayClass

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: envoy
spec:
  controller: gateway.envoyproxy.io/gatewayclass-controller
```

#### Bare metal / on-prem

- Requires MetalLB or similar for LoadBalancer, or NodePort
- MetalLB: Both controllers can have LoadBalancer; different IPs from same pool
- NodePort: Different node ports; update external LB/DNS to point to new port
- Host networking: Possible but more complex; document carefully

#### Local (kind, minikube)

- Use `kubectl port-forward` or NodePort for testing
- Install both controllers; use different ports or port-forward to each

### Step 4: Parallel run procedure

1. **Install Envoy Gateway** (do not remove ingress-nginx):

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  -n envoy-gateway-system \
  --create-namespace
```

2. **Create GatewayClass and Gateway** (see eg-gateway, eg-install)

3. **Convert Ingress** using ingress2gateway or ingress2eg:

```bash
# ingress2gateway (Gateway API only)
ingress2gateway convert -f ingress-backup.yaml -o gateway-api.yaml

# ingress2eg (includes NGINX annotations → EG CRDs)
# See https://github.com/kkk777-7/ingress2eg
```

4. **Apply converted resources** to a test namespace or with a different Gateway
5. **Validate**: curl against Envoy Gateway's external IP, compare with ingress-nginx
6. **Cutover**: Update DNS or LB to point to Envoy Gateway's IP
7. **Monitor**: Verify traffic; rollback by reverting DNS/LB if needed
8. **Decommission**: Remove ingress-nginx after stable period

### Step 5: Incremental procedure

1. Install Envoy Gateway alongside ingress-nginx
2. Convert one Ingress (or one host) at a time
3. Create HTTPRoute for that host/path; attach to shared Gateway
4. Use split DNS or LB rules to send a subset of traffic to EG
5. Validate; expand; repeat
6. Final cutover when all routes migrated

### Step 6: Big-bang procedure

1. **Staging first**: Run full migration in staging; validate all routes and policies
2. **Backup**: `kubectl get ingress --all-namespaces -o yaml > ingress-backup.yaml`
3. **Maintenance window**: Install EG, convert all Ingress, apply
4. **Cutover**: Switch DNS/LB to EG
5. **Rollback plan**: Keep ingress-nginx manifests; revert DNS and re-apply if needed

### Step 7: Cutover checklist

- [ ] DNS TTL lowered before cutover (e.g., 300s) for quick rollback
- [ ] Health checks configured for Envoy Gateway endpoints
- [ ] Rollback trigger defined (e.g., error rate > X%)
- [ ] Monitoring/alerting in place for both controllers during parallel run

## Validation Checklist

- [ ] Approach (parallel / incremental / big-bang) chosen with rationale
- [ ] Environment-specific steps (managed / bare metal / local) included
- [ ] Conversion tools (ingress2gateway, ingress2eg) referenced
- [ ] Cutover and rollback steps documented
- [ ] Envoy Gateway version from versions.yaml (v1.7.0)

## References

- [Envoy Gateway: Migrating from Ingress](https://gateway.envoyproxy.io/latest/install/migrating-to-envoy/)
- [Gateway API: Migrating from Ingress-NGINX](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress-nginx/)
- [ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway)
- [ingress2eg](https://github.com/kkk777-7/ingress2eg)
- eg-install, eg-gateway, eg-route
