#!/usr/bin/env bash
set -euo pipefail

# compare-runs.sh — Compare baseline timing against post-change timing and produce a multi-axis delta report.
# Includes wall-clock timing and estimated billable minutes.

usage() {
  cat <<'USAGE'
Usage: compare-runs.sh --baseline FILE --current FILE [--output FILE] [--format markdown|json]
                       [--hygiene-before FILE] [--hygiene-after FILE]
                       [--flakiness FILE]

Compare baseline CI timing against a current run and produce a multi-axis delta report.

Options:
  --baseline FILE         Required. Path to baseline JSON (from collect-baseline.sh)
  --current FILE          Required. Path to current run JSON (from collect-run-timing.sh)
  --hygiene-before FILE   Optional. Hygiene score before changes (from score-hygiene.sh)
  --hygiene-after FILE    Optional. Hygiene score after changes (from score-hygiene.sh)
  --flakiness FILE        Optional. Flakiness report (from score-flakiness.sh)
  --output FILE           Write output to FILE instead of stdout
  --format FMT            Output format: markdown (default) or json
  --help                  Show this help message

Output:
  Multi-axis comparison: wall-clock timing, estimated billable minutes,
  hygiene checklist (if provided), and flakiness report (if provided).
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
HYGIENE_BEFORE=""
HYGIENE_AFTER=""
FLAKINESS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)        BASELINE="$2"; shift 2 ;;
    --current)         CURRENT="$2"; shift 2 ;;
    --output)          OUTPUT="$2"; shift 2 ;;
    --format)          FORMAT="$2"; shift 2 ;;
    --hygiene-before)  HYGIENE_BEFORE="$2"; shift 2 ;;
    --hygiene-after)   HYGIENE_AFTER="$2"; shift 2 ;;
    --flakiness)       FLAKINESS="$2"; shift 2 ;;
    --help)            usage; exit 0 ;;
    *)                 echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
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

for f in "$BASELINE" "$CURRENT"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: File not found: $f" >&2
    exit 1
  fi
done

if [[ "$FORMAT" != "markdown" && "$FORMAT" != "json" ]]; then
  echo "Error: --format must be 'markdown' or 'json'." >&2
  exit 1
fi

