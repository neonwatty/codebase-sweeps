#!/usr/bin/env bash
set -euo pipefail

# analyze-settings.sh - Parse Claude Code settings files and analyze hook
# configuration for optimization opportunities.
# Outputs structured JSON to stdout; human-readable summaries to stderr.

PROJECT_DIR="$(pwd)"
OUTPUT=""

usage() {
  cat >&2 <<'EOF'
Usage: analyze-settings.sh [--project-dir DIR] [--output FILE] [--help]

Analyze Claude Code hook settings for optimization opportunities.

Options:
  --project-dir DIR   Project directory to scan (default: current directory)
  --output FILE       Write JSON output to FILE instead of stdout
  --help              Show this help message
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:?--project-dir requires a value}"; shift 2 ;;
    --output)      OUTPUT="${2:?--output requires a value}"; shift 2 ;;
    --help)        usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Check required tools
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found in PATH." >&2
  exit 1
fi

# Resolve project dir to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# High-frequency events that fire often
HIGH_FREQ_EVENTS=("PreToolUse" "PostToolUse")

# Settings files to examine (in order)
declare -A SETTINGS_LABELS
GLOBAL_SETTINGS="$HOME/.claude/settings.json"
PROJECT_SETTINGS="$PROJECT_DIR/.claude/settings.json"
LOCAL_SETTINGS="$PROJECT_DIR/.claude/settings.local.json"

SETTINGS_LABELS["$GLOBAL_SETTINGS"]="global"
SETTINGS_LABELS["$PROJECT_SETTINGS"]="project"
SETTINGS_LABELS["$LOCAL_SETTINGS"]="local"

