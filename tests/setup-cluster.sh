#!/usr/bin/env bash
set -euo pipefail

# setup-cluster.sh -- Create a kind cluster with Envoy Gateway installed
#
# Sets up a local Kubernetes cluster for testing SKILL.md-generated YAML.
# Installs Envoy Gateway via Helm, deploys a test backend, and creates
# a basic Gateway + HTTPRoute.
#
# Usage:
#   ./tests/setup-cluster.sh                          # Create cluster with defaults
#   ./tests/setup-cluster.sh --eg-version v1.6.2      # Specific EG version
#   ./tests/setup-cluster.sh --cluster-name my-test   # Custom cluster name
#   ./tests/setup-cluster.sh --cleanup                 # Delete the cluster

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Find repo root ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Defaults ---
CLUSTER_NAME="envoy-skills-test"
EG_VERSION=""
CLEANUP=false
EG_NAMESPACE="envoy-gateway-system"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

# --- Read default version from versions.yaml ---
VERSIONS_FILE="${REPO_ROOT}/versions.yaml"
if [[ -z "$EG_VERSION" ]] && [[ -f "$VERSIONS_FILE" ]]; then
  EG_VERSION="$(grep 'latest_stable:' "$VERSIONS_FILE" | head -1 | sed -E 's/.*latest_stable:[[:space:]]*"?([^"]*)"?.*/\1/' | tr -d '[:space:]')"
fi
EG_VERSION="${EG_VERSION:-v1.7.0}"

# --- Argument parsing ---
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Set up a kind cluster with Envoy Gateway for testing."
  echo ""
  echo "Options:"
  echo "  --eg-version VERSION    Envoy Gateway version (default: ${EG_VERSION})"
  echo "  --cluster-name NAME     Kind cluster name (default: ${CLUSTER_NAME})"
  echo "  --cleanup               Delete the cluster and exit"
  echo "  --help                  Show this help message"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --eg-version)
      EG_VERSION="$2"
      shift 2
      ;;
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --cleanup)
      CLEANUP=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      usage
      ;;
  esac
done

# --- Cleanup mode ---
if [[ "$CLEANUP" == true ]]; then
  echo -e "${CYAN}Deleting kind cluster: ${CLUSTER_NAME}${NC}"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo -e "${GREEN}Cluster deleted.${NC}"
  else
    echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' does not exist.${NC}"
  fi
  exit 0
fi

# --- Check prerequisites ---
echo -e "${BOLD}Checking prerequisites...${NC}"

missing=()
for cmd in kind kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo -e "${RED}Error: Missing required tools: ${missing[*]}${NC}"
  echo ""
  echo "Install them:"
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      kind)    echo "  brew install kind       # or: go install sigs.k8s.io/kind@latest" ;;
      kubectl) echo "  brew install kubectl" ;;
      helm)    echo "  brew install helm" ;;
    esac
  done
  exit 1
fi

echo -e "${GREEN}All prerequisites found.${NC}"
echo ""

# --- Cluster setup ---
echo -e "${BOLD}Configuration:${NC}"
echo -e "  Cluster name:      ${CLUSTER_NAME}"
echo -e "  Envoy Gateway:     ${EG_VERSION}"
echo -e "  Kind config:       ${KIND_CONFIG}"
echo ""

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' already exists. Using existing cluster.${NC}"
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null || {
    echo -e "${RED}Error: Cluster exists but is not reachable. Run: $0 --cleanup${NC}"
    exit 1
  }
else
  echo -e "${CYAN}Creating kind cluster...${NC}"
  if [[ -f "$KIND_CONFIG" ]]; then
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
  else
    echo -e "${YELLOW}Warning: Kind config not found at ${KIND_CONFIG}. Using defaults.${NC}"
    kind create cluster --name "${CLUSTER_NAME}"
  fi
  echo -e "${GREEN}Cluster created.${NC}"
fi

echo ""

# --- Set kubectl context ---
kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null

