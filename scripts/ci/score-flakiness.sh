#!/usr/bin/env bash
set -euo pipefail

# score-flakiness.sh — Compute per-job failure rates from recent CI runs and check retry config.
# Structured JSON to stdout; human-readable summary to stderr.

usage() {
  cat <<'USAGE'
Usage: score-flakiness.sh --repo OWNER/REPO [--runs N] [--threshold PCT] [--output FILE] [--format json|markdown]

Analyze recent CI runs for flakiness and check retry configuration.

Options:
  --repo OWNER/REPO   Required. GitHub repository
  --runs N            Number of recent runs to analyze (default: 20)
  --threshold PCT     Failure rate threshold to flag (default: 10, meaning 10%)
  --output FILE       Write output to FILE instead of stdout
  --format FMT        Output format: json (default) or markdown
  --help              Show this help message

Output:
  Per-job failure rates, retry config analysis, and flaky job flags.
USAGE
}

for arg in "$@"; do
  if [[ "$arg" == "--help" ]]; then usage; exit 0; fi
done

# --- Check required tools ---
for tool in gh jq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Error: '$tool' is required but not installed." >&2
    exit 1
  fi
done

# --- Parse arguments ---
REPO=""
RUNS=20
THRESHOLD=10
OUTPUT=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --runs)      RUNS="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --output)    OUTPUT="$2"; shift 2 ;;
    --format)    FORMAT="$2"; shift 2 ;;
    --help)      usage; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Error: --repo is required." >&2
  usage >&2
  exit 1
fi

if [[ "$FORMAT" != "json" && "$FORMAT" != "markdown" ]]; then
  echo "Error: --format must be 'json' or 'markdown'." >&2
  exit 1
fi

# --- Fetch recent runs (all conclusions, on default branch) ---
echo "Fetching last $RUNS runs for $REPO..." >&2

DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main")

RUN_DATA=$(gh run list --repo "$REPO" --branch "$DEFAULT_BRANCH" --limit "$RUNS" \
  --json databaseId,conclusion,createdAt 2>/dev/null || echo "[]")

RUN_IDS=$(echo "$RUN_DATA" | jq -r '.[].databaseId')

if [[ -z "$RUN_IDS" ]]; then
  echo "Error: No runs found for $REPO on branch $DEFAULT_BRANCH." >&2
  exit 1
fi

RUN_ID_ARRAY=()
while IFS= read -r id; do
  [[ -n "$id" ]] && RUN_ID_ARRAY+=("$id")
done <<< "$RUN_IDS"

