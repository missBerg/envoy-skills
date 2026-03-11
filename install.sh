#!/usr/bin/env bash
set -euo pipefail

# Install Envoy Skills into a project's .claude/ directory
#
# Usage:
#   ./install.sh <skill-set-path> [target-project-path]
#
# Examples:
#   ./install.sh gateway/adopters                    # Envoy Gateway adopters
#   ./install.sh ai-gateway/adopters                 # Envoy AI Gateway adopters
#   ./install.sh gateway/contributors                # Envoy Gateway contributors
#   ./install.sh ai-gateway/contributors              # Envoy AI Gateway contributors
#   ./install.sh shared/contributors                 # Shared controller skills
#   ./install.sh gateway/adopters /path/to/project   # Install into specific project
#
# For cross-agent installation, use: npx skills add missBerg/envoy-skills

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKILL_SET="${1:?Usage: ./install.sh <skill-set-path> [target-project-path]}"
TARGET="${2:-.}"

SKILL_SET_PATH="${SCRIPT_DIR}/${SKILL_SET}"

if [[ ! -d "${SKILL_SET_PATH}" ]]; then
  echo "Error: Skill set not found at ${SKILL_SET_PATH}"
  echo ""
  echo "Available skill sets:"
  echo "  gateway/adopters      Envoy Gateway skills for adopters"
  echo "  gateway/contributors  Envoy Gateway skills for contributors"
  echo "  ai-gateway/adopters   Envoy AI Gateway skills for adopters"
  echo "  ai-gateway/contributors  Envoy AI Gateway skills for contributors"
  echo "  shared/contributors   Shared Kubernetes controller skills for contributors"
  echo ""
  echo "Planned:"
  echo "  proxy/adopters        Envoy Proxy skills"
  exit 1
fi

if [[ ! -d "${SKILL_SET_PATH}/skills" ]]; then
  echo "Error: No skills directory found at ${SKILL_SET_PATH}/skills"
  exit 1
fi

# Create .claude/skills if it doesn't exist
mkdir -p "${TARGET}/.claude/skills"

# Track what we install
INSTALLED=0

for skill_dir in "${SKILL_SET_PATH}/skills"/*/; do
  if [[ -d "${skill_dir}" ]]; then
    skill_name="$(basename "${skill_dir}")"
    cp -r "${skill_dir}" "${TARGET}/.claude/skills/${skill_name}"
    echo "  Installed: /${skill_name}"
    INSTALLED=$((INSTALLED + 1))
  fi
done

echo ""
echo "Installed ${INSTALLED} skills from ${SKILL_SET} into ${TARGET}/.claude/skills/"
echo ""
case "${SKILL_SET}" in
  ai-gateway/adopters)
    echo "Quick start:"
    echo "  /aigw-orchestrator  — guided setup (start here)"
    echo "  /aigw-install       — install Envoy AI Gateway"
    echo "  /aigw-fundamentals  — learn the resource model"
    ;;
  gateway/contributors)
    echo "Quick start:"
    echo "  /eg-contrib-orchestrator  — guided setup (start here)"
    echo "  /eg-contrib-add-api       — add new API support"
    echo "  /eg-contrib-architecture   — codebase structure"
    ;;
  ai-gateway/contributors)
    echo "Quick start:"
    echo "  /aigw-contrib-orchestrator  — guided setup (start here)"
    echo "  /aigw-contrib-add-translator — add new LLM provider"
    echo "  /aigw-contrib-architecture   — codebase structure"
    ;;
  shared/contributors)
    echo "Quick start:"
    echo "  /k8s-controller-reconcile  — reconcile loops, finalizers"
    echo "  /k8s-controller-testing    — unit testing patterns"
    echo "  /k8s-controller-perf       — performance tuning"
    ;;
  *)
    echo "Quick start:"
    echo "  /eg-orchestrator  — guided setup (start here)"
    echo "  /eg-install       — install Envoy Gateway"
    echo "  /eg-fundamentals  — learn the resource model"
    ;;
esac
