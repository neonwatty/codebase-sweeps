#!/usr/bin/env bash
set -euo pipefail

# compare-profiles.sh - Compare baseline hook profile against post-change profile.
# Outputs structured JSON or markdown to stdout; human-readable summaries to stderr.

BASELINE=""
CURRENT=""
OUTPUT=""
FORMAT="markdown"

usage() {
  cat >&2 <<'EOF'
Usage: compare-profiles.sh --baseline FILE --current FILE [--output FILE] [--format markdown|json] [--help]

Compare two hook profile snapshots and produce a delta report.

Options:
  --baseline FILE    Baseline profile JSON (from profile-hooks.sh)
  --current FILE     Current profile JSON (from profile-hooks.sh)
  --output FILE      Write output to FILE instead of stdout
  --format FMT       Output format: markdown (default) or json
  --help             Show this help message
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="${2:?--baseline requires a value}"; shift 2 ;;
    --current)  CURRENT="${2:?--current requires a value}"; shift 2 ;;
    --output)   OUTPUT="${2:?--output requires a value}"; shift 2 ;;
    --format)   FORMAT="${2:?--format requires a value}"; shift 2 ;;
    --help)     usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Validate required args
if [[ -z "$BASELINE" || -z "$CURRENT" ]]; then
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

if [[ "$FORMAT" != "markdown" && "$FORMAT" != "json" ]]; then
  echo "ERROR: Format must be 'markdown' or 'json'." >&2
  exit 1
fi

# Check required tools
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found in PATH." >&2
  exit 1
fi