ACTUAL_RUNS=${#RUN_ID_ARRAY[@]}
echo "Analyzing $ACTUAL_RUNS runs..." >&2

# --- Collect per-job conclusions across all runs ---
ALL_JOBS="[]"

for run_id in "${RUN_ID_ARRAY[@]}"; do
  echo "  Fetching jobs for run $run_id..." >&2
  OWNER="${REPO%%/*}"
  REPO_NAME_LOCAL="${REPO##*/}"
  JOBS=$(gh api "repos/$OWNER/$REPO_NAME_LOCAL/actions/runs/$run_id/jobs" --paginate -q '[.jobs[]]' 2>/dev/null | jq -s 'add // []' || echo "[]")
  TAGGED=$(echo "$JOBS" | jq --arg rid "$run_id" '[.[] | {run_id: ($rid | tonumber), name: .name, conclusion: (.conclusion // "unknown")}]')
  ALL_JOBS=$(echo "$ALL_JOBS" "$TAGGED" | jq -s 'add // []')
done

# --- Compute per-job failure rates ---
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESULT=$(echo "$ALL_JOBS" | jq \
  --arg repo "$REPO" \
  --arg ts "$COLLECTED_AT" \
  --argjson runs "$ACTUAL_RUNS" \
  --argjson threshold "$THRESHOLD" '

  group_by(.name) | map({
    name: .[0].name,
    total_runs: length,
    successes: [.[] | select(.conclusion == "success")] | length,
    failures: [.[] | select(.conclusion == "failure")] | length,
    skipped: [.[] | select(.conclusion == "skipped")] | length,
    other: [.[] | select(.conclusion != "success" and .conclusion != "failure" and .conclusion != "skipped")] | length,
    failure_rate_pct: (
      ([.[] | select(.conclusion == "failure")] | length) as $f |
      ([.[] | select(.conclusion != "skipped")] | length) as $non_skip |
      if $non_skip == 0 then 0
      else (($f / $non_skip) * 100 | . * 10 | round / 10)
      end
    )
  }) |
  sort_by(-.failure_rate_pct) |
  {
    repo: $repo,
    collected_at: $ts,
    runs_analyzed: $runs,
    threshold_pct: $threshold,
    jobs: .,
    flaky_jobs: [.[] | select(.failure_rate_pct >= $threshold)],
    summary: {
      total_jobs: length,
      flaky_jobs: ([.[] | select(.failure_rate_pct >= $threshold)] | length),
      clean_jobs: ([.[] | select(.failure_rate_pct < $threshold and .failure_rate_pct >= 0)] | length),
      max_failure_rate: ([.[].failure_rate_pct] | max // 0)
    }
  }
')

# --- Check retry config in workflow files ---
RETRY_CONFIG="[]"
if [[ -d ".github/workflows" ]]; then
  echo "  Checking retry configuration in workflows..." >&2
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [[ -f "$f" ]] || continue
    # Look for retry-related config
    local_retries=$(grep -n 'retry\|retries\|max_attempts\|attempts' "$f" 2>/dev/null || true)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      RETRY_CONFIG=$(echo "$RETRY_CONFIG" | jq --arg f "$f" --arg l "$line" '. + [{file: $f, line: $l}]')
    done <<< "$local_retries"
  done
fi

RESULT=$(echo "$RESULT" | jq --argjson retries "$RETRY_CONFIG" '. + {retry_config: $retries}')

# --- Format output ---
format_markdown() {
  echo "$RESULT" | jq --argjson thresh "$THRESHOLD" -r '
    "## Flakiness Report",
    "",
    "Analyzed \(.runs_analyzed) recent runs on default branch. Threshold: \(.threshold_pct)%.",
    "",
    "| Job | Runs | Failures | Failure Rate | Status |",
    "|-----|------|----------|-------------|--------|",
    (.jobs[] |
      "| \(.name) | \(.total_runs) | \(.failures) | \(.failure_rate_pct)% | \(if .failure_rate_pct >= $thresh then "FLAKY" else "OK" end) |"
    ),
    "",
    "**Summary:** \(.summary.flaky_jobs) flaky job(s) out of \(.summary.total_jobs)",
    "",
    (if (.flaky_jobs | length) > 0 then
      "### Flaky Jobs (>\(.threshold_pct)% failure rate)",
      "",
      (.flaky_jobs[] | "- **\(.name)**: \(.failure_rate_pct)% failure rate (\(.failures)/\(.total_runs - .skipped) non-skipped runs)")
    else
      "No flaky jobs detected."
    end),
    "",
    (if (.retry_config | length) > 0 then
      "### Retry Configuration Found",
      "",
      (.retry_config[] | "- `\(.file)`: \(.line)")
    else
      "No retry configuration found in workflow files."
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
echo "=== Flakiness Summary ===" >&2
echo "$RESULT" | jq -r '
  "Runs analyzed: \(.runs_analyzed)",
  "Total jobs: \(.summary.total_jobs)",
  "Flaky jobs (>\(.threshold_pct)%): \(.summary.flaky_jobs)",
  "Max failure rate: \(.summary.max_failure_rate)%",
  "",
  (if (.flaky_jobs | length) > 0 then
    "Flaky jobs:",
    (.flaky_jobs[] | "  \(.name): \(.failure_rate_pct)%")
  else
    "No flaky jobs detected."
  end)
' >&2
