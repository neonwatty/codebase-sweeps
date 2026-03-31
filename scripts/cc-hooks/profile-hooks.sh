#!/usr/bin/env bash
set -euo pipefail

# profile-hooks.sh - Profile all configured Claude Code hooks for execution time.
# Outputs structured JSON to stdout; human-readable summaries to stderr.

ITERATIONS=5
OUTPUT=""

usage() {
  cat >&2 <<'EOF'
Usage: profile-hooks.sh [--iterations N] [--output FILE] [--help]

Profile all configured Claude Code hooks for execution time.

Options:
  --iterations N   Number of profiling iterations per hook (default: 5)
  --output FILE    Write JSON output to FILE instead of stdout
  --help           Show this help message
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="${2:?--iterations requires a value}"; shift 2 ;;
    --output)     OUTPUT="${2:?--output requires a value}"; shift 2 ;;
    --help)       usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Check required tools
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found in PATH." >&2
  exit 1
fi

# Utility: compute stats from a file of numbers (one per line)
compute_stats() {
  local file="$1"
  jq -s '{
    mean: (add / length | . * 100 | round / 100),
    median: (sort | if length % 2 == 0 then (.[length/2 - 1] + .[length/2]) / 2 else .[length/2 | floor] end | . * 100 | round / 100),
    min: min,
    max: max,
    stddev: (if length <= 1 then 0 else ((map(. as $x | ($x - (add / length)) | . * .) | add) / (length - 1)) | sqrt | . * 100 | round / 100 end)
  }' < "$file"
}

# Utility: create synthetic input for a given event type
synthetic_input() {
  local event="$1"
  local matcher="$2"
  local tool_name="${matcher:-Bash}"

  case "$event" in
    PreToolUse)
      jq -n --arg tool "$tool_name" '{
        tool_name: $tool,
        tool_input: {command: "echo hello"}
      }'
      ;;
    PostToolUse)
      jq -n --arg tool "$tool_name" '{
        tool_name: $tool,
        tool_input: {command: "echo hello"},
        tool_result: {stdout: "hello", exit_code: 0}
      }'
      ;;
    Notification)
      jq -n '{title: "Test", message: "test notification"}'
      ;;
    Stop)
      jq -n '{stop_reason: "end_turn", message: "Done"}'
      ;;
    SubagentStop)
      jq -n '{stop_reason: "end_turn", message: "Subagent done"}'
      ;;
    *)
      jq -n '{}'
      ;;
  esac
}

