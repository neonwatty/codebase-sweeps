#!/usr/bin/env bash
set -euo pipefail

# run-actionlint.sh — Run actionlint on workflow files and output structured results.

usage() {
  cat <<'USAGE'
Usage: run-actionlint.sh [--dir .github/workflows] [--output FILE] [--format json|markdown]

Run actionlint on GitHub Actions workflow files and produce structured findings.

Options:
  --dir DIR           Workflow directory to lint (default: .github/workflows)
  --output FILE       Write output to FILE instead of stdout
  --format FMT        Output format: json (default) or markdown
  --help              Show this help message

Output:
  Structured JSON or markdown to stdout (or --output file).
  Human-readable summary to stderr.
USAGE
}

# --- Early help check ---
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

if ! command -v actionlint &>/dev/null; then
  echo "Error: 'actionlint' is not installed." >&2
  echo "" >&2
  echo "Install instructions:" >&2
  echo "  brew install rhysd/actionlint/actionlint     # macOS (Homebrew)" >&2
  echo "  go install github.com/rhysd/actionlint/cmd/actionlint@latest  # Go" >&2
  echo "  Download from: https://github.com/rhysd/actionlint/releases" >&2
  exit 1
fi

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

echo "Running actionlint on $DIR..." >&2

# --- Collect workflow files (only those that exist) ---
LINT_FILES=()
for ext in yml yaml; do
  for f in "$DIR"/*."$ext"; do
    [[ -f "$f" ]] && LINT_FILES+=("$f")
  done
done

if [[ ${#LINT_FILES[@]} -eq 0 ]]; then
  echo "Error: No workflow files found in $DIR" >&2
  exit 1
fi

# --- Run actionlint with JSON output ---
# actionlint returns non-zero when it finds issues, so we capture it
RAW_OUTPUT=$(actionlint -format '{{json .}}' "${LINT_FILES[@]}" 2>/dev/null || true)

# Parse into structured findings
if [[ -z "$RAW_OUTPUT" ]]; then
  # No findings
  FINDINGS_JSON="[]"
else
  FINDINGS_JSON=$(echo "$RAW_OUTPUT" | jq -s '[
    .[] | {
      file: .filepath,
      line: .line,
      column: .column,
      severity: (if .kind == "syntax-check" or .kind == "type-check" or .kind == "expression" then "error" else "warning" end),
      message: .message,
      rule: .kind
    }
  ]')
fi

RESULT=$(echo "$FINDINGS_JSON" | jq '{
  total: length,
  errors: [.[] | select(.severity == "error")] | length,
  warnings: [.[] | select(.severity == "warning")] | length,
  findings: .
}')

# --- Format output ---
format_markdown() {
  echo "$RESULT" | jq -r '
    "## actionlint Results",
    "",
    "**Total: \(.total)** (Errors: \(.errors), Warnings: \(.warnings))",
    "",
    (if .total == 0 then
      "No issues found."
    else
      "| File | Line | Col | Severity | Rule | Message |",
      "|------|------|-----|----------|------|---------|",
      (.findings[] |
        "| \(.file) | \(.line) | \(.column) | \(.severity) | \(.rule) | \(.message) |"
      )
    end)
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
echo "=== actionlint Summary ===" >&2
echo "$RESULT" | jq -r '
  "Total findings: \(.total)",
  "  Errors: \(.errors)",
  "  Warnings: \(.warnings)"
' >&2

# Exit with error if there are errors (not warnings)
ERRORS=$(echo "$RESULT" | jq '.errors')
if [[ "$ERRORS" -gt 0 ]]; then
  echo "Exiting with status 1 due to $ERRORS error(s)." >&2
  exit 1
fi
