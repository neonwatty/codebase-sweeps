#!/usr/bin/env bash
set -euo pipefail

# compare-runs.sh — Compare baseline timing against post-change timing and produce a delta report.

usage() {
  cat <<'USAGE'
Usage: compare-runs.sh --baseline FILE --current FILE [--output FILE] [--format markdown|json]

Compare baseline CI timing against a current run and produce a delta report.

Options:
  --baseline FILE     Required. Path to baseline JSON (from collect-baseline.sh)
  --current FILE      Required. Path to current run JSON (from collect-run-timing.sh)
  --output FILE       Write output to FILE instead of stdout
  --format FMT        Output format: markdown (default) or json
  --help              Show this help message

Output:
  Markdown table or JSON comparison to stdout (or --output file).
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

# --- Parse arguments ---
BASELINE=""
CURRENT=""
OUTPUT=""
FORMAT="markdown"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2 ;;
    --current)  CURRENT="$2"; shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    --format)   FORMAT="$2"; shift 2 ;;
    --help)     usage; exit 0 ;;
    *)          echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$BASELINE" ]]; then
  echo "Error: --baseline is required." >&2
  usage >&2
  exit 1
fi

if [[ -z "$CURRENT" ]]; then
  echo "Error: --current is required." >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "Error: Baseline file not found: $BASELINE" >&2
  exit 1
fi

if [[ ! -f "$CURRENT" ]]; then
  echo "Error: Current file not found: $CURRENT" >&2
  exit 1
fi

if [[ "$FORMAT" != "markdown" && "$FORMAT" != "json" ]]; then
  echo "Error: --format must be 'markdown' or 'json'." >&2
  exit 1
fi

# --- Build comparison data ---
COMPARISON=$(jq -n \
  --slurpfile baseline "$BASELINE" \
  --slurpfile current "$CURRENT" '
  ($baseline[0]) as $b |
  ($current[0]) as $c |

  # Baseline job names and median durations
  ($b.jobs | to_entries | map({name: .key, baseline_s: .value.median_duration_s})) as $baseline_jobs |
  ($baseline_jobs | map(.name)) as $baseline_names |

  # Current job names and durations
  ($c.jobs | map({name: .name, current_s: .duration_s, conclusion: .conclusion})) as $current_jobs |
  ($current_jobs | map(.name)) as $current_names |

  # Matched jobs (present in both)
  [
    $baseline_jobs[] |
    .name as $jn |
    ($current_jobs | map(select(.name == $jn)) | first // null) as $cj |
    if $cj then {
      name: $jn,
      baseline_s: .baseline_s,
      current_s: $cj.current_s,
      conclusion: $cj.conclusion,
      delta_s: ($cj.current_s - .baseline_s),
      pct_change: (
        if .baseline_s == 0 then null
        else ((($cj.current_s - .baseline_s) / .baseline_s) * 100 | round)
        end
      )
    } else null end
  ] | map(select(. != null)) as $matched |

  # Removed jobs (in baseline but not current)
  [$baseline_jobs[] | select(.name as $n | $current_names | index($n) | not)] as $removed |

  # New jobs (in current but not baseline)
  [$current_jobs[] | select(.name as $n | $baseline_names | index($n) | not)] as $added |

  # Skipped jobs (in current with conclusion "skipped")
  [$current_jobs[] | select(.conclusion == "skipped")] as $skipped |

  # Totals
  ($b.total_median_s) as $total_baseline |
  ([$c.jobs[].duration_s] | add // 0) as $total_current |

  {
    baseline_repo: $b.repo,
    baseline_runs: $b.baseline_runs,
    current_run_id: $c.run_id,
    compared_at: (now | todate),
    matched_jobs: $matched,
    removed_jobs: $removed,
    added_jobs: $added,
    skipped_jobs: $skipped,
    total_baseline_s: $total_baseline,
    total_current_s: $total_current,
    total_delta_s: ($total_current - $total_baseline),
    total_pct_change: (
      if $total_baseline == 0 then null
      else ((($total_current - $total_baseline) / $total_baseline) * 100 | round)
      end
    )
  }
')

# --- Format output ---
format_markdown() {
  echo "$COMPARISON" | jq -r '
    "| Job | Baseline (s) | Current (s) | Delta | % Change |",
    "|-----|-------------|-------------|-------|----------|",
    (.matched_jobs[] |
      "| \(.name) | \(.baseline_s) | \(.current_s) | \(if .delta_s >= 0 then "+\(.delta_s)" else "\(.delta_s)" end) | \(if .pct_change != null then (if .pct_change >= 0 then "+\(.pct_change)%" else "\(.pct_change)%"  end) else "N/A" end) |"
    ),
    "| **TOTAL** | **\(.total_baseline_s)** | **\(.total_current_s)** | **\(if .total_delta_s >= 0 then "+\(.total_delta_s)" else "\(.total_delta_s)" end)** | **\(if .total_pct_change != null then (if .total_pct_change >= 0 then "+\(.total_pct_change)%" else "\(.total_pct_change)%" end) else "N/A" end)** |",
    "",
    "### Structural Changes",
    (if (.removed_jobs | length) > 0 then
      "- Jobs removed: " + ([.removed_jobs[] | "\(.name) (was \(.baseline_s)s)"] | join(", "))
    else
      "- Jobs removed: none"
    end),
    (if (.added_jobs | length) > 0 then
      "- Jobs added: " + ([.added_jobs[] | "\(.name) (\(.current_s)s)"] | join(", "))
    else
      "- Jobs added: none"
    end),
    (if (.skipped_jobs | length) > 0 then
      "- Jobs skipped: " + ([.skipped_jobs[] | .name] | join(", "))
    else
      "- Jobs skipped: none"
    end)
  '
}

if [[ "$FORMAT" == "markdown" ]]; then
  RESULT=$(format_markdown)
else
  RESULT=$(echo "$COMPARISON" | jq '.')
fi

if [[ -n "$OUTPUT" ]]; then
  echo "$RESULT" > "$OUTPUT"
  echo "Comparison written to $OUTPUT" >&2
else
  echo "$RESULT"
fi

# --- Human summary to stderr ---
echo "" >&2
echo "=== Comparison Summary ===" >&2
echo "$COMPARISON" | jq -r '
  "Total: \(.total_baseline_s)s -> \(.total_current_s)s (\(if .total_delta_s >= 0 then "+\(.total_delta_s)" else "\(.total_delta_s)" end)s, \(if .total_pct_change != null then "\(.total_pct_change)%" else "N/A" end))",
  "Matched jobs: \(.matched_jobs | length)",
  "Removed jobs: \(.removed_jobs | length)",
  "Added jobs: \(.added_jobs | length)",
  "Skipped jobs: \(.skipped_jobs | length)"
' >&2
