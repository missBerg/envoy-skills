---
name: eg-migrate
description: "Migrate Envoy Gateway between versions with pre-flight checks, step-by-step upgrade procedures, and rollback guidance"
arguments:
  - name: From
    description: "Current Envoy Gateway version (e.g., v1.6.2)"
    required: true
  - name: To
    description: "Target Envoy Gateway version (e.g., v1.7.0). Defaults to latest stable v1.7.0."
    required: false
---

Migrate an Envoy Gateway installation from one version to another. This skill runs pre-flight checks, applies the correct CRD and controller upgrade sequence, handles version-specific breaking changes, and provides rollback guidance.

## Instructions

### Step 0: Set variables

Determine the source and target versions. If the user did not provide a target version, use the default:

- **From**: `${From}` (required -- the currently running version)
- **To**: `${To}` or `v1.7.0` if not specified (latest stable release)

---

## Phase 1: Pre-Flight Checks

Run every check below before touching the cluster. If any check fails, stop and resolve the issue first.

### 1.1 Verify the current Envoy Gateway version

```bash
# Confirm the running controller image matches the declared From version
kubectl get deployment envoy-gateway -n envoy-gateway-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Compare the output against `${From}`. If they do not match, confirm the correct source version with the user before proceeding.

### 1.2 Check current Gateway API CRD versions

```bash
# List installed Gateway API CRDs and their stored versions
kubectl get crds | grep -E 'gateway\.networking\.k8s\.io|gateway\.envoyproxy\.io'
```

Record the output. This is needed to determine which CRD migrations apply.

### 1.3 Check for unhealthy Gateways and Routes

```bash
# Gateways that are not Programmed
kubectl get gateways --all-namespaces -o json | \
  jq -r '.items[] | select(.status.conditions[]? | select(.type=="Programmed" and .status!="True")) | "\(.metadata.namespace)/\(.metadata.name)"'

# HTTPRoutes that are not Accepted
kubectl get httproutes --all-namespaces -o json | \
  jq -r '.items[] | select(.status.parents[]?.conditions[]? | select(.type=="Accepted" and .status!="True")) | "\(.metadata.namespace)/\(.metadata.name)"'
```

If any Gateways or Routes are unhealthy, investigate and fix them before upgrading. Upgrading with broken resources can mask new issues introduced by the migration.

### 1.4 Backup all Envoy Gateway resources

```bash
# Full backup of every EG-related resource across all namespaces
kubectl get \
  gateway,httproute,grpcroute,tlsroute,tcproute,udproute,\
  securitypolicy,backendtrafficpolicy,clienttrafficpolicy,\
  envoyproxy,envoyextensionpolicy,envoypatchpolicy,backendtlspolicy \
  --all-namespaces -o yaml > eg-backup-$(date +%Y%m%d).yaml
```

Verify the backup file is non-empty and contains the expected resources:

```bash
grep -c 'kind:' eg-backup-$(date +%Y%m%d).yaml
```

> **Critical**: Do not proceed without a valid backup. This file is your only recovery path if CRD changes cause data loss.

### 1.5 Check Helm release status

```bash
helm list -n envoy-gateway-system
helm history eg -n envoy-gateway-system
```

Confirm the Helm release named `eg` exists and is in a `deployed` state.

---

## Phase 2: Version-Specific Migration Notes

Apply the relevant notes based on the `${From}` and `${To}` versions. If a section does not apply to the version range, skip it.

### v1.5.x to v1.6.x

**Breaking change: BackendTLSPolicy API version moved from v1alpha3 to v1.**

Before upgrading, update all BackendTLSPolicy manifests to use the new API version:

```bash
# Find all BackendTLSPolicy resources still using the old API version
kubectl get backendtlspolicy --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'
```

If you have BackendTLSPolicy manifests stored in Git or on disk, update them:

```bash
# Update apiVersion in local manifest files
find . -name '*.yaml' -o -name '*.yml' | \
  xargs grep -l 'gateway.networking.k8s.io/v1alpha3' | \
  xargs sed -i.bak 's|gateway.networking.k8s.io/v1alpha3|gateway.networking.k8s.io/v1|g'
