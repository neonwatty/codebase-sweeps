#!/usr/bin/env bash
set -euo pipefail

# collect-baseline.sh — Collect timing data from recent passing CI runs to establish a baseline.

usage() {
  cat <<'USAGE'
Usage: collect-baseline.sh --repo OWNER/REPO [--runs N] [--output FILE]

Collect timing data from recent successful CI runs on the default branch
to establish a performance baseline.

Options:
  --repo OWNER/REPO   Required. GitHub repository (e.g. octocat/hello-world)
  --runs N            Number of recent successful runs to sample (default: 3)
  --output FILE       Write JSON output to FILE instead of stdout
  --help              Show this help message

Output:
  Structured JSON to stdout (or --output file).
  Human-readable summary to stderr.
USAGE
}

# --- Early help check ---
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
RUNS=3
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2 ;;
    --runs)   RUNS="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --help)   usage; exit 0 ;;
    *)        echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Error: --repo is required." >&2
  usage >&2
  exit 1
fi

# --- Fetch recent successful runs from the default branch ---
echo "Fetching last $RUNS successful runs for $REPO..." >&2

RUN_IDS=$(gh run list --repo "$REPO" --branch "$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name')" \
  --status success --limit "$RUNS" --json databaseId -q '.[].databaseId')

if [[ -z "$RUN_IDS" ]]; then
  echo "Error: No successful runs found." >&2
  exit 1
fi

RUN_ID_ARRAY=()
while IFS= read -r id; do
  RUN_ID_ARRAY+=("$id")
done <<< "$RUN_IDS"

echo "Found ${#RUN_ID_ARRAY[@]} runs: ${RUN_ID_ARRAY[*]}" >&2

# --- Collect per-job timing for each run ---
ALL_JOBS_JSON="[]"

for run_id in "${RUN_ID_ARRAY[@]}"; do
  echo "  Fetching jobs for run $run_id..." >&2
  JOBS_JSON=$(gh run view "$run_id" --repo "$REPO" --json jobs -q '.jobs')

  # Calculate duration for each job and tag with run_id
  RUN_JOBS=$(echo "$JOBS_JSON" | jq --arg rid "$run_id" '
    [ .[] | {
      run_id: ($rid | tonumber),
      name: .name,
      duration_s: (
        ((.completedAt // empty) | fromdateiso8601) -
        ((.startedAt // empty) | fromdateiso8601)
      )
    } ]
  ')

  ALL_JOBS_JSON=$(echo "$ALL_JOBS_JSON" "$RUN_JOBS" | jq -s '.[0] + .[1]')
done

# --- Compute stats per job name ---
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESULT=$(echo "$ALL_JOBS_JSON" | jq --arg repo "$REPO" --arg ts "$COLLECTED_AT" \
  --argjson run_ids "$(printf '%s\n' "${RUN_ID_ARRAY[@]}" | jq -R 'tonumber' | jq -s '.')" '
  # Group by job name
  group_by(.name) |
  map({
    name: .[0].name,
    runs: [ .[] | { run_id: .run_id, duration_s: .duration_s } ],
    sorted: ([ .[].duration_s ] | sort)
  }) |
  map({
    name: .name,
    runs: .runs,
    min_duration_s: (.sorted | first),
    max_duration_s: (.sorted | last),
    median_duration_s: (
      .sorted as $s |
      ($s | length) as $len |
      if $len == 0 then 0
      elif ($len % 2) == 1 then $s[($len - 1) / 2]
      else (($s[$len / 2 - 1] + $s[$len / 2]) / 2)
      end
    )
  }) |
  {
    repo: $repo,
    baseline_runs: $run_ids,
    collected_at: $ts,
    jobs: (
      reduce .[] as $j ({}; . + {
        ($j.name): {
          median_duration_s: $j.median_duration_s,
          min_duration_s: $j.min_duration_s,
          max_duration_s: $j.max_duration_s,
          runs: $j.runs
        }
      })
    ),
    total_median_s: ([ .[].median_duration_s ] | add // 0)
  }
')

# --- Output ---
if [[ -n "$OUTPUT" ]]; then
  echo "$RESULT" | jq '.' > "$OUTPUT"
  echo "Baseline written to $OUTPUT" >&2
else
  echo "$RESULT" | jq '.'
fi

# --- Human summary to stderr ---
echo "" >&2
echo "=== Baseline Summary ===" >&2
echo "Repo: $REPO" >&2
echo "Runs sampled: ${#RUN_ID_ARRAY[@]}" >&2
echo "$RESULT" | jq -r '
  "Total median: \(.total_median_s)s",
  "",
  "Per-job medians:",
  (.jobs | to_entries[] | "  \(.key): \(.value.median_duration_s)s (min=\(.value.min_duration_s)s, max=\(.value.max_duration_s)s)")
' >&2
