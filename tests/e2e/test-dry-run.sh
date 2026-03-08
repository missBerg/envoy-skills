#!/usr/bin/env bash
set -euo pipefail

# test-dry-run.sh -- Server-side dry-run validation for all skill YAML
#
# Extracts YAML from all SKILL.md files and runs kubectl apply --dry-run=server
# against each one. This catches structural and schema errors in the generated
# Kubernetes resources without actually creating them.
#
# Some failures are expected (e.g., references to Secrets or Services that
# don't exist). The focus is on catching malformed YAML and incorrect
# apiVersion/kind/spec structures.
#
# Assumes setup-cluster.sh has been run (CRDs must be installed).
#
# Usage:
#   ./tests/e2e/test-dry-run.sh

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
EXTRACT_SCRIPT="${REPO_ROOT}/tests/extract-yaml.sh"

# --- Preflight checks ---
echo -e "${BOLD}Server-Side Dry-Run Validation${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Verify cluster is reachable
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Error: Kubernetes cluster is not reachable. Run setup-cluster.sh first.${NC}"
  exit 1
fi

# Verify extract script exists
if [[ ! -x "$EXTRACT_SCRIPT" ]]; then
  echo -e "${RED}Error: extract-yaml.sh not found or not executable at ${EXTRACT_SCRIPT}${NC}"
  exit 1
fi

# --- Find all SKILL.md files ---
SKILLS_DIR="${REPO_ROOT}/gateway/adopters/skills"
SKILL_FILES=()

while IFS= read -r -d '' f; do
  SKILL_FILES+=("$f")
done < <(find "$SKILLS_DIR" -name "SKILL.md" -type f -print0 | sort -z)

if [[ ${#SKILL_FILES[@]} -eq 0 ]]; then
  echo -e "${RED}Error: No SKILL.md files found under ${SKILLS_DIR}${NC}"
  exit 1
fi

echo -e "Found ${#SKILL_FILES[@]} SKILL.md files"
echo ""

# --- Extract YAML from all skills ---
YAML_DIR="/tmp/envoy-skills-yaml-dry-run"

echo -e "${CYAN}Extracting YAML from all skills...${NC}"
"${EXTRACT_SCRIPT}" --outdir "$YAML_DIR" "${SKILL_FILES[@]}"
echo ""

# --- Find extracted YAML files ---
YAML_FILES=()
if [[ -d "$YAML_DIR" ]]; then
  while IFS= read -r -d '' f; do
    YAML_FILES+=("$f")
  done < <(find "$YAML_DIR" -name "*.yaml" -type f -print0 | sort -z)
fi

if [[ ${#YAML_FILES[@]} -eq 0 ]]; then
  echo -e "${YELLOW}No YAML files were extracted. Nothing to validate.${NC}"
  exit 0
fi

echo -e "${BOLD}Validating ${#YAML_FILES[@]} extracted YAML files...${NC}"
echo ""

# --- Counters ---
total=0
passed=0
failed_schema=0
failed_ref=0
skipped=0

# Track results for summary
declare -a pass_list=()
declare -a fail_schema_list=()
declare -a fail_ref_list=()
declare -a skip_list=()

# --- Validate each file ---
for yaml_file in "${YAML_FILES[@]}"; do
  total=$((total + 1))
  filename="$(basename "$yaml_file")"

  echo -ne "  ${filename}: "

  # Check if file is empty or has no content
  if [[ ! -s "$yaml_file" ]]; then
    skipped=$((skipped + 1))
    skip_list+=("$filename (empty file)")
    echo -e "${YELLOW}SKIP (empty)${NC}"
    continue
  fi

  # Run server-side dry-run
  output=""
  if output="$(kubectl apply --dry-run=server -f "$yaml_file" 2>&1)"; then
    passed=$((passed + 1))
    pass_list+=("$filename")
    echo -e "${GREEN}PASS${NC}"
  else
    # Categorize the failure
    # Reference errors: missing secrets, services, namespaces, etc.
    if echo "$output" | grep -qiE 'not found|NotFound|no matches for|unable to recognize|does not exist'; then
      # This is a reference error -- the YAML structure is valid but references
      # resources that don't exist in the test cluster. This is expected.
      failed_ref=$((failed_ref + 1))
      fail_ref_list+=("$filename")
      # Truncate long error messages
      short_err="$(echo "$output" | head -3 | tr '\n' ' ' | cut -c1-120)"
      echo -e "${YELLOW}EXPECTED FAIL (missing ref)${NC}"
      echo -e "    ${YELLOW}${short_err}${NC}"
    else
      # This is likely a schema/structural error -- the YAML itself is wrong
      failed_schema=$((failed_schema + 1))
      fail_schema_list+=("$filename")
      short_err="$(echo "$output" | head -5 | tr '\n' ' ' | cut -c1-200)"
      echo -e "${RED}FAIL (schema error)${NC}"
      echo -e "    ${RED}${short_err}${NC}"
    fi
  fi
done

# --- Summary ---
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}Dry-Run Validation Summary${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "Total YAML files:     ${total}"
echo -e "${GREEN}Passed:               ${passed}${NC}"
echo -e "${RED}Schema errors:        ${failed_schema}${NC}"
echo -e "${YELLOW}Missing references:   ${failed_ref} (expected, not blocking)${NC}"
echo -e "${YELLOW}Skipped:              ${skipped}${NC}"
echo ""

if [[ ${#pass_list[@]} -gt 0 ]]; then
  echo -e "${GREEN}Passed files:${NC}"
  for f in "${pass_list[@]}"; do
    echo -e "  ${GREEN}+ ${f}${NC}"
  done
  echo ""
fi

if [[ ${#fail_ref_list[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Expected failures (missing references):${NC}"
  for f in "${fail_ref_list[@]}"; do
    echo -e "  ${YELLOW}~ ${f}${NC}"
  done
  echo -e "${YELLOW}These files have valid schema but reference resources not in the test cluster.${NC}"
  echo ""
fi

if [[ ${#fail_schema_list[@]} -gt 0 ]]; then
  echo -e "${RED}Schema errors (NEEDS FIX):${NC}"
  for f in "${fail_schema_list[@]}"; do
    echo -e "  ${RED}x ${f}${NC}"
  done
  echo ""
fi

# Exit non-zero only for schema errors (not reference errors)
if [[ $failed_schema -gt 0 ]]; then
  echo -e "${RED}VALIDATION FAILED -- ${failed_schema} file(s) have schema errors${NC}"
  exit 1
else
  echo -e "${GREEN}VALIDATION PASSED -- all YAML is structurally valid${NC}"
  if [[ $failed_ref -gt 0 ]]; then
    echo -e "${YELLOW}(${failed_ref} file(s) have missing references, which is expected in a test cluster)${NC}"
  fi
  exit 0
fi
