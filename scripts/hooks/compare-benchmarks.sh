#!/usr/bin/env bash
set -euo pipefail

######################################################################
# compare-benchmarks.sh — Compare baseline vs current benchmark JSON
# files and produce a delta report (markdown or JSON).
#
# Structured JSON goes to stdout; human summaries go to stderr.
######################################################################

# ── defaults ──────────────────────────────────────────────────────
BASELINE=""
CURRENT=""
OUTPUT=""
FORMAT="markdown"

# ── usage ─────────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --baseline FILE --current FILE [OPTIONS]

Compare two benchmark JSON files and produce a delta report.

Required:
  --baseline FILE   Path to baseline benchmark JSON
  --current  FILE   Path to current benchmark JSON

Options:
  --output   FILE           Write output to FILE
  --format   markdown|json  Output format (default: markdown)
  --help                    Show this help message
EOF
  exit 0
}

# ── parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2 ;;
    --current)  CURRENT="$2";  shift 2 ;;
    --output)   OUTPUT="$2";   shift 2 ;;
    --format)   FORMAT="$2";   shift 2 ;;
    --help)     usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$BASELINE" ]] || [[ -z "$CURRENT" ]]; then
  echo "ERROR: --baseline and --current are required." >&2
  usage
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "ERROR: Baseline file not found: $BASELINE" >&2
  exit 1
fi

if [[ ! -f "$CURRENT" ]]; then
  echo "ERROR: Current file not found: $CURRENT" >&2
  exit 1
fi

if [[ "$FORMAT" != "markdown" ]] && [[ "$FORMAT" != "json" ]]; then
  echo "ERROR: --format must be 'markdown' or 'json'" >&2
  exit 1
fi

# ── tool checks ───────────────────────────────────────────────────
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not found." >&2; exit 1; }; }
require jq

# ── comparison ────────────────────────────────────────────────────
echo "hooks-audit: compare-benchmarks (format=$FORMAT)" >&2

COMPARISON_JSON=$(jq -n \
  --slurpfile base "$BASELINE" \
  --slurpfile curr "$CURRENT" \
'
  ($base[0].hooks | keys) as $base_hooks |
  ($curr[0].hooks | keys) as $curr_hooks |
  ([$base_hooks[], $curr_hooks[]] | unique) as $all_hooks |

  {
    baseline_collected_at: $base[0].collected_at,
    current_collected_at:  $curr[0].collected_at,
    comparisons: [
      $all_hooks[] as $h |
      ($base[0].hooks[$h] // null) as $bh |
      ($curr[0].hooks[$h] // null) as $ch |
      if ($bh == null or $bh.status != "benchmarked") and ($ch == null or $ch.status != "benchmarked") then
        {
          hook: $h,
          status: "not_configured"
        }
      elif ($bh == null or $bh.status != "benchmarked") then
        {
          hook: $h,
          status: "new_in_current",
          current_median_s: $ch.median_s,
          current_mean_s:   $ch.mean_s,
          current_stddev_s: $ch.stddev_s
        }
      elif ($ch == null or $ch.status != "benchmarked") then
        {
          hook: $h,
          status: "removed_in_current",
          baseline_median_s: $bh.median_s,
          baseline_mean_s:   $bh.mean_s,
          baseline_stddev_s: $bh.stddev_s
        }
      else
        {
          hook: $h,
          status: "compared",
          baseline_median_s: $bh.median_s,
          baseline_mean_s:   $bh.mean_s,
          baseline_stddev_s: $bh.stddev_s,
          current_median_s:  $ch.median_s,
          current_mean_s:    $ch.mean_s,
          current_stddev_s:  $ch.stddev_s,
          delta_median_s:    (($ch.median_s - $bh.median_s) * 1000 | round / 1000),
          delta_mean_s:      (($ch.mean_s   - $bh.mean_s)   * 1000 | round / 1000),
          pct_change_median: (if $bh.median_s == 0 then null
                              else (($ch.median_s - $bh.median_s) / $bh.median_s * 100 | round)
                              end),
          pct_change_mean:   (if $bh.mean_s == 0 then null
                              else (($ch.mean_s - $bh.mean_s) / $bh.mean_s * 100 | round)
                              end)
        }
      end
    ]
  }
')

# ── output ────────────────────────────────────────────────────────
if [[ "$FORMAT" == "json" ]]; then
  result="$COMPARISON_JSON"
else
  # Markdown table
  result=$(echo "$COMPARISON_JSON" | jq -r '
    "| Hook | Baseline (median) | Current (median) | Delta | % Change |",
    "|------|-------------------|------------------|-------|----------|",
    (.comparisons[] |
      if .status == "compared" then
        "| \(.hook) | \(.baseline_median_s)s ± \(.baseline_stddev_s)s | \(.current_median_s)s ± \(.current_stddev_s)s | \(if .delta_median_s > 0 then "+\(.delta_median_s)" else "\(.delta_median_s)" end)s | \(if .pct_change_median == null then "N/A" elif .pct_change_median > 0 then "+\(.pct_change_median)%" else "\(.pct_change_median)%" end) |"
      elif .status == "not_configured" then
        "| \(.hook) | not configured | not configured | — | — |"
      elif .status == "new_in_current" then
        "| \(.hook) | — | \(.current_median_s)s ± \(.current_stddev_s)s | new | new |"
      elif .status == "removed_in_current" then
        "| \(.hook) | \(.baseline_median_s)s ± \(.baseline_stddev_s)s | — | removed | removed |"
      else
        "| \(.hook) | ? | ? | ? | ? |"
      end
    )
  ')
fi

if [[ -n "$OUTPUT" ]]; then
  echo "$result" > "$OUTPUT"
  echo "  Results written to $OUTPUT" >&2
fi

echo "$result"
echo "  Done." >&2
