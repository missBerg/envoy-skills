---
name: eg-version
description: "Envoy Gateway version information, compatibility matrix, and upgrade readiness checks"
---

# Envoy Gateway Version Reference

Quick reference for Envoy Gateway versions, compatibility requirements, and upgrade readiness. Use this skill to check what you are running, whether your cluster meets version requirements, and what to review before upgrading.

## Check Your Version

### Installed Envoy Gateway version

```bash
# Controller image version
kubectl get deployment envoy-gateway -n envoy-gateway-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Helm release version

```bash
helm list -n envoy-gateway-system -o json | \
  jq -r '.[] | select(.name=="eg") | .app_version'
```

### Gateway API CRD version installed on the cluster

```bash
# Check the Gateway CRD for its stored versions
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.status.storedVersions}'
```

### All Gateway API CRDs and their versions

```bash
kubectl get crd -o custom-columns=\
NAME:.metadata.name,\
VERSIONS:.status.storedVersions \
  | grep gateway.networking.k8s.io
```

### Envoy Proxy version in use by a specific Gateway

```bash
# Replace GATEWAY_NAMESPACE and GATEWAY_NAME with your values
kubectl get deployment -n GATEWAY_NAMESPACE \
  -l gateway.envoyproxy.io/owning-gateway-name=GATEWAY_NAME \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'
```

### GatewayClass controller version

```bash
kubectl get gatewayclass -o custom-columns=\
NAME:.metadata.name,\
CONTROLLER:.spec.controllerName,\
ACCEPTED:.status.conditions[0].status
```

## Compatibility Matrix

| EG Version | Gateway API | Kubernetes   | Envoy Proxy | Status       | EOL Date     |
|------------|-------------|--------------|-------------|--------------|--------------|
| **v1.7.0** | v1.4.1      | v1.31-v1.34  | v1.37.x     | Latest Stable |              |
| **v1.6.2** | v1.4.0      | v1.30-v1.33  | v1.36.x     | Previous Stable |            |
| **v1.5.0** | v1.3.0      | v1.29-v1.32  | v1.35.x     | End of Life  | 2025-11-01   |

> **Important**: Running an EOL version means no further security patches or bug fixes. Plan your upgrade path using the `/eg-migrate` skill.

### How to read the matrix

- **Gateway API**: The version of the Gateway API specification that the EG release implements. The Helm chart bundles CRDs matching this version.
- **Kubernetes**: The range of Kubernetes versions tested and supported. Running outside this range may work but is not guaranteed.
- **Envoy Proxy**: The data-plane version deployed by the controller. Managed automatically; do not override unless explicitly required.

## CRD API Versions

### Gateway API resources (upstream)

All GA Gateway API resources use the `v1` API group:

```text
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass | Gateway | HTTPRoute | GRPCRoute | ReferenceGrant
```

Experimental resources use `v1alpha2` or `v1alpha3`:

```text
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute | UDPRoute | TLSRoute

# BackendTLSPolicy moved to v1 in Gateway API v1.4.0 (EG v1.6+)
# For EG v1.5.x, it was under v1alpha3
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
```

### Envoy Gateway extension CRDs

All Envoy Gateway extension CRDs use `v1alpha1`:

```text
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy | BackendTrafficPolicy | SecurityPolicy
      EnvoyProxy | EnvoyExtensionPolicy | EnvoyPatchPolicy
      Backend | HTTPRouteFilter
```

### Verify CRD versions on the cluster

```bash
# List all Envoy Gateway CRDs with their served versions
kubectl get crd -o custom-columns=\
NAME:.metadata.name,\
SERVED:.spec.versions[*].name \
  | grep -E 'gateway\.(networking\.k8s\.io|envoyproxy\.io)'
```

## Version-Specific Notices

### v1.7.0 (Latest Stable)

**HTTPRoute status.parents validation is stricter**

The controller now validates that `status.parents` entries reference the correct Gateway and section name. Routes that previously had stale or incorrect parent references in their status may report errors after upgrade. After upgrading, check route status:

```bash
kubectl get httproute -A -o json | \
  jq -r '.items[] | select(.status.parents[]?.conditions[]?.type=="Accepted" and .status.parents[]?.conditions[]?.status=="False") | .metadata.namespace + "/" + .metadata.name'
```

**CRD sequencing is critical during upgrades**

When upgrading to v1.7.0, CRDs must be applied before the controller deployment rolls out. If using Helm with `--skip-crds`, apply CRDs manually first:

```bash
# Apply CRDs before upgrading the controller
helm template eg oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.7.0 \
  --set crds.gatewayAPI.enabled=true \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

# Then upgrade the controller
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  -n envoy-gateway-system \
  --skip-crds