```

> **Important**: The CRD upgrade in Phase 3 will add the new stored version. Existing resources are migrated automatically by the API server, but your source-of-truth manifests (Git, Helm values, Kustomize overlays) must be updated to `v1` or future applies will fail.

### v1.6.x to v1.7.x

**Known issue: HTTPRoute status.parents validation became stricter.**

After upgrading, null values in `status.parents` fields are no longer accepted. Routes with stale or malformed status may report errors.

**Potential 404 errors if CRDs are not sequenced correctly.**

The CRD update must complete before the controller upgrade. If the controller starts before the new CRDs are registered, routes may return 404 until reconciliation catches up.

Post-upgrade, verify all HTTPRoutes are Accepted:

```bash
kubectl get httproutes --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): " + (.status.parents[]?.conditions[]? | select(.type=="Accepted") | .status)'
```

### Multi-version jumps (e.g., v1.5.x to v1.7.x)

Jumping across multiple minor versions is supported but carries higher risk.

**Recommended approach**: Step through each intermediate minor version sequentially (v1.5 -> v1.6 -> v1.7). This is the safest path and ensures each version's migration logic runs correctly.

**Alternative approach**: If stepping through versions is impractical:

1. Apply all CRD changes at once for the target version (Phase 3, Step 1).
2. Handle every intermediate breaking change before upgrading the controller:
   - If jumping past v1.6.x: update all BackendTLSPolicy manifests from `v1alpha3` to `v1` (see v1.5.x to v1.6.x notes above).
3. Upgrade the controller directly to the target version (Phase 3, Step 2).

> **Warning**: Multi-version jumps skip intermediate controller migration logic. Test this path in a staging environment first.

---

## Phase 3: Generic Upgrade Procedure

These steps apply to every version upgrade. Run them in order.

### Step 1: Update CRDs first (always)

CRDs must be updated before the controller. The controller may depend on new CRD fields or versions that do not exist yet.

```bash
# Pull the target version Helm chart to get the CRD manifests
helm pull oci://docker.io/envoyproxy/gateway-helm --version ${To} --untar

# Apply Gateway API CRDs with server-side apply to handle field ownership
kubectl apply --force-conflicts --server-side -f ./gateway-helm/crds/gatewayapi-crds.yaml

# Apply Envoy Gateway CRDs
kubectl apply --force-conflicts --server-side -f ./gateway-helm/crds/generated
```

Verify CRDs were updated:

```bash
kubectl get crds gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'
```

> **Why `--force-conflicts --server-side`?** CRDs are cluster-scoped resources that may have field managers from the previous Helm install. Server-side apply with force-conflicts ensures clean ownership transfer without manual conflict resolution.

### Step 2: Upgrade the controller

```bash
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${To} \
  -n envoy-gateway-system
```

If you have custom Helm values, include them:

```bash
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${To} \
  -n envoy-gateway-system \
  -f values.yaml
```

### Step 3: Verify the controller is running

```bash
# Wait for the deployment to become available
kubectl wait --timeout=5m -n envoy-gateway-system \
  deployment/envoy-gateway --for=condition=Available

