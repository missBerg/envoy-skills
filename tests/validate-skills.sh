#!/usr/bin/env bash
set -euo pipefail

# validate-skills.sh -- Validate all SKILL.md files in the repository
#
# Checks:
#   - YAML frontmatter is present and well-formed
#   - Frontmatter contains required "name:" and "description:" fields
#   - The name field matches the parent directory name
#   - File is under 500 lines
#   - All ```yaml blocks have matching closing ```
#   - No hardcoded version strings that differ from latest_stable in versions.yaml
#
# Usage:
#   ./tests/validate-skills.sh

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Find repo root ---
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIRS=(
  "${REPO_ROOT}/gateway/adopters/skills"
  "${REPO_ROOT}/gateway/contributors/skills"
  "${REPO_ROOT}/ai-gateway/adopters/skills"
)

# --- Read latest_stable from versions.yaml ---
VERSIONS_FILE="${REPO_ROOT}/versions.yaml"
LATEST_STABLE=""

if [[ -f "$VERSIONS_FILE" ]]; then
  # Extract latest_stable value (handles quoted and unquoted)
  LATEST_STABLE="$(grep 'latest_stable:' "$VERSIONS_FILE" | head -1 | sed -E 's/.*latest_stable:[[:space:]]*"?([^"]*)"?.*/\1/' | tr -d '[:space:]')"
  echo -e "${CYAN}Loaded versions.yaml: latest_stable=${LATEST_STABLE}${NC}"
else
  echo -e "${YELLOW}Warning: versions.yaml not found at ${VERSIONS_FILE}. Skipping version checks.${NC}"
fi

echo ""

# --- Counters ---
total=0
passed=0
failed=0
warnings=0

# --- Find all SKILL.md files ---
skill_files=()
for skills_dir in "${SKILLS_DIRS[@]}"; do
  if [[ ! -d "$skills_dir" ]]; then
    echo -e "${YELLOW}Warning: Skills directory not found: ${skills_dir} (skipping)${NC}"
    continue
  fi
  while IFS= read -r -d '' f; do
    skill_files+=("$f")
  done < <(find "$skills_dir" -name "SKILL.md" -type f -print0 | sort -z)
done

if [[ ${#skill_files[@]} -eq 0 ]]; then
  echo -e "${RED}Error: No SKILL.md files found under any skills directory${NC}"
  exit 1
fi

echo -e "${BOLD}Found ${#skill_files[@]} SKILL.md files to validate${NC}"
echo ""

# --- Validate each file ---
for filepath in "${skill_files[@]}"; do
  total=$((total + 1))
  skill_dir="$(basename "$(dirname "$filepath")")"
  relative_path="${filepath#"${REPO_ROOT}/"}"
  errors=()
  warns=()

  echo -e "${CYAN}Checking: ${relative_path}${NC}"

  # --- Check 1: YAML frontmatter exists ---
  first_line="$(head -1 "$filepath")"
  if [[ "$first_line" != "---" ]]; then
    errors+=("Missing YAML frontmatter (file must start with ---)")
  else
    # Find the closing --- (skip the first line)
    closing_line=""
    line_num=0
    found_closing=false
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      if [[ $line_num -gt 1 ]] && [[ "$line" == "---" ]]; then
        closing_line=$line_num
        found_closing=true
        break
      fi
    done < "$filepath"

    if [[ "$found_closing" != true ]]; then
      errors+=("YAML frontmatter not closed (missing closing ---)")
    else
      # Extract frontmatter content (between the two --- lines)
      frontmatter="$(sed -n "2,$((closing_line - 1))p" "$filepath")"

      # --- Check 2: name field exists ---
      if ! echo "$frontmatter" | grep -qE '^name:'; then
        errors+=("Frontmatter missing required 'name:' field")
      else
        # --- Check 4: name matches directory ---
        fm_name="$(echo "$frontmatter" | grep -E '^name:' | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '[:space:]')"
        if [[ "$fm_name" != "$skill_dir" ]]; then
          errors+=("Frontmatter name '${fm_name}' does not match directory '${skill_dir}'")
        fi
      fi

      # --- Check 3: description field exists ---
      if ! echo "$frontmatter" | grep -qE '^description:'; then
        errors+=("Frontmatter missing required 'description:' field")
      fi
    fi
  fi

  # --- Check 5: File under 500 lines ---
  line_count="$(wc -l < "$filepath" | tr -d '[:space:]')"
  if [[ "$line_count" -gt 500 ]]; then
    errors+=("File is ${line_count} lines (max 500)")
  fi

  # --- Check 6: Matched yaml code fences ---
  open_count="$(grep -cE '^\`\`\`yaml' "$filepath" || true)"
  # Count closing fences: lines that are exactly ``` (possibly with trailing whitespace)
  # We need to count all closing fences, not just yaml ones.
  # Strategy: count opens (```yaml) and total closes (```), then check opens <= closes
  # But closes also close non-yaml blocks. Instead, do a state-machine check.
  in_block=false
  unclosed=0
  block_line=0
  current_line=0
  while IFS= read -r line; do
    current_line=$((current_line + 1))
    if [[ "$in_block" == false ]]; then
      if [[ "$line" =~ ^\`\`\`yaml ]]; then
        in_block=true
        block_line=$current_line
      fi
    else
      if [[ "$line" =~ ^\`\`\`[[:space:]]*$ ]] || [[ "$line" == '```' ]]; then
        in_block=false
      fi
    fi
  done < "$filepath"
  if [[ "$in_block" == true ]]; then
    errors+=("Unclosed \`\`\`yaml block starting at line ${block_line}")
  fi

  # --- Check 7: No hardcoded EG version mismatch ---
  if [[ -n "$LATEST_STABLE" ]]; then
    # Only flag version references that are clearly Envoy Gateway (gateway-helm chart)
    # Skip eg-migrate which intentionally references multiple versions
    if [[ "$skill_dir" != "eg-migrate" ]]; then
      while IFS= read -r match_line; do
        matched_version="$(echo "$match_line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [[ -n "$matched_version" ]] && [[ "$matched_version" != "$LATEST_STABLE" ]]; then
          warns+=("Found EG version ${matched_version} (latest_stable is ${LATEST_STABLE}): $(echo "$match_line" | sed 's/^[[:space:]]*//')")
        fi
      done < <(grep -nE 'gateway-helm.*\-\-version v[0-9]|default:.*v[0-9]+\.[0-9]+\.[0-9]+' "$filepath" 2>/dev/null || true)
    fi
  fi

  # --- Check 8: AI Gateway skills - version check uses envoy_ai_gateway latest_stable ---
  if [[ "$relative_path" == ai-gateway/* ]]; then
    AIGW_LATEST=""
    if [[ -f "$VERSIONS_FILE" ]]; then
      AIGW_LATEST="$(grep -A 1 'envoy_ai_gateway:' "$VERSIONS_FILE" | grep 'latest_stable:' | head -1 | sed -E 's/.*latest_stable:[[:space:]]*"?([^"]*)"?.*/\1/' | tr -d '[:space:]')"
    fi
    if [[ -n "$AIGW_LATEST" ]]; then
      while IFS= read -r match_line; do
        matched_version="$(echo "$match_line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [[ -n "$matched_version" ]] && [[ "$matched_version" != "$AIGW_LATEST" ]]; then
          warns+=("Found AI Gateway version ${matched_version} (latest_stable is ${AIGW_LATEST}): $(echo "$match_line" | sed 's/^[[:space:]]*//')")
        fi
      done < <(grep -nE 'ai-gateway-helm.*\-\-version v[0-9]|ai-gateway-crds-helm.*\-\-version v[0-9]|v0\.[0-9]+\.[0-9]+' "$filepath" 2>/dev/null || true)
    fi
  fi

  # --- Report results ---
  if [[ ${#errors[@]} -gt 0 ]]; then
    failed=$((failed + 1))
    echo -e "  ${RED}FAIL${NC}"
    for err in "${errors[@]}"; do
      echo -e "    ${RED}x ${err}${NC}"
    done
  else
    passed=$((passed + 1))
    echo -e "  ${GREEN}PASS${NC}"
  fi

  if [[ ${#warns[@]} -gt 0 ]]; then
    warnings=$((warnings + ${#warns[@]}))
    for w in "${warns[@]}"; do
      echo -e "    ${YELLOW}! ${w}${NC}"
    done
  fi
done

# --- Summary ---
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}Validation Summary${NC}"
echo -e "${BOLD}========================================${NC}"
echo -e "Total skills: ${total}"
echo -e "${GREEN}Passed:       ${passed}${NC}"
echo -e "${RED}Failed:       ${failed}${NC}"
echo -e "${YELLOW}Warnings:     ${warnings}${NC}"
echo ""

if [[ $failed -gt 0 ]]; then
  echo -e "${RED}Validation FAILED${NC}"
  exit 1
else
  echo -e "${GREEN}All skills passed validation${NC}"
  exit 0
fi
