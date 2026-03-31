#!/usr/bin/env bash
set -euo pipefail

# collect-run-timing.sh — Collect detailed timing from a specific CI run.

usage() {
  cat <<'USAGE'
Usage: collect-run-timing.sh --repo OWNER/REPO --run-id ID [--output FILE]

Collect detailed per-job and per-step timing from a specific GitHub Actions run.

Options:
  --repo OWNER/REPO   Required. GitHub repository (e.g. octocat/hello-world)
  --run-id ID         Required. The workflow run ID
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
RUN_ID=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --run-id)  RUN_ID="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --help)    usage; exit 0 ;;
    *)         echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Error: --repo is required." >&2
  usage >&2
  exit 1
fi

if [[ -z "$RUN_ID" ]]; then
  echo "Error: --run-id is required." >&2
  usage >&2
  exit 1
fi

# --- Split owner/repo for API calls ---
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

echo "Fetching timing for run $RUN_ID in $REPO..." >&2

# --- Fetch per-step timing via the REST API ---
JOBS_API_JSON=$(gh api "repos/$OWNER/$REPO_NAME/actions/runs/$RUN_ID/jobs" --paginate)

COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESULT=$(echo "$JOBS_API_JSON" | jq --arg repo "$REPO" --argjson run_id "$RUN_ID" --arg ts "$COLLECTED_AT" '
  .jobs as $jobs |
  {
    repo: $repo,
    run_id: $run_id,
    collected_at: $ts,
    jobs: [
      $jobs[] | {
        name: .name,
        duration_s: (
          ((.completed_at // empty) | fromdateiso8601) -
          ((.started_at // empty) | fromdateiso8601)
        ),
        conclusion: (.conclusion // "unknown"),
        steps: [
          (.steps // [])[] | {
            name: .name,
            duration_s: (
              if (.completed_at != null and .started_at != null) then
                ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601))
              else 0
              end
            ),
            conclusion: (.conclusion // "unknown")
          }
        ]
      }
    ]
  } |
  .total_duration_s = ([ .jobs[].duration_s ] | add // 0)
')

# --- Output ---
if [[ -n "$OUTPUT" ]]; then
  echo "$RESULT" | jq '.' > "$OUTPUT"
  echo "Run timing written to $OUTPUT" >&2
else
  echo "$RESULT" | jq '.'
fi

# --- Human summary to stderr ---
echo "" >&2
echo "=== Run $RUN_ID Summary ===" >&2
echo "Repo: $REPO" >&2
echo "$RESULT" | jq -r '
  "Total duration: \(.total_duration_s)s",
  "",
  "Jobs:",
  (.jobs[] |
    "  \(.name): \(.duration_s)s [\(.conclusion)]",
    (.steps[] | "    - \(.name): \(.duration_s)s [\(.conclusion)]")
  )
' >&2