main() {
  local baseline_hooks current_hooks
  baseline_hooks=$(jq '.hooks' "$BASELINE")
  current_hooks=$(jq '.hooks' "$CURRENT")

  # Build keyed lookup objects using jq
  local baseline_map current_map
  baseline_map=$(echo "$baseline_hooks" | jq 'map({key: (.event + "|" + (.matcher // "") + "|" + .command), value: .}) | from_entries')
  current_map=$(echo "$current_hooks" | jq 'map({key: (.event + "|" + (.matcher // "") + "|" + .command), value: .}) | from_entries')

  # Get all unique keys via jq
  local all_keys_json
  all_keys_json=$(jq -n --argjson b "$baseline_map" --argjson c "$current_map" '[$b | keys[], $c | keys[]] | unique')

  local matched_hooks="[]"
  local added_hooks="[]"
  local removed_hooks="[]"

  local key_count
  key_count=$(echo "$all_keys_json" | jq 'length')

  for (( ki=0; ki<key_count; ki++ )); do
    local key
    key=$(echo "$all_keys_json" | jq -r ".[$ki]")
    [[ -z "$key" ]] && continue

    local b_data c_data
    b_data=$(echo "$baseline_map" | jq --arg k "$key" '.[$k] // null')
    c_data=$(echo "$current_map" | jq --arg k "$key" '.[$k] // null')

    if [[ "$b_data" == "null" ]]; then
      # Added hook
      added_hooks=$(echo "$added_hooks" | jq --argjson h "$c_data" '. + [$h]')
    elif [[ "$c_data" == "null" ]]; then
      # Removed hook
      removed_hooks=$(echo "$removed_hooks" | jq --argjson h "$b_data" '. + [$h]')
    else
      # Matched - compute delta
      local b_mean b_median c_mean c_median
      b_mean=$(echo "$b_data" | jq '.mean_ms')
      b_median=$(echo "$b_data" | jq '.median_ms')
      c_mean=$(echo "$c_data" | jq '.mean_ms')
      c_median=$(echo "$c_data" | jq '.median_ms')

      local delta_mean delta_median pct_change
      delta_mean=$(echo "$c_mean - $b_mean" | bc -l 2>/dev/null || echo "0")
      delta_median=$(echo "$c_median - $b_median" | bc -l 2>/dev/null || echo "0")

      if (( $(echo "$b_median != 0" | bc -l 2>/dev/null || echo "0") )); then
        pct_change=$(printf "%.0f" "$(echo "($delta_median / $b_median) * 100" | bc -l 2>/dev/null || echo "0")")
      else
        pct_change=0
      fi

      matched_hooks=$(echo "$matched_hooks" | jq \
        --arg key "$key" \
        --argjson b_median "$b_median" \
        --argjson c_median "$c_median" \
        --argjson delta_median "$(printf "%.2f" "$delta_median")" \
        --argjson pct "$pct_change" \
        --argjson b_mean "$b_mean" \
        --argjson c_mean "$c_mean" \
        --argjson delta_mean "$(printf "%.2f" "$delta_mean")" \
        --arg b_status "$(echo "$b_data" | jq -r '.status')" \
        --arg c_status "$(echo "$c_data" | jq -r '.status')" \
        '. + [{
          key: $key,
          baseline_median_ms: $b_median,
          current_median_ms: $c_median,
          delta_median_ms: $delta_median,
          pct_change: $pct,
          baseline_mean_ms: $b_mean,
          current_mean_ms: $c_mean,
          delta_mean_ms: $delta_mean,
          baseline_status: $b_status,
          current_status: $c_status
        }]')
    fi
  done

  # Compute summary stats
  local baseline_total current_total
  baseline_total=$(jq '.summary.mean_total_ms // 0' "$BASELINE")
  current_total=$(jq '.summary.mean_total_ms // 0' "$CURRENT")
  local total_delta total_pct
  total_delta=$((current_total - baseline_total))
  if [[ "$baseline_total" -ne 0 ]]; then
    total_pct=$(printf "%.0f" "$(echo "($total_delta * 100) / $baseline_total" | bc -l 2>/dev/null || echo "0")")
  else
    total_pct=0
  fi

  local baseline_slow current_slow
  baseline_slow=$(jq '.summary.slow_hooks // 0' "$BASELINE")
  current_slow=$(jq '.summary.slow_hooks // 0' "$CURRENT")

  local added_count removed_count match_count
  added_count=$(echo "$added_hooks" | jq 'length')
  removed_count=$(echo "$removed_hooks" | jq 'length')
  match_count=$(echo "$matched_hooks" | jq 'length')

  if [[ "$FORMAT" == "json" ]]; then
    local result
    result=$(jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg baseline_file "$BASELINE" \
      --arg current_file "$CURRENT" \
      --argjson matched "$matched_hooks" \
      --argjson added "$added_hooks" \
      --argjson removed "$removed_hooks" \
      --argjson baseline_total "$baseline_total" \
      --argjson current_total "$current_total" \
      --argjson total_delta "$total_delta" \
      --argjson total_pct "$total_pct" \
      --argjson baseline_slow "$baseline_slow" \
      --argjson current_slow "$current_slow" \
      --argjson added_count "$added_count" \
      --argjson removed_count "$removed_count" \
      '{
        collected_at: $ts,
        baseline_file: $baseline_file,
        current_file: $current_file,
        matched_hooks: $matched,
        added_hooks: $added,
        removed_hooks: $removed,
        summary: {
          baseline_total_ms: $baseline_total,
          current_total_ms: $current_total,
          delta_total_ms: $total_delta,
          delta_total_pct: $total_pct,
          baseline_slow_hooks: $baseline_slow,
          current_slow_hooks: $current_slow,
          hooks_added: $added_count,
          hooks_removed: $removed_count
        }
      }')

    if [[ -n "$OUTPUT" ]]; then
      echo "$result" | jq . > "$OUTPUT"
      echo >&2 "JSON output written to $OUTPUT"
    else
      echo "$result" | jq .
    fi

  else
    # Markdown format
    local md=""

    md+="## Hook Profile Comparison"$'\n\n'

    # Table header
    md+="| Hook (event -> matcher) | Baseline (median ms) | Current (median ms) | Delta | % Change |"$'\n'
    md+="|------------------------|---------------------|---------------------|-------|----------|"$'\n'

    # Table rows for matched hooks
    for (( i=0; i<match_count; i++ )); do
      local key b_med c_med delta pct
      key=$(echo "$matched_hooks" | jq -r ".[$i].key")
      b_med=$(echo "$matched_hooks" | jq ".[$i].baseline_median_ms")
      c_med=$(echo "$matched_hooks" | jq ".[$i].current_median_ms")
      delta=$(echo "$matched_hooks" | jq ".[$i].delta_median_ms")
      pct=$(echo "$matched_hooks" | jq ".[$i].pct_change")

      # Parse key into readable form
      local event matcher
      event=$(echo "$key" | cut -d'|' -f1)
      matcher=$(echo "$key" | cut -d'|' -f2)
      [[ -z "$matcher" ]] && matcher="(all)"

      local sign=""
      if (( $(echo "$delta > 0" | bc -l 2>/dev/null || echo "0") )); then
        sign="+"
      fi

      md+="| ${event} -> ${matcher} | ${b_med} | ${c_med} | ${sign}${delta} | ${sign}${pct}% |"$'\n'
    done

    md+=$'\n'

    # Configuration changes
    md+="### Configuration Changes"$'\n'

    if [[ "$removed_count" -gt 0 ]]; then
      md+="- Hooks removed: ${removed_count}"
      for (( i=0; i<removed_count; i++ )); do
        local r_event r_matcher r_median
        r_event=$(echo "$removed_hooks" | jq -r ".[$i].event")
        r_matcher=$(echo "$removed_hooks" | jq -r ".[$i].matcher // \"empty matcher\"")
        r_median=$(echo "$removed_hooks" | jq ".[$i].median_ms")
        [[ -z "$r_matcher" ]] && r_matcher="empty matcher"
        md+=" (${r_event} -> ${r_matcher}, was ${r_median}ms)"
      done
      md+=$'\n'
    else
      md+="- Hooks removed: 0"$'\n'
    fi

    if [[ "$added_count" -gt 0 ]]; then
      md+="- Hooks added: ${added_count}"
      for (( i=0; i<added_count; i++ )); do
        local a_event a_matcher
        a_event=$(echo "$added_hooks" | jq -r ".[$i].event")
        a_matcher=$(echo "$added_hooks" | jq -r ".[$i].matcher // \"(all)\"")
        [[ -z "$a_matcher" ]] && a_matcher="(all)"
        md+=" (${a_event} -> ${a_matcher})"
      done
      md+=$'\n'
    else
      md+="- Hooks added: 0"$'\n'
    fi

    md+=$'\n'

    # Summary
    md+="### Summary"$'\n'
    local sign=""
    if [[ "$total_delta" -gt 0 ]]; then sign="+"; fi
    md+="- Total hook invocation overhead: ${baseline_total}ms -> ${current_total}ms (${sign}${total_pct}%)"$'\n'
    md+="- Slow hooks (>500ms): ${baseline_slow} -> ${current_slow}"$'\n'

    if [[ -n "$OUTPUT" ]]; then
      echo "$md" > "$OUTPUT"
      echo >&2 "Markdown output written to $OUTPUT"
    else
      echo "$md"
    fi
  fi

  # Human summary to stderr
  echo >&2 ""
  echo >&2 "=== Profile Comparison Summary ==="
  echo >&2 "Baseline total: ${baseline_total}ms | Current total: ${current_total}ms | Delta: ${total_delta}ms (${total_pct}%)"
  echo >&2 "Hooks matched: $match_count | Added: $added_count | Removed: $removed_count"
  echo >&2 "Slow hooks: $baseline_slow -> $current_slow"
  echo >&2 ""
}

main
