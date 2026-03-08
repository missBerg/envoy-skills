#!/usr/bin/env bash
set -euo pipefail

# test-policies.sh -- E2E test for Envoy Gateway policy CRDs
#
# Validates that policy resources from eg-backend-policy, eg-client-policy,
# and eg-auth skills can be applied to the cluster. Uses server-side dry-run
# for policies that require external dependencies (e.g., JWT JWKS endpoints).
#
# Assumes setup-cluster.sh has already been run.
#
# Usage:
#   ./tests/e2e/test-policies.sh

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Find repo root ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Test framework ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
  local name="$1"
  local func="$2"
  TESTS_RUN=$((TESTS_RUN + 1))

  echo -e "${CYAN}TEST: ${name}${NC}"

  if eval "$func"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}"
  fi
  echo ""
}

# --- Preflight checks ---
echo -e "${BOLD}Policy CRD E2E Tests${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Verify cluster is reachable
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Error: Kubernetes cluster is not reachable. Run setup-cluster.sh first.${NC}"
  exit 1
fi

# Verify CRDs are installed
for crd in backendtrafficpolicies.gateway.envoyproxy.io clienttrafficpolicies.gateway.envoyproxy.io securitypolicies.gateway.envoyproxy.io; do
  if ! kubectl get crd "$crd" &>/dev/null; then
    echo -e "${RED}Error: CRD ${crd} not found. Is Envoy Gateway installed?${NC}"
    exit 1
  fi
done
echo -e "${GREEN}All required CRDs are present.${NC}"
echo ""

# --- Test 1: BackendTrafficPolicy with retry config ---
test_backend_traffic_policy() {
  local policy_name="e2e-btp-retry"

  echo -e "  Applying BackendTrafficPolicy with retry configuration..."

  # Apply the policy targeting test-gateway's route
  if kubectl apply -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: ${policy_name}
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: test-route
  retry:
    numRetries: 3
    retryOn:
      httpStatusCodes:
        - 502
        - 503
        - 504
    perRetry:
      backOff:
        baseInterval: 100ms
        maxInterval: 1s
      timeout: 5s
EOF
  then
    echo -e "  BackendTrafficPolicy applied successfully"

    # Wait for the policy to be accepted
    local status=""
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
      status="$(kubectl get backendtrafficpolicy "${policy_name}" -n default \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")"
      if [[ "$status" == "True" ]]; then
        break
      fi
      sleep 2
      elapsed=$((elapsed + 2))
    done

    if [[ "$status" == "True" ]]; then
      echo -e "  Policy is Accepted by controller"
    else
      echo -e "  ${YELLOW}Policy applied but Accepted status is '${status:-unknown}' after ${elapsed}s${NC}"
    fi

    # Clean up
    kubectl delete backendtrafficpolicy "${policy_name}" -n default --ignore-not-found &>/dev/null || true
    return 0
  else
    echo -e "  ${RED}Failed to apply BackendTrafficPolicy${NC}"
    return 1
  fi
}

# --- Test 2: ClientTrafficPolicy with timeout ---
test_client_traffic_policy() {
  local policy_name="e2e-ctp-timeout"

  echo -e "  Applying ClientTrafficPolicy with timeout configuration..."

  if kubectl apply -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: ${policy_name}
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: test-gateway
  timeout:
    http:
      requestReceivedTimeout: 30s
      idleTimeout: 120s
EOF
  then
    echo -e "  ClientTrafficPolicy applied successfully"

    # Wait for the policy to be accepted
    local status=""
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
      status="$(kubectl get clienttrafficpolicy "${policy_name}" -n default \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")"
      if [[ "$status" == "True" ]]; then
        break
      fi
      sleep 2
      elapsed=$((elapsed + 2))
    done

    if [[ "$status" == "True" ]]; then
      echo -e "  Policy is Accepted by controller"
    else
      echo -e "  ${YELLOW}Policy applied but Accepted status is '${status:-unknown}' after ${elapsed}s${NC}"
    fi

    # Clean up
    kubectl delete clienttrafficpolicy "${policy_name}" -n default --ignore-not-found &>/dev/null || true
    return 0
  else
    echo -e "  ${RED}Failed to apply ClientTrafficPolicy${NC}"
    return 1
  fi
}

# --- Test 3: SecurityPolicy with JWT auth (dry-run) ---
test_security_policy_jwt_dry_run() {
  local policy_name="e2e-sp-jwt"

  echo -e "  Applying SecurityPolicy with JWT auth (server-side dry-run)..."
  echo -e "  ${YELLOW}Note: Using dry-run because JWT validation requires reachable JWKS endpoint${NC}"

  if kubectl apply --dry-run=server -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ${policy_name}
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: test-gateway
  jwt:
    providers:
      - name: example-provider
        issuer: "https://example.com"
        remoteJWKS:
          uri: "https://example.com/.well-known/jwks.json"
        claimToHeaders:
          - claim: sub
            header: x-jwt-sub
EOF
  then
    echo -e "  SecurityPolicy passed server-side dry-run validation"
    return 0
  else
    echo -e "  ${RED}SecurityPolicy failed server-side dry-run validation${NC}"
    return 1
  fi
}

# --- Run tests ---
run_test "BackendTrafficPolicy with retry config" test_backend_traffic_policy
run_test "ClientTrafficPolicy with timeout config" test_client_traffic_policy
run_test "SecurityPolicy with JWT auth (dry-run)" test_security_policy_jwt_dry_run

# --- Summary ---
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}Policy E2E Test Summary${NC}"
echo -e "${BOLD}========================================${NC}"
echo -e "Tests run:    ${TESTS_RUN}"
echo -e "${GREEN}Passed:       ${TESTS_PASSED}${NC}"
echo -e "${RED}Failed:       ${TESTS_FAILED}${NC}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
fi