# Collect all hooks and produce findings
main() {
  local settings_files_json="[]"
  local all_hooks="[]"
  local findings="[]"
  local hook_index=0

  for settings_path in "$GLOBAL_SETTINGS" "$PROJECT_SETTINGS" "$LOCAL_SETTINGS"; do
    if [[ ! -f "$settings_path" ]]; then
      continue
    fi

    local label="${SETTINGS_LABELS[$settings_path]}"
    local display_path="$settings_path"

    # Count hooks in this file
    local file_hook_count
    file_hook_count=$(jq '[.hooks // {} | to_entries[] | .value | length] | add // 0' "$settings_path" 2>/dev/null || echo "0")

    settings_files_json=$(echo "$settings_files_json" | jq \
      --arg path "$display_path" \
      --argjson count "$file_hook_count" \
      '. + [{path: $path, hooks_count: $count}]')

    # Iterate over event types in this file
    local events
    events=$(jq -r '.hooks // {} | keys[]' "$settings_path" 2>/dev/null || true)

    for event in $events; do
      local count
      count=$(jq -r ".hooks[\"$event\"] | length" "$settings_path" 2>/dev/null || echo "0")

      for (( i=0; i<count; i++ )); do
        local hook_json
        hook_json=$(jq ".hooks[\"$event\"][$i]" "$settings_path" 2>/dev/null)

        # Determine hook type
        local hook_type
        hook_type=$(echo "$hook_json" | jq -r 'if .command then "command" elif .url then "http" elif .prompt then "prompt" elif .agent then "agent" else "unknown" end')

        local matcher if_filter timeout_val is_async command_val status_message
        matcher=$(echo "$hook_json" | jq -r '.matcher // ""')
        if_filter=$(echo "$hook_json" | jq '.if // null')
        timeout_val=$(echo "$hook_json" | jq '.timeout // null')
        is_async=$(echo "$hook_json" | jq '.async // false')
        status_message=$(echo "$hook_json" | jq -r '.statusMessage // ""')

        # Get the actual command/url/prompt
        case "$hook_type" in
          command)  command_val=$(echo "$hook_json" | jq -r '.command // ""') ;;
          http)     command_val=$(echo "$hook_json" | jq -r '.url // ""') ;;
          prompt)   command_val=$(echo "$hook_json" | jq -r '.prompt // ""') ;;
          agent)    command_val=$(echo "$hook_json" | jq -r '.agent // ""') ;;
          *)        command_val="" ;;
        esac

        # Add to hooks array
        all_hooks=$(echo "$all_hooks" | jq \
          --arg source "$label" \
          --arg event "$event" \
          --arg matcher "$matcher" \
          --argjson if_filter "$if_filter" \
          --arg type "$hook_type" \
          --arg command "$command_val" \
          --argjson timeout "$timeout_val" \
          --argjson async "$is_async" \
          '. + [{
            source: $source,
            event: $event,
            matcher: $matcher,
            if_filter: $if_filter,
            type: $type,
            command: $command,
            timeout: $timeout,
            async: $async
          }]')

        # --- Analyze findings ---

        # HIGH: Empty matcher on high-frequency events
        is_high_freq=false
        for hf in "${HIGH_FREQ_EVENTS[@]}"; do
          [[ "$event" == "$hf" ]] && is_high_freq=true
        done

        if [[ "$is_high_freq" == true && -z "$matcher" ]]; then
          findings=$(echo "$findings" | jq \
            --argjson idx "$hook_index" \
            --arg event "$event" \
            '. + [{
              severity: "HIGH",
              hook_index: $idx,
              message: ("Empty matcher on " + $event + " fires on every tool call. Scope to specific tools."),
              recommendation: "Add matcher like '\''Bash|Edit|Write'\'' to limit invocations"
            }]')
        fi

        # HIGH: No explicit timeout on command hooks
        if [[ "$hook_type" == "command" && "$timeout_val" == "null" ]]; then
          findings=$(echo "$findings" | jq \
            --argjson idx "$hook_index" \
            '. + [{
              severity: "HIGH",
              hook_index: $idx,
              message: "No explicit timeout set (defaults to 600s for command hooks - risk of hanging).",
              recommendation: "Set timeout to a reasonable value, e.g. 10000 (10s) or 30000 (30s)"
            }]')
        fi

        # HIGH: Prompt or agent hook on PreToolUse
        if [[ "$event" == "PreToolUse" && ( "$hook_type" == "prompt" || "$hook_type" == "agent" ) ]]; then
          findings=$(echo "$findings" | jq \
            --argjson idx "$hook_index" \
            --arg type "$hook_type" \
            '. + [{
              severity: "HIGH",
              hook_index: $idx,
              message: ("Using " + $type + " hook type on PreToolUse causes an expensive LLM call blocking every tool invocation."),
              recommendation: "Convert to a command hook or move to a less frequent event"
            }]')
        fi

        # MEDIUM: Hook could use if filter but doesn't
        if [[ "$is_high_freq" == true && -n "$matcher" && "$if_filter" == "null" ]]; then
          findings=$(echo "$findings" | jq \
            --argjson idx "$hook_index" \
            --arg matcher "$matcher" \
            '. + [{
              severity: "MEDIUM",
              hook_index: $idx,
              message: ("Hook matches " + $matcher + " but has no if filter for argument-level filtering."),
              recommendation: "Add an if filter to further scope when the hook fires, e.g. filter by command pattern"
            }]')
        fi

        # MEDIUM: Synchronous hook that could be async
        if [[ "$is_async" == "false" && "$hook_type" == "command" && "$event" == "PostToolUse" ]]; then
          findings=$(echo "$findings" | jq \
            --argjson idx "$hook_index" \
            '. + [{
              severity: "MEDIUM",
              hook_index: $idx,
              message: "Synchronous command hook on PostToolUse could potentially run asynchronously.",
              recommendation: "If this hook does not need to block execution, set async: true"
            }]')
        fi

        # LOW: Missing statusMessage
        if [[ -z "$status_message" && "$hook_type" == "command" ]]; then
          findings=$(echo "$findings" | jq \
            --argjson idx "$hook_index" \
            '. + [{
              severity: "LOW",
              hook_index: $idx,
              message: "Missing statusMessage - user gets no feedback during slow hooks.",
              recommendation: "Add a statusMessage like \"Running validation...\" for user visibility"
            }]')
        fi

        # LOW: Hook script not found at specified path (for command hooks)
        if [[ "$hook_type" == "command" ]]; then
          # Extract the first word as potential script path
          local script_path
          script_path=$(echo "$command_val" | awk '{print $1}')
          if [[ "$script_path" == ./* || "$script_path" == /* ]]; then
            local resolved_path="$script_path"
            [[ "$script_path" == ./* ]] && resolved_path="$PROJECT_DIR/$script_path"
            if [[ ! -f "$resolved_path" ]]; then
              findings=$(echo "$findings" | jq \
                --argjson idx "$hook_index" \
                --arg path "$script_path" \
                '. + [{
                  severity: "LOW",
                  hook_index: $idx,
                  message: ("Hook script not found at specified path: " + $path),
                  recommendation: "Verify the script exists and the path is correct"
                }]')
            fi
          fi
        fi

        hook_index=$((hook_index + 1))
      done
    done
  done

  # Check for MEDIUM: Duplicate or near-duplicate commands across events
  local dup_commands
  dup_commands=$(echo "$all_hooks" | jq -r '[.[] | .command] | group_by(.) | map(select(length > 1)) | .[0] // empty | .[0]' 2>/dev/null || true)
  if [[ -n "$dup_commands" ]]; then
    # Find indices of duplicate commands
    local dup_indices
    dup_indices=$(echo "$all_hooks" | jq -r --arg cmd "$dup_commands" '[to_entries[] | select(.value.command == $cmd) | .key] | join(", ")')
    findings=$(echo "$findings" | jq \
      --arg cmd "$dup_commands" \
      --arg indices "$dup_indices" \
      '. + [{
        severity: "MEDIUM",
        hook_index: -1,
        message: ("Duplicate hook command found across multiple events: " + $cmd + " (indices: " + $indices + ")"),
        recommendation: "Consider consolidating duplicate hooks or verifying they serve distinct purposes"
      }]')
  fi

  # Build summary
  local total_hooks hooks_without_timeout hooks_without_matcher hooks_without_if
  local findings_high findings_medium findings_low

  total_hooks=$(echo "$all_hooks" | jq 'length')
  hooks_without_timeout=$(echo "$all_hooks" | jq '[.[] | select(.type == "command" and .timeout == null)] | length')
  hooks_without_matcher=$(echo "$all_hooks" | jq '[.[] | select(.matcher == "")] | length')
  hooks_without_if=$(echo "$all_hooks" | jq '[.[] | select(.if_filter == null)] | length')
  findings_high=$(echo "$findings" | jq '[.[] | select(.severity == "HIGH")] | length')
  findings_medium=$(echo "$findings" | jq '[.[] | select(.severity == "MEDIUM")] | length')
  findings_low=$(echo "$findings" | jq '[.[] | select(.severity == "LOW")] | length')

  local result
  result=$(jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project_dir "$PROJECT_DIR" \
    --argjson settings_files "$settings_files_json" \
    --argjson hooks "$all_hooks" \
    --argjson findings "$findings" \
    --argjson total "$total_hooks" \
    --argjson no_timeout "$hooks_without_timeout" \
    --argjson no_matcher "$hooks_without_matcher" \
    --argjson no_if "$hooks_without_if" \
    --argjson f_high "$findings_high" \
    --argjson f_medium "$findings_medium" \
    --argjson f_low "$findings_low" \
    '{
      collected_at: $ts,
      project_dir: $project_dir,
      settings_files: $settings_files,
      hooks: $hooks,
      findings: $findings,
      summary: {
        total_hooks: $total,
        hooks_without_timeout: $no_timeout,
        hooks_without_matcher: $no_matcher,
        hooks_without_if_filter: $no_if,
        findings_high: $f_high,
        findings_medium: $f_medium,
        findings_low: $f_low
      }
    }')

  # Print human summary to stderr
  echo >&2 ""
  echo >&2 "=== Hook Settings Analysis ==="
  echo >&2 "Project: $PROJECT_DIR"
  echo >&2 "Total hooks: $total_hooks"
  echo >&2 "Without explicit timeout: $hooks_without_timeout"
  echo >&2 "Without matcher: $hooks_without_matcher"
  echo >&2 "Without if filter: $hooks_without_if"
  echo >&2 ""
  echo >&2 "Findings:"
  echo >&2 "  HIGH:   $findings_high"
  echo >&2 "  MEDIUM: $findings_medium"
  echo >&2 "  LOW:    $findings_low"
  echo >&2 ""

  if [[ -n "$OUTPUT" ]]; then
    echo "$result" | jq . > "$OUTPUT"
    echo >&2 "Output written to $OUTPUT"
  else
    echo "$result" | jq .
  fi
}

main
