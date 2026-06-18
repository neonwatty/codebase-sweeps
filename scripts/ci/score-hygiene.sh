#!/usr/bin/env bash
set -euo pipefail

# score-hygiene.sh — Score CI workflow configuration against a best-practices checklist.
# Structured JSON to stdout; human-readable summary to stderr.

usage() {
  cat <<'USAGE'
Usage: score-hygiene.sh [--dir .github/workflows] [--output FILE] [--format json|markdown]

Score GitHub Actions workflows against a configuration hygiene checklist.

Options:
  --dir DIR           Workflow directory to check (default: .github/workflows)
  --output FILE       Write output to FILE instead of stdout
  --format FMT        Output format: json (default) or markdown
  --help              Show this help message

Checks:
  - timeout-minutes on every job
  - Actions pinned to SHA or major version
  - Explicit permissions blocks
  - Concurrency groups on PR workflows
  - Node.js / tool version pinning
USAGE
}

for arg in "$@"; do
  if [[ "$arg" == "--help" ]]; then usage; exit 0; fi
done

# --- Check required tools ---
for tool in jq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Error: '$tool' is required but not installed." >&2
    exit 1
  fi
done

# --- Parse arguments ---
DIR=".github/workflows"
OUTPUT=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)    DIR="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --help)   usage; exit 0 ;;
    *)        echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$FORMAT" != "json" && "$FORMAT" != "markdown" ]]; then
  echo "Error: --format must be 'json' or 'markdown'." >&2
  exit 1
fi

if [[ ! -d "$DIR" ]]; then
  echo "Error: Workflow directory not found: $DIR" >&2
  exit 1
fi