# Collect hooks from settings files
collect_hooks_from_settings() {
  local settings_files=()
  local home_settings="$HOME/.claude/settings.json"
  local project_settings=".claude/settings.json"
  local local_settings=".claude/settings.local.json"

  for f in "$home_settings" "$project_settings" "$local_settings"; do
    [[ -f "$f" ]] && settings_files+=("$f")
  done

  if [[ ${#settings_files[@]} -eq 0 ]]; then
    echo "[]"
    return
  fi

  local hooks_json="[]"

  for f in "${settings_files[@]}"; do
    # Extract hooks object - iterate over event types
    local events
    events=$(jq -r '.hooks // {} | keys[]' "$f" 2>/dev/null || true)
    for event in $events; do
      local count
      count=$(jq -r ".hooks[\"$event\"] | length" "$f" 2>/dev/null || echo "0")
      for (( i=0; i<count; i++ )); do
        local hook_type
        hook_type=$(jq -r ".hooks[\"$event\"][$i] | if .command then \"command\" elif .url then \"http\" elif .prompt then \"prompt\" elif .agent then \"agent\" else \"unknown\" end" "$f" 2>/dev/null || echo "unknown")

        # Only profile command hooks
        if [[ "$hook_type" != "command" ]]; then
          continue
        fi

        local matcher command_str
        matcher=$(jq -r ".hooks[\"$event\"][$i].matcher // \"\"" "$f" 2>/dev/null || echo "")
        command_str=$(jq -r ".hooks[\"$event\"][$i].command" "$f" 2>/dev/null || echo "")

        hooks_json=$(echo "$hooks_json" | jq \
          --arg event "$event" \
          --arg matcher "$matcher" \
          --arg command "$command_str" \
          --arg source "$f" \
          '. + [{event: $event, matcher: $matcher, command: $command, source: $source}]')
      done
    done
  done

  echo "$hooks_json"
}

# Run profiling with claudekit
profile_with_claudekit() {
  local raw
  raw=$(claudekit-hooks profile --iterations "$ITERATIONS" 2>/dev/null)
  echo "$raw" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson iter "$ITERATIONS" '{
    collected_at: $ts,
    tool: "claudekit",
    iterations: $iter,
    hooks: .hooks,
    summary: .summary
  }'
}

# Run manual profiling
profile_manually() {
  local hooks_json
  hooks_json=$(collect_hooks_from_settings)

  local hook_count
  hook_count=$(echo "$hooks_json" | jq 'length')

  if [[ "$hook_count" -eq 0 ]]; then
    echo >&2 "No command hooks found in settings files."
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson iter "$ITERATIONS" '{
      collected_at: $ts,
      tool: "manual",
      iterations: $iter,
      hooks: [],
      summary: {total_hooks: 0, slow_hooks: 0, error_hooks: 0, mean_total_ms: 0}
    }'
    return
  fi

  local results="[]"
  local slow_count=0
  local error_count=0
  local total_mean=0

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" EXIT

  for (( h=0; h<hook_count; h++ )); do
    local event matcher command_str
    event=$(echo "$hooks_json" | jq -r ".[$h].event")
    matcher=$(echo "$hooks_json" | jq -r ".[$h].matcher")
    command_str=$(echo "$hooks_json" | jq -r ".[$h].command")

    echo >&2 "Profiling: $event -> ${matcher:-'(all)'} [$command_str] ($ITERATIONS iterations)"

    local times_file="$tmpdir/times_$h.json"
    echo -n "" > "$times_file"
    local had_error=false

    local input
    input=$(synthetic_input "$event" "$matcher")

    for (( i=0; i<ITERATIONS; i++ )); do
      local start_ns end_ns elapsed_ms
      start_ns=$(date +%s%N)

      if echo "$input" | bash -c "$command_str" >/dev/null 2>/dev/null; then
        end_ns=$(date +%s%N)
        elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
        echo "$elapsed_ms" >> "$times_file"
      else
        end_ns=$(date +%s%N)
        elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
        echo "$elapsed_ms" >> "$times_file"
        had_error=true
      fi
    done

    local line_count
    line_count=$(wc -l < "$times_file" | tr -d ' ')

    if [[ "$line_count" -eq 0 ]]; then
      results=$(echo "$results" | jq \
        --arg event "$event" \
        --arg matcher "$matcher" \
        --arg command "$command_str" \
        '. + [{
          event: $event,
          matcher: $matcher,
          command: $command,
          mean_ms: 0, median_ms: 0, min_ms: 0, max_ms: 0, stddev_ms: 0,
          status: "error"
        }]')
      error_count=$((error_count + 1))
      continue
    fi

    local stats
    stats=$(compute_stats "$times_file")

    local mean_val median_val min_val max_val stddev_val status
    mean_val=$(echo "$stats" | jq '.mean')
    median_val=$(echo "$stats" | jq '.median')
    min_val=$(echo "$stats" | jq '.min')
    max_val=$(echo "$stats" | jq '.max')
    stddev_val=$(echo "$stats" | jq '.stddev')

    if [[ "$had_error" == true ]]; then
      status="error"
      error_count=$((error_count + 1))
    elif (( $(echo "$median_val > 500" | bc -l 2>/dev/null || echo 0) )); then
      status="slow"
      slow_count=$((slow_count + 1))
    else
      status="ok"
    fi

    total_mean=$(echo "$total_mean + $mean_val" | bc -l 2>/dev/null || echo "$total_mean")

    results=$(echo "$results" | jq \
      --arg event "$event" \
      --arg matcher "$matcher" \
      --arg command "$command_str" \
      --argjson mean "$mean_val" \
      --argjson median "$median_val" \
      --argjson min "$min_val" \
      --argjson max "$max_val" \
      --argjson stddev "$stddev_val" \
      --arg status "$status" \
      '. + [{
        event: $event,
        matcher: $matcher,
        command: $command,
        mean_ms: $mean,
        median_ms: $median,
        min_ms: $min,
        max_ms: $max,
        stddev_ms: $stddev,
        status: $status
      }]')
  done

  # Round total_mean
  local mean_total_rounded
  mean_total_rounded=$(printf "%.0f" "$total_mean" 2>/dev/null || echo "0")

  # Build final JSON
  local final
  final=$(jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson iter "$ITERATIONS" \
    --argjson hooks "$results" \
    --argjson total "$hook_count" \
    --argjson slow "$slow_count" \
    --argjson errors "$error_count" \
    --argjson mean_total "$mean_total_rounded" \
    '{
      collected_at: $ts,
      tool: "manual",
      iterations: $iter,
      hooks: $hooks,
      summary: {
        total_hooks: $total,
        slow_hooks: $slow,
        error_hooks: $errors,
        mean_total_ms: $mean_total
      }
    }')

  # Print human summary to stderr
  echo >&2 ""
  echo >&2 "=== Hook Profile Summary ==="
  echo >&2 "Total hooks profiled: $hook_count"
  echo >&2 "Slow hooks (>500ms median): $slow_count"
  echo >&2 "Error hooks: $error_count"
  echo >&2 "Total mean overhead: ${mean_total_rounded}ms"
  echo >&2 ""

  echo "$final"
}

# Main
main() {
  local result

  if command -v claudekit-hooks &>/dev/null; then
    echo >&2 "Using claudekit for profiling..."
    result=$(profile_with_claudekit)
  else
    echo >&2 "claudekit not found, using manual profiling..."
    result=$(profile_manually)
  fi

  if [[ -n "$OUTPUT" ]]; then
    echo "$result" | jq . > "$OUTPUT"
    echo >&2 "Output written to $OUTPUT"
  else
    echo "$result" | jq .
  fi
}

main
