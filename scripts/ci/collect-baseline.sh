#!/usr/bin/env bash
set -euo pipefail

# collect-baseline.sh — Collect timing data from recent passing CI runs to establish a baseline.
# Collects from the default branch first, then backfills from PR runs if job coverage is sparse.

usage() {
  cat <<'USAGE'
Usage: collect-baseline.sh --repo OWNER/REPO [--runs N] [--output FILE]

Collect timing data from recent successful CI runs to establish a performance
baseline. Prioritizes default-branch runs, but backfills from PR-branch runs
when default-branch data has sparse job coverage (e.g., PR-only workflows).

Options:
  --repo OWNER/REPO   Required. GitHub repository (e.g. octocat/hello-world)
  --runs N            Number of recent successful runs to sample per source (default: 3)
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

# --- Helper: fetch jobs from a list of run IDs ---
fetch_jobs_for_runs() {
  local result="[]"
  local owner="${REPO%%/*}"
  local repo_name="${REPO##*/}"
  for run_id in "$@"; do
    echo "  Fetching jobs for run $run_id..." >&2
    local jobs_json
    # Use REST API (not CLI) to get runner labels for billable minutes estimation
    jobs_json=$(gh api "repos/$owner/$repo_name/actions/runs/$run_id/jobs" --paginate -q '[.jobs[]]' 2>/dev/null || echo "[]")

    local run_jobs
    run_jobs=$(echo "$jobs_json" | jq --arg rid "$run_id" '
      [ .[] | select(.conclusion == "success" or .conclusion == "skipped") | {
        run_id: ($rid | tonumber),
        name: .name,
        conclusion: .conclusion,
        runner_labels: (.labels // []),
        duration_s: (
          if .conclusion == "skipped" then 0
          else
            ((.completed_at // empty) | fromdateiso8601) -
            ((.started_at // empty) | fromdateiso8601)
          end
        )
      } ]
    ')

    result=$(echo "$result" "$run_jobs" | jq -s 'add // []')
  done
  echo "$result"
}

# --- Count unique workflow names from the repo ---
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
WORKFLOW_COUNT=$(gh api "repos/$OWNER/$REPO_NAME/actions/workflows" --jq '.total_count' 2>/dev/null || echo "0")
echo "Repository has $WORKFLOW_COUNT workflow(s)." >&2

# --- Phase 1: Collect from default branch ---
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main")
echo "Phase 1: Fetching last $RUNS successful runs from $DEFAULT_BRANCH..." >&2

MAIN_RUN_IDS=$(gh run list --repo "$REPO" --branch "$DEFAULT_BRANCH" \
  --status success --limit "$RUNS" --json databaseId -q '.[].databaseId' 2>/dev/null || true)

MAIN_ID_ARRAY=()
ALL_RUN_IDS=()
ALL_JOBS_JSON="[]"

if [[ -n "$MAIN_RUN_IDS" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] && MAIN_ID_ARRAY+=("$id") && ALL_RUN_IDS+=("$id")
  done <<< "$MAIN_RUN_IDS"

  echo "Found ${#MAIN_ID_ARRAY[@]} default-branch runs: ${MAIN_ID_ARRAY[*]}" >&2
  ALL_JOBS_JSON=$(fetch_jobs_for_runs "${MAIN_ID_ARRAY[@]}")
else
  echo "No successful runs found on $DEFAULT_BRANCH." >&2
fi

# --- Phase 2: Check coverage and backfill from PR runs if sparse ---
MAIN_JOB_NAMES=$(echo "$ALL_JOBS_JSON" | jq -r '[.[].name] | unique | length')
echo "Default-branch coverage: $MAIN_JOB_NAMES unique job name(s)." >&2

# Backfill if we have fewer job names than workflows, or very few jobs overall
if [[ "$MAIN_JOB_NAMES" -lt "$WORKFLOW_COUNT" ]] || [[ "$MAIN_JOB_NAMES" -lt 3 ]]; then
  echo "Phase 2: Sparse coverage detected — backfilling from recent PR runs..." >&2

  # Fetch a larger pool of recent successful runs from non-default branches,
  # picking one run per workflow name to maximize job diversity
  PR_CANDIDATES=$(gh run list --repo "$REPO" \
    --status success --limit 30 --json databaseId,headBranch,name \
    --jq "[.[] | select(.headBranch != \"$DEFAULT_BRANCH\")]" 2>/dev/null || echo "[]")

  # Deduplicate: take the most recent run per workflow name
  PR_RUN_IDS=$(echo "$PR_CANDIDATES" | jq -r '
    group_by(.name) | map(.[0].databaseId) | .[]
  ' 2>/dev/null || true)

  if [[ -n "$PR_RUN_IDS" ]]; then
    PR_ID_ARRAY=()
    while IFS= read -r id; do
      [[ -n "$id" ]] && PR_ID_ARRAY+=("$id") && ALL_RUN_IDS+=("$id")
    done <<< "$PR_RUN_IDS"

    echo "Found ${#PR_ID_ARRAY[@]} PR-branch runs (1 per workflow): ${PR_ID_ARRAY[*]}" >&2
    PR_JOBS=$(fetch_jobs_for_runs "${PR_ID_ARRAY[@]}")

    # Only add jobs whose names are NOT already covered by default-branch data
    # Also skip jobs that were skipped (they have 0s duration)
    EXISTING_NAMES=$(echo "$ALL_JOBS_JSON" | jq '[.[].name] | unique')
    NEW_JOBS=$(echo "$PR_JOBS" | jq --argjson existing "$EXISTING_NAMES" '
      [ .[] | select(
        (.name as $n | $existing | index($n) | not) and
        .conclusion == "success"
      ) ]
    ')
    NEW_COUNT=$(echo "$NEW_JOBS" | jq 'length')
    NEW_NAMES=$(echo "$NEW_JOBS" | jq -r '[.[].name] | unique | join(", ")')

    if [[ "$NEW_COUNT" -gt 0 ]]; then
      echo "Backfilled $NEW_COUNT job records for: $NEW_NAMES" >&2
      ALL_JOBS_JSON=$(echo "$ALL_JOBS_JSON" "$NEW_JOBS" | jq -s 'add // []')
    else
      echo "No new successfully-completed job names found in PR runs." >&2
    fi
  else
    echo "No successful PR-branch runs found." >&2
  fi
fi

# --- Final job count ---
FINAL_JOB_NAMES=$(echo "$ALL_JOBS_JSON" | jq -r '[.[].name] | unique | length')
echo "Final coverage: $FINAL_JOB_NAMES unique job name(s)." >&2

if [[ $(echo "$ALL_JOBS_JSON" | jq 'length') -eq 0 ]]; then
  echo "Error: No job data collected from any source." >&2
  exit 1
fi

# --- Compute stats per job name ---
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESULT=$(echo "$ALL_JOBS_JSON" | jq --arg repo "$REPO" --arg ts "$COLLECTED_AT" \
  --argjson run_ids "$(printf '%s\n' "${ALL_RUN_IDS[@]}" | jq -R 'tonumber' | jq -s '.')" '
  # Filter out skipped jobs for timing stats (they contribute 0s which skews medians)
  [ .[] | select(.conclusion != "skipped") ] |

  # Group by job name
  group_by(.name) |
  map({
    name: .[0].name,
    runner_labels: (.[0].runner_labels // []),
    runs: [ .[] | { run_id: .run_id, duration_s: .duration_s } ],
    sorted: ([ .[].duration_s ] | sort)
  }) |
  map({
    name: .name,
    runner_labels: .runner_labels,
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
          runner_labels: $j.runner_labels,
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
echo "Runs sampled: ${#ALL_RUN_IDS[@]} (${#MAIN_ID_ARRAY[@]} default-branch + $((${#ALL_RUN_IDS[@]} - ${#MAIN_ID_ARRAY[@]})) PR-branch)" >&2
echo "$RESULT" | jq -r '
  "Total median: \(.total_median_s)s",
  "",
  "Per-job medians:",
  (.jobs | to_entries[] | "  \(.key): \(.value.median_duration_s)s (min=\(.value.min_duration_s)s, max=\(.value.max_duration_s)s)")
' >&2