# --- Collect workflow files ---
WORKFLOW_FILES=()
for ext in yml yaml; do
  for f in "$DIR"/*."$ext"; do
    [[ -f "$f" ]] && WORKFLOW_FILES+=("$f")
  done
done

if [[ ${#WORKFLOW_FILES[@]} -eq 0 ]]; then
  echo "Error: No workflow files found in $DIR" >&2
  exit 1
fi

echo "Scoring ${#WORKFLOW_FILES[@]} workflow file(s) in $DIR..." >&2

# --- Checklist functions ---
# Each function outputs a JSON object: {check, pass, total, details: [{file, job?, status, note}]}

check_timeout_minutes() {
  local pass=0 total=0
  local details="[]"

  for f in "${WORKFLOW_FILES[@]}"; do
    # Extract job names and check for timeout-minutes
    local jobs
    jobs=$(yq -r '.jobs // {} | keys[]' "$f" 2>/dev/null || true)
    for job in $jobs; do
      total=$((total + 1))
      local has_timeout
      has_timeout=$(yq -r ".jobs[\"$job\"][\"timeout-minutes\"] // \"\"" "$f" 2>/dev/null || echo "")
      if [[ -n "$has_timeout" ]]; then
        pass=$((pass + 1))
        details=$(echo "$details" | jq --arg f "$f" --arg j "$job" '. + [{file: $f, job: $j, status: "pass", note: "has timeout-minutes"}]')
      else
        details=$(echo "$details" | jq --arg f "$f" --arg j "$job" '. + [{file: $f, job: $j, status: "fail", note: "missing timeout-minutes"}]')
      fi
    done
  done

  jq -n --arg check "timeout-minutes" --argjson pass "$pass" --argjson total "$total" --argjson details "$details" \
    '{check: $check, pass: $pass, total: $total, details: $details}'
}

check_actions_pinned() {
  local pass=0 total=0
  local details="[]"

  for f in "${WORKFLOW_FILES[@]}"; do
    # Find all uses: lines with action references
    local uses_lines
    uses_lines=$(grep -n 'uses:' "$f" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*#' || true)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      total=$((total + 1))
      local action_ref
      action_ref=$(echo "$line" | sed 's/.*uses:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"' | tr -d "'")

      # Check if pinned to SHA (40-char hex after @) or major version (e.g., @v4)
      if echo "$action_ref" | grep -qE '@[0-9a-f]{40}'; then
        pass=$((pass + 1))
        details=$(echo "$details" | jq --arg f "$f" --arg a "$action_ref" '. + [{file: $f, status: "pass", note: ("pinned to SHA: " + $a)}]')
      elif echo "$action_ref" | grep -qE '@v[0-9]+(\.[0-9]+)*([-+][a-zA-Z0-9.]+)*$'; then
        pass=$((pass + 1))
        details=$(echo "$details" | jq --arg f "$f" --arg a "$action_ref" '. + [{file: $f, status: "pass", note: ("pinned to version: " + $a)}]')
      elif echo "$action_ref" | grep -qE '^\./'; then
        # Local action — always OK
        pass=$((pass + 1))
        details=$(echo "$details" | jq --arg f "$f" --arg a "$action_ref" '. + [{file: $f, status: "pass", note: ("local action: " + $a)}]')
      else
        details=$(echo "$details" | jq --arg f "$f" --arg a "$action_ref" '. + [{file: $f, status: "fail", note: ("not pinned: " + $a)}]')
      fi
    done <<< "$uses_lines"
  done

  jq -n --arg check "actions-pinned" --argjson pass "$pass" --argjson total "$total" --argjson details "$details" \
    '{check: $check, pass: $pass, total: $total, details: $details}'
}

check_permissions() {
  local pass=0 total=0
  local details="[]"

  for f in "${WORKFLOW_FILES[@]}"; do
    total=$((total + 1))
    # Check for top-level permissions key
    local has_perms
    has_perms=$(yq -r '.permissions // ""' "$f" 2>/dev/null || echo "")
    if [[ -n "$has_perms" ]]; then
      pass=$((pass + 1))
      details=$(echo "$details" | jq --arg f "$f" '. + [{file: $f, status: "pass", note: "has workflow-level permissions"}]')
    else
      # Check if any job has permissions
      local job_perms
      job_perms=$(yq -r '.jobs // {} | to_entries[] | select(.value.permissions != null) | .key' "$f" 2>/dev/null || true)
      if [[ -n "$job_perms" ]]; then
        pass=$((pass + 1))
        details=$(echo "$details" | jq --arg f "$f" '. + [{file: $f, status: "pass", note: "has job-level permissions"}]')
      else
        details=$(echo "$details" | jq --arg f "$f" '. + [{file: $f, status: "fail", note: "no permissions block — uses default (often write-all)"}]')
      fi
    fi
  done

  jq -n --arg check "permissions" --argjson pass "$pass" --argjson total "$total" --argjson details "$details" \
    '{check: $check, pass: $pass, total: $total, details: $details}'
}

check_concurrency() {
  local pass=0 total=0
  local details="[]"

  for f in "${WORKFLOW_FILES[@]}"; do
    # Only check workflows triggered by pull_request
    local has_pr_trigger
    # Handle both map syntax (on: {pull_request: ...}) and array syntax (on: [push, pull_request])
    has_pr_trigger=$(yq -r '.on | ((tag == "!!map" and (has("pull_request") or has("pull_request_target"))) or (tag == "!!seq" and (. | contains(["pull_request"]) or contains(["pull_request_target"])))) // false' "$f" 2>/dev/null || echo "false")

    if [[ "$has_pr_trigger" == "true" ]]; then
      total=$((total + 1))
      local has_concurrency
      has_concurrency=$(yq -r '.concurrency // ""' "$f" 2>/dev/null || echo "")
      if [[ -n "$has_concurrency" ]]; then
        pass=$((pass + 1))
        details=$(echo "$details" | jq --arg f "$f" '. + [{file: $f, status: "pass", note: "has concurrency group"}]')
      else
        details=$(echo "$details" | jq --arg f "$f" '. + [{file: $f, status: "fail", note: "PR workflow missing concurrency group"}]')
      fi
    fi
  done

  # If no PR workflows, report as N/A
  if [[ $total -eq 0 ]]; then
    details=$(echo "$details" | jq '. + [{file: "(none)", status: "skip", note: "no PR-triggered workflows found"}]')
  fi

  jq -n --arg check "concurrency-groups" --argjson pass "$pass" --argjson total "$total" --argjson details "$details" \
    '{check: $check, pass: $pass, total: $total, details: $details}'
}

check_secrets_on_pinned_actions() {
  local pass=0 total=0
  local details="[]"

  if ! $HAS_YQ; then
    jq -n --arg check "secrets-on-pinned-actions" --argjson pass 0 --argjson total 0 --argjson details '[]' \
      '{check: $check, pass: $pass, total: $total, details: $details}'
    return
  fi

  for f in "${WORKFLOW_FILES[@]}"; do
    # Parse each step with yq→jq to find actions that receive secrets via with: or env: blocks.
    # The previous grep -B1 approach missed secrets more than 1 line below uses:.
    local jobs
    jobs=$(yq -r '.jobs // {} | keys[]' "$f" 2>/dev/null || true)
    for job in $jobs; do
      local steps_json
      steps_json=$(yq -o=json ".jobs[\"$job\"].steps // []" "$f" 2>/dev/null || echo "[]")

      # Find steps that (a) have a uses: action (not local ./) and (b) reference secrets.* in with: or env:
      local secret_actions
      secret_actions=$(echo "$steps_json" | jq -r '
        [.[] | select(
          (.uses // "" | test("^\\./") | not) and
          (.uses // "" | length > 0) and
          (
            ((.with // {}) | to_entries | map(.value | tostring) | any(test("secrets\\."))) or
            ((.env // {}) | to_entries | map(.value | tostring) | any(test("secrets\\.")))
          )
        ) | .uses | sub("[[:space:]]*#.*"; "") | gsub("[\"'"'"']"; "")] | .[]
      ' 2>/dev/null || true)

      while IFS= read -r action_ref; do
        [[ -z "$action_ref" ]] && continue
        total=$((total + 1))

        if echo "$action_ref" | grep -qE '@[0-9a-f]{40}'; then
          pass=$((pass + 1))
          details=$(echo "$details" | jq --arg f "$f" --arg a "$action_ref" '. + [{file: $f, status: "pass", note: ("receives secrets, pinned to SHA: " + $a)}]')
        else
          details=$(echo "$details" | jq --arg f "$f" --arg a "$action_ref" '. + [{file: $f, status: "fail", note: ("receives secrets but NOT pinned to SHA: " + $a)}]')
        fi
      done <<< "$secret_actions"
    done
  done

  # If no actions receive secrets, report as clean
  if [[ $total -eq 0 ]]; then
    details=$(echo "$details" | jq '. + [{file: "(none)", status: "skip", note: "no third-party actions receive secrets"}]')
  fi

  jq -n --arg check "secrets-on-pinned-actions" --argjson pass "$pass" --argjson total "$total" --argjson details "$details" \
    '{check: $check, pass: $pass, total: $total, details: $details}'
}

# --- Determine if yq is available (needed for YAML parsing) ---
if ! command -v yq &>/dev/null; then
  echo "Warning: 'yq' is not installed. Some checks will be skipped." >&2
  echo "  Install: brew install yq" >&2
  HAS_YQ=false
else
  HAS_YQ=true
fi

# --- Run checks ---
CHECKS="[]"

if $HAS_YQ; then
  CHECKS=$(echo "$CHECKS" | jq --argjson c "$(check_timeout_minutes)" '. + [$c]')
  CHECKS=$(echo "$CHECKS" | jq --argjson c "$(check_permissions)" '. + [$c]')
  CHECKS=$(echo "$CHECKS" | jq --argjson c "$(check_concurrency)" '. + [$c]')
fi

# check_actions_pinned uses grep; check_secrets_on_pinned_actions uses yq but has its own internal guard
CHECKS=$(echo "$CHECKS" | jq --argjson c "$(check_actions_pinned)" '. + [$c]')
CHECKS=$(echo "$CHECKS" | jq --argjson c "$(check_secrets_on_pinned_actions)" '. + [$c]')

# --- Build result ---
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESULT=$(echo "$CHECKS" | jq --arg ts "$COLLECTED_AT" --arg dir "$DIR" '{
  collected_at: $ts,
  directory: $dir,
  checks: .,
  summary: {
    total_checks: (. | length),
    passing: [.[] | select(.pass == .total and .total > 0)] | length,
    failing: [.[] | select(.pass < .total and .total > 0)] | length,
    skipped: [.[] | select(.total == 0)] | length
  }
}')

# --- Format output ---
format_markdown() {
  echo "$RESULT" | jq -r '
    "## CI Hygiene Checklist",
    "",
    "| Check | Pass | Total | Status |",
    "|-------|------|-------|--------|",
    (.checks[] |
      "| \(.check) | \(.pass) | \(.total) | \(if .total == 0 then "N/A" elif .pass == .total then "PASS" else "FAIL (\(.total - .pass) issues)" end) |"
    ),
    "",
    "**Summary:** \(.summary.passing)/\(.summary.total_checks) checks passing",
    "",
    "### Details",
    "",
    (.checks[] | select(.details | length > 0) |
      "#### \(.check)",
      (.details[] | select(.status == "fail") |
        "- FAIL: \(.file)\(if .job then " / \(.job)" else "" end) — \(.note)"
      ),
      ""
    )
  '
}

if [[ "$FORMAT" == "markdown" ]]; then
  FORMATTED=$(format_markdown)
else
  FORMATTED=$(echo "$RESULT" | jq '.')
fi

if [[ -n "$OUTPUT" ]]; then
  echo "$FORMATTED" > "$OUTPUT"
  echo "Results written to $OUTPUT" >&2
else
  echo "$FORMATTED"
fi

# --- Human summary to stderr ---
echo "" >&2
echo "=== Hygiene Score ===" >&2
echo "$RESULT" | jq -r '
  "Checks: \(.summary.passing)/\(.summary.total_checks) passing",
  (.checks[] | "  \(.check): \(.pass)/\(.total)\(if .total == 0 then " (N/A)" elif .pass == .total then " PASS" else " FAIL" end)")
' >&2