# --- Runner multiplier lookup ---
# GitHub Actions billing: Linux=1x, Windows=2x, macOS=10x
# We infer OS from runner labels in the jobs API response
runner_multiplier_jq='
  def runner_multiplier:
    (. // [] | map(ascii_downcase)) as $labels |
    if ($labels | any(startswith("macos"))) then 10
    elif ($labels | any(startswith("windows"))) then 2
    else 1
    end;
'

# --- Build wall-clock comparison data ---
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
    timing: {
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
  }
')

# --- Estimate billable minutes ---
# We try to get runner labels from the current run data (collect-run-timing.sh includes them if available)
BILLABLE=$(jq -n \
  --slurpfile baseline "$BASELINE" \
  --slurpfile current "$CURRENT" "
  $runner_multiplier_jq

  (\$baseline[0]) as \$b |
  (\$current[0]) as \$c |

  # Baseline: estimate from median durations (assume Linux if no label info)
  (\$b.jobs | to_entries | map(
    (.value.median_duration_s / 60) as \$mins |
    (.value.runner_labels // null) as \$labels |
    {
      name: .key,
      duration_min: (\$mins * 100 | round / 100),
      multiplier: ((\$labels // []) | runner_multiplier),
      billable_min: ((\$mins * ((\$labels // []) | runner_multiplier)) * 100 | round / 100)
    }
  )) as \$baseline_billable |

  # Current: estimate from actual durations
  (\$c.jobs | map(
    (.duration_s / 60) as \$mins |
    (.runner_labels // null) as \$labels |
    {
      name: .name,
      duration_min: (\$mins * 100 | round / 100),
      multiplier: ((\$labels // []) | runner_multiplier),
      billable_min: ((\$mins * ((\$labels // []) | runner_multiplier)) * 100 | round / 100)
    }
  )) as \$current_billable |

  {
    baseline_total_min: ([\$baseline_billable[].billable_min] | add // 0 | . * 100 | round / 100),
    current_total_min: ([\$current_billable[].billable_min] | add // 0 | . * 100 | round / 100),
    delta_min: (([\$current_billable[].billable_min] | add // 0) - ([\$baseline_billable[].billable_min] | add // 0) | . * 100 | round / 100),
    baseline_jobs: \$baseline_billable,
    current_jobs: \$current_billable
  }
")

COMPARISON=$(echo "$COMPARISON" | jq --argjson billable "$BILLABLE" '. + {billable: $billable}')

# --- Add hygiene comparison if provided ---
if [[ -n "$HYGIENE_BEFORE" && -f "$HYGIENE_BEFORE" && -n "$HYGIENE_AFTER" && -f "$HYGIENE_AFTER" ]]; then
  HYGIENE_CMP=$(jq -n \
    --slurpfile before "$HYGIENE_BEFORE" \
    --slurpfile after "$HYGIENE_AFTER" '
    {
      before: $before[0].checks,
      after: $after[0].checks,
      before_summary: $before[0].summary,
      after_summary: $after[0].summary
    }
  ')
  COMPARISON=$(echo "$COMPARISON" | jq --argjson hygiene "$HYGIENE_CMP" '. + {hygiene: $hygiene}')
fi

# --- Add flakiness if provided ---
if [[ -n "$FLAKINESS" && -f "$FLAKINESS" ]]; then
  FLAKINESS_DATA=$(jq '.' "$FLAKINESS")
  COMPARISON=$(echo "$COMPARISON" | jq --argjson flakiness "$FLAKINESS_DATA" '. + {flakiness: $flakiness}')
fi

# --- Format output ---
format_markdown() {
  local output=""

  # Timing section
  output+=$(echo "$COMPARISON" | jq -r '
    "#### Timing",
    "",
    "| Job | Baseline (s) | Current (s) | Delta | % Change |",
    "|-----|-------------|-------------|-------|----------|",
    (.timing.matched_jobs[] |
      "| \(.name) | \(.baseline_s) | \(.current_s) | \(if .delta_s >= 0 then "+\(.delta_s)" else "\(.delta_s)" end) | \(if .pct_change != null then (if .pct_change >= 0 then "+\(.pct_change)%" else "\(.pct_change)%"  end) else "N/A" end) |"
    ),
    "| **TOTAL** | **\(.timing.total_baseline_s)** | **\(.timing.total_current_s)** | **\(if .timing.total_delta_s >= 0 then "+\(.timing.total_delta_s)" else "\(.timing.total_delta_s)" end)** | **\(if .timing.total_pct_change != null then (if .timing.total_pct_change >= 0 then "+\(.timing.total_pct_change)%" else "\(.timing.total_pct_change)%" end) else "N/A" end)** |"
  ')
  output+=$'\n\n'

  # Structural changes
  output+=$(echo "$COMPARISON" | jq -r '
    "#### Structural Changes",
    "",
    (if (.timing.removed_jobs | length) > 0 then
      "- Jobs removed: " + ([.timing.removed_jobs[] | "\(.name) (was \(.baseline_s)s)"] | join(", "))
    else
      "- Jobs removed: none"
    end),
    (if (.timing.added_jobs | length) > 0 then
      "- Jobs added: " + ([.timing.added_jobs[] | "\(.name) (\(.current_s)s)"] | join(", "))
    else
      "- Jobs added: none"
    end),
    (if (.timing.skipped_jobs | length) > 0 then
      "- Jobs skipped: " + ([.timing.skipped_jobs[] | .name] | join(", "))
    else
      "- Jobs skipped: none"
    end)
  ')
  output+=$'\n\n'

  # Billable minutes
  output+=$(echo "$COMPARISON" | jq -r '
    "#### Billable Minutes (estimated)",
    "",
    "| Metric | Before | After | Delta |",
    "|--------|--------|-------|-------|",
    "| Total billable min | \(.billable.baseline_total_min) | \(.billable.current_total_min) | \(if .billable.delta_min >= 0 then "+\(.billable.delta_min)" else "\(.billable.delta_min)" end) |",
    "",
    "Runner multipliers: Linux=1x, Windows=2x, macOS=10x"
  ')
  output+=$'\n\n'

  # Hygiene (if present)
  if echo "$COMPARISON" | jq -e '.hygiene' >/dev/null 2>&1; then
    output+=$(echo "$COMPARISON" | jq -r '
      "#### Hygiene Checklist",
      "",
      "| Check | Before | After |",
      "|-------|--------|-------|",
      (
        .hygiene.before as $before |
        .hygiene.after as $after |
        ($before | map(.check)) as $checks |
        $checks[] |
        . as $c |
        ($before | map(select(.check == $c)) | first) as $b |
        ($after | map(select(.check == $c)) | first) as $a |
        "| \($c) | \($b.pass)/\($b.total) | \($a.pass)/\($a.total) |"
      )
    ')
    output+=$'\n\n'
  fi

  # Flakiness (if present)
  if echo "$COMPARISON" | jq -e '.flakiness' >/dev/null 2>&1; then
    output+=$(echo "$COMPARISON" | jq -r '
      "#### Flakiness",
      "",
      "| Job | Failure Rate | Status |",
      "|-----|-------------|--------|",
      (.flakiness.jobs[] |
        "| \(.name) | \(.failure_rate_pct)% | \(if .failure_rate_pct >= 10 then "FLAKY" else "OK" end) |"
      ),
      "",
      "Flaky jobs: \(.flakiness.summary.flaky_jobs)/\(.flakiness.summary.total_jobs)"
    ')
    output+=$'\n'
  fi

  echo "$output"
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
  "Timing: \(.timing.total_baseline_s)s -> \(.timing.total_current_s)s (\(if .timing.total_delta_s >= 0 then "+\(.timing.total_delta_s)" else "\(.timing.total_delta_s)" end)s, \(if .timing.total_pct_change != null then "\(.timing.total_pct_change)%" else "N/A" end))",
  "Billable: \(.billable.baseline_total_min)min -> \(.billable.current_total_min)min (\(if .billable.delta_min >= 0 then "+\(.billable.delta_min)" else "\(.billable.delta_min)" end)min)",
  "Matched jobs: \(.timing.matched_jobs | length)",
  "Removed jobs: \(.timing.removed_jobs | length)",
  "Added jobs: \(.timing.added_jobs | length)"
' >&2