# Confirm the GatewayClass is accepted
kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
```

The GatewayClass status should return `True`.

---

## Phase 4: Post-Upgrade Validation Checklist

Run every check below after the upgrade completes. All checks must pass before declaring the migration successful.

### 4.1 GatewayClass is Accepted

```bash
kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
# Expected: True
```

### 4.2 All Gateways are Programmed

```bash
kubectl get gateways --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): " + (.status.conditions[]? | select(.type=="Programmed") | .status)'
# Expected: all True
```

### 4.3 All Routes are Accepted

```bash
kubectl get httproutes --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): " + (.status.parents[]?.conditions[]? | select(.type=="Accepted") | .status)'
# Expected: all True
```

### 4.4 Envoy proxy pods are healthy

```bash
kubectl get pods --all-namespaces -l app.kubernetes.io/component=proxy -o wide
# Expected: all Running, all containers Ready
```

### 4.5 Traffic is flowing

```bash
# Replace with your actual gateway address and a known-good route
GATEWAY_IP=$(kubectl get gateway eg -n default -o jsonpath='{.status.addresses[0].value}')
curl -v http://${GATEWAY_IP}/healthz
# Expected: 200 OK (or the expected response for your application)
```

### 4.6 No error logs in the controller

```bash
kubectl logs -n envoy-gateway-system deployment/envoy-gateway --since=5m | grep -i error
# Expected: no unexpected errors
```

---

## Phase 5: Rollback Procedure

If the upgrade fails or causes issues, roll back using the steps below.

### 5.1 Roll back the controller via Helm

```bash
helm rollback eg -n envoy-gateway-system
```

This reverts the controller deployment to the previous Helm revision.

### 5.2 Verify rollback

```bash
helm list -n envoy-gateway-system
kubectl get deployment envoy-gateway -n envoy-gateway-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Confirm the image tag matches `${From}`.

### 5.3 CRD rollback (if needed)

> **Warning**: CRD rollbacks are manual and risky. Downgrading CRDs can cause data loss if new fields were already populated by the newer controller. Only attempt this if the upgrade introduced CRD-level issues.

If CRD changes caused problems, restore from the backup taken in Phase 1:

```bash
# Re-apply the backed-up resources
kubectl apply -f eg-backup-$(date +%Y%m%d).yaml
```

For CRDs themselves, you may need to reinstall the previous version's CRDs:

```bash
helm pull oci://docker.io/envoyproxy/gateway-helm --version ${From} --untar
kubectl apply --force-conflicts --server-side -f ./gateway-helm/crds/gatewayapi-crds.yaml
kubectl apply --force-conflicts --server-side -f ./gateway-helm/crds/generated
```

> **Recommendation**: If CRD rollback is necessary, consider restoring the entire cluster state from backup rather than selectively reverting CRDs. Partial CRD rollbacks can leave the cluster in an inconsistent state.

---

## Warnings

- **Never skip CRD updates.** The controller depends on CRDs being at the correct version. Upgrading the controller without updating CRDs first causes reconciliation failures and potential 404 errors.
- **Always backup before upgrading.** The backup command in Phase 1 is your safety net. Without it, CRD data loss is unrecoverable.
- **Test upgrades in a staging environment first.** Production upgrades should follow a validated staging run.
- **Review the release notes** for every version in your upgrade path: https://gateway.envoyproxy.io/news/releases/
- **Do not downgrade across minor versions without testing.** Envoy Gateway does not guarantee backward compatibility for CRD schemas across minor versions.

---

## Summary Checklist

Use this checklist to track progress through the migration:

- [ ] Verified current EG version matches `${From}`
- [ ] Checked Gateway API CRD versions
- [ ] Confirmed all Gateways are healthy
- [ ] Confirmed all Routes are healthy
- [ ] Created resource backup (`eg-backup-YYYYMMDD.yaml`)
- [ ] Verified Helm release is in deployed state
- [ ] Applied version-specific migration steps (if applicable)
- [ ] Updated CRDs with server-side apply
- [ ] Upgraded controller via Helm
- [ ] Controller deployment is Available
- [ ] GatewayClass is Accepted
- [ ] All Gateways are Programmed
- [ ] All Routes are Accepted
- [ ] Envoy proxy pods are healthy
- [ ] Traffic is flowing through the gateway
- [ ] No unexpected errors in controller logs
- [ ] Release notes reviewed for target version