# --- Install Envoy Gateway ---
echo -e "${CYAN}Installing Envoy Gateway ${EG_VERSION}...${NC}"

# Check if already installed
if kubectl get deployment -n "${EG_NAMESPACE}" envoy-gateway &>/dev/null 2>&1; then
  echo -e "${YELLOW}Envoy Gateway already installed. Skipping Helm install.${NC}"
else
  helm install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "${EG_VERSION}" \
    -n "${EG_NAMESPACE}" \
    --create-namespace \
    --wait \
    --timeout 5m
  echo -e "${GREEN}Envoy Gateway installed.${NC}"
fi

echo ""

# --- Wait for controller ---
echo -e "${CYAN}Waiting for Envoy Gateway controller to be available...${NC}"
if kubectl wait --timeout=300s -n "${EG_NAMESPACE}" \
  deployment/envoy-gateway --for=condition=Available; then
  echo -e "${GREEN}Controller is ready.${NC}"
else
  echo -e "${RED}Error: Envoy Gateway controller did not become available within timeout.${NC}"
  exit 1
fi

echo ""

# --- Apply GatewayClass ---
echo -e "${CYAN}Applying default GatewayClass...${NC}"
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
echo -e "${GREEN}GatewayClass applied.${NC}"

echo ""

# --- Deploy test backend ---
echo -e "${CYAN}Deploying test backend (nginx)...${NC}"
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-backend
  namespace: default
  labels:
    app: test-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-backend
  template:
    metadata:
      labels:
        app: test-backend
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: test-backend
  namespace: default
spec:
  selector:
    app: test-backend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF

echo -e "${CYAN}Waiting for test backend to be ready...${NC}"
kubectl wait --timeout=120s -n default \
  deployment/test-backend --for=condition=Available
echo -e "${GREEN}Test backend deployed.${NC}"

echo ""

# --- Create basic Gateway ---
echo -e "${CYAN}Creating basic Gateway...${NC}"
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: test-gateway
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
EOF

echo ""

# --- Create basic HTTPRoute ---
echo -e "${CYAN}Creating basic HTTPRoute...${NC}"
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: test-route
  namespace: default
spec:
  parentRefs:
    - name: test-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: test-backend
          port: 80
EOF

echo ""

# --- Wait for Gateway to be programmed ---
echo -e "${CYAN}Waiting for Gateway to be programmed...${NC}"
TIMEOUT=120
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  STATUS="$(kubectl get gateway test-gateway -n default -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")"
  if [[ "$STATUS" == "True" ]]; then
    echo -e "${GREEN}Gateway is programmed.${NC}"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo -e "  Waiting... (${ELAPSED}s/${TIMEOUT}s)"
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo -e "${YELLOW}Warning: Gateway did not reach Programmed status within ${TIMEOUT}s.${NC}"
  echo -e "${YELLOW}It may still be initializing. Check: kubectl get gateway test-gateway -n default${NC}"
fi

echo ""

# --- Print connection info ---
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}Cluster Ready${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "Cluster name:  ${CLUSTER_NAME}"
echo -e "EG version:    ${EG_VERSION}"
echo -e "Gateway:       test-gateway (default namespace)"
echo -e "Backend:       test-backend (nginx, default namespace)"
echo -e "HTTPRoute:     test-route (default namespace)"
echo ""
echo -e "${CYAN}To port-forward to the Envoy proxy:${NC}"
echo ""

# Get the envoy service name
ENVOY_SVC="$(kubectl get svc -n "${EG_NAMESPACE}" -l gateway.envoyproxy.io/owning-gateway-name=test-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "envoy-default-test-gateway-<hash>")"

echo "  kubectl port-forward -n ${EG_NAMESPACE} svc/${ENVOY_SVC} 8888:80"
echo ""
echo -e "${CYAN}Then test with:${NC}"
echo ""
echo "  curl -H 'Host: test.example.com' http://localhost:8888/"
echo ""
echo -e "${CYAN}To clean up:${NC}"
echo ""
echo "  $0 --cleanup"
echo ""
