#!/usr/bin/env bash
set -euo pipefail

# extract-yaml.sh -- Extract Kubernetes YAML from SKILL.md files
#
# Parses markdown fenced code blocks tagged with ```yaml and extracts only
# blocks that contain "apiVersion:" (actual K8s resources, not Helm values
# or partial snippets). Template variables like ${Name} are substituted
# with safe test defaults.
#
# Usage:
#   ./tests/extract-yaml.sh path/to/SKILL.md [more/SKILL.md ...]
#   ./tests/extract-yaml.sh --outdir /tmp/my-output path/to/SKILL.md

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Defaults ---
OUTDIR="/tmp/envoy-skills-yaml"
FILES=()

# --- Argument parsing ---
usage() {
  echo "Usage: $0 [--outdir DIR] SKILL.md [SKILL.md ...]"
  echo ""
  echo "Extract Kubernetes YAML from SKILL.md files."
  echo ""
  echo "Options:"
  echo "  --outdir DIR   Output directory (default: /tmp/envoy-skills-yaml/)"
  echo "  --help         Show this help message"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo -e "${RED}Error: No SKILL.md files specified.${NC}"
  usage
fi

# --- Prepare output directory ---
rm -rf "${OUTDIR}"
mkdir -p "${OUTDIR}"

# --- Template substitution function ---
# Replaces ${Variable} placeholders with test defaults.
substitute_templates() {
  local content="$1"
  # Named substitutions -- order matters (longest match first where needed)
  content="${content//\$\{ServiceName\}/test-backend}"
  content="${content//\$\{ServicePort\}/80}"
  content="${content//\$\{Hostname\}/test.example.com}"
  content="${content//\$\{Version\}/v1.7.0}"
  content="${content//\$\{Namespace\}/test-ns}"
  content="${content//\$\{Name\}/test-resource}"
  content="${content//\$\{JwksUri\}/https://example.com/.well-known/jwks.json}"
  content="${content//\$\{Issuer\}/https://example.com}"
  content="${content//\$\{SecretName\}/test-tls-secret}"
  content="${content//\$\{AIGatewayVersion\}/v0.5.0}"
  content="${content//\$\{EnvoyGatewayVersion\}/v1.7.0}"
  content="${content//\$\{GatewayName\}/test-gateway}"
  content="${content//\$\{RouteName\}/test-route}"
  content="${content//\$\{ModelHeader\}/gpt-4o-mini}"
  content="${content//\$\{BackendNames\}/test-backend}"
  content="${content//\$\{BackendName\}/test-backend}"
  content="${content//\$\{Schema\}/OpenAI}"
  content="${content//\$\{Port\}/443}"
  content="${content//\$\{PolicyType\}/APIKey}"
  content="${content//\$\{AIServiceBackendName\}/test-backend}"

  # Catch-all: replace any remaining ${...} with test-value
  # Use sed for regex replacement
  echo "$content" | sed -E 's/\$\{[^}]+\}/test-value/g'
}

# --- Extraction ---
total_extracted=0
extracted_files=()

for filepath in "${FILES[@]}"; do
  if [[ ! -f "$filepath" ]]; then
    echo -e "${RED}Warning: File not found: ${filepath}${NC}" >&2
    continue
  fi

  # Derive skill name from parent directory
  skill_dir="$(basename "$(dirname "$filepath")")"
  skill_name="${skill_dir}"

  echo -e "${CYAN}Processing: ${filepath} (skill: ${skill_name})${NC}"

  # State machine to parse yaml code blocks
  in_yaml_block=false
  block_content=""
  block_index=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in_yaml_block" == false ]]; then
      # Look for opening ```yaml fence
      if [[ "$line" =~ ^\`\`\`yaml[[:space:]]*$ ]] || [[ "$line" =~ ^\`\`\`yaml$ ]]; then
        in_yaml_block=true
        block_content=""
      fi
    else
      # Look for closing ``` fence
      if [[ "$line" =~ ^\`\`\`[[:space:]]*$ ]] || [[ "$line" == '```' ]]; then
        in_yaml_block=false

        # Only extract blocks that contain apiVersion: (actual K8s resources)
        if echo "$block_content" | grep -q "apiVersion:"; then
          # Substitute template variables
          substituted="$(substitute_templates "$block_content")"

          outfile="${OUTDIR}/${skill_name}-${block_index}.yaml"
          echo "$substituted" > "$outfile"
          extracted_files+=("$outfile")
          block_index=$((block_index + 1))
          total_extracted=$((total_extracted + 1))
          echo -e "  ${GREEN}Extracted:${NC} $(basename "$outfile")"
        fi
      else
        # Accumulate content inside the yaml block
        if [[ -z "$block_content" ]]; then
          block_content="$line"
        else
          block_content="${block_content}
${line}"
        fi
      fi
    fi
  done < "$filepath"

  # Warn if we ended inside an unclosed block
  if [[ "$in_yaml_block" == true ]]; then
    echo -e "${YELLOW}Warning: Unclosed yaml block in ${filepath}${NC}" >&2
  fi
done

# --- Summary ---
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Extraction Summary${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "Output directory: ${OUTDIR}"
echo -e "Files processed:  ${#FILES[@]}"
echo -e "YAML extracted:   ${total_extracted}"
echo ""

if [[ ${total_extracted} -gt 0 ]]; then
  echo -e "${GREEN}Extracted files:${NC}"
  for f in "${extracted_files[@]}"; do
    echo "  $(basename "$f")"
  done
else
  echo -e "${YELLOW}No Kubernetes YAML blocks found.${NC}"
fi
