#!/usr/bin/env bash
set -euo pipefail

# Install Envoy Skills into a project's .claude/ directory
#
# Usage:
#   ./install.sh <skill-set-path> [target-project-path]
#
# Examples:
#   ./install.sh gateway/adopters                    # Install into current directory
#   ./install.sh gateway/adopters /path/to/my-project  # Install into specific project
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
  echo "  gateway/adopters     Envoy Gateway skills for adopters"
  echo "  ai-gateway/adopters  Envoy AI Gateway skills for adopters"
  echo ""
  echo "Planned:"
  echo "  gateway/contributors Envoy Gateway skills for contributors"
  echo "  proxy/adopters       Envoy Proxy skills"
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
if [[ "${SKILL_SET}" == "ai-gateway/adopters" ]]; then
  echo "Quick start:"
  echo "  /eai-orchestrator  — guided setup (start here)"
  echo "  /eai-install       — install Envoy AI Gateway"
  echo "  /eai-fundamentals  — learn the resource model"
else
  echo "Quick start:"
  echo "  /eg-orchestrator  — guided setup (start here)"
  echo "  /eg-install       — install Envoy Gateway"
  echo "  /eg-fundamentals  — learn the resource model"
fi