```

### v1.6.x (Previous Stable)

**BackendTLSPolicy moved from v1alpha3 to v1**

If you have BackendTLSPolicy resources using `gateway.networking.k8s.io/v1alpha3`, they must be migrated to `gateway.networking.k8s.io/v1` when upgrading to v1.6.x. The v1alpha3 version is still served but deprecated.

```bash
# Check for BackendTLSPolicy resources still using alpha API
kubectl get backendtlspolicy -A -o json | \
  jq -r '.items[] | .apiVersion + " " + .metadata.namespace + "/" + .metadata.name'
```

**Action required**: Re-apply any BackendTLSPolicy manifests with `apiVersion: gateway.networking.k8s.io/v1` before the alpha version is removed in a future release.

### v1.5.x (End of Life)

**This version reached End of Life on 2025-11-01.**

- No further security patches or bug fixes will be released.
- Upgrade to v1.6.x or v1.7.0 as soon as possible.
- Review the `/eg-migrate` skill for step-by-step upgrade procedures.
- Key differences from v1.6: BackendTLSPolicy is still `v1alpha3`, Gateway API is v1.3.0.

## Release Cycle

Envoy Gateway follows a roughly **quarterly release cadence** with each minor release receiving patch updates until the next minor version is released plus a grace period.

- **Latest stable**: Receives active bug fixes and security patches.
- **Previous stable**: Receives critical security patches only.
- **Older releases**: End of Life, no further updates.

For the full release history and support schedule, see the official matrix:
https://gateway.envoyproxy.io/news/releases/matrix/

### Version support timeline

```
v1.5.x  ████████████░░░░░░░░  EOL 2025-11-01
v1.6.x  ░░░░████████████████  Previous stable (security fixes only)
v1.7.x  ░░░░░░░░████████████  Latest stable (active development)
```

## Upgrade Readiness Checklist

Run through this checklist before performing a `helm upgrade`. For the full step-by-step upgrade procedure, use the `/eg-migrate` skill.

### 1. Verify Kubernetes version compatibility

```bash
# Check your cluster version against the matrix above
kubectl version --short 2>/dev/null || kubectl version
```

Ensure your cluster version falls within the supported range for the target EG version.

### 2. Back up existing CRDs and custom resources

```bash
# Export all Gateway API resources
kubectl get gateways,httproutes,grpcroutes,tcproutes,udproutes,\
tlsroutes,referencegrants,backendtlspolicies -A -o yaml > gateway-api-backup.yaml

# Export all Envoy Gateway extension resources
kubectl get clienttrafficpolicies,backendtrafficpolicies,\
securitypolicies,envoyproxies,envoyextensionpolicies,\
envoypatchpolicies,backends,httproutefilters -A -o yaml > eg-extension-backup.yaml
```

### 3. Check for deprecated API versions in your manifests

```bash
# Look for alpha/beta versions that may have graduated
grep -rn 'apiVersion:.*v1alpha\|apiVersion:.*v1beta' \
  --include='*.yaml' --include='*.yml' .
```

Compare against the CRD API Versions section above to ensure your manifests use the correct apiVersion for the target EG release.

### 4. Review Helm values diff

```bash
# Compare your current values with the new chart defaults
helm show values oci://docker.io/envoyproxy/gateway-helm \
  --version TARGET_VERSION > new-defaults.yaml

helm get values eg -n envoy-gateway-system > current-values.yaml

diff current-values.yaml new-defaults.yaml
```

### 5. Check that all routes are healthy before upgrading

```bash
# All HTTPRoutes should have Accepted=True
kubectl get httproute -A -o json | \
  jq -r '.items[] | .metadata.namespace + "/" + .metadata.name + " Accepted=" + (.status.parents[0].conditions[] | select(.type=="Accepted") | .status)'

# All Gateways should be Programmed
kubectl get gateway -A -o json | \
  jq -r '.items[] | .metadata.namespace + "/" + .metadata.name + " Programmed=" + (.status.conditions[] | select(.type=="Programmed") | .status)'
```

### 6. Plan for brief control-plane downtime

During the upgrade, the Envoy Gateway controller pod restarts. Existing Envoy Proxy data-plane pods continue serving traffic, but configuration changes (new routes, policy updates) will not be reconciled until the controller is back.

- For zero-downtime upgrades in production, consider running the upgrade during a maintenance window.
- Monitor the controller pod rollout:

```bash
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system --timeout=5m
```

### 7. Post-upgrade verification

After the upgrade completes, verify the new version and check resource health:

```bash
# Confirm the new version
kubectl get deployment envoy-gateway -n envoy-gateway-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Re-check all routes and gateways are accepted
kubectl get gateway,httproute -A
```

---

For step-by-step upgrade procedures including rollback instructions, use the `/eg-migrate` skill.
