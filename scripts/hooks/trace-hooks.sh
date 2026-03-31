#!/usr/bin/env bash
set -euo pipefail

######################################################################
# trace-hooks.sh — Run GIT_TRACE2_PERF to capture a detailed timing
# breakdown of git hook execution.
#
# Structured JSON goes to stdout; human summaries go to stderr.
######################################################################

# ── defaults ──────────────────────────────────────────────────────
HOOK="both"
OUTPUT=""

# ── usage ─────────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Trace Git hook execution using GIT_TRACE2_PERF.

Options:
  --hook   pre-commit|pre-push|both   Hook(s) to trace (default: both)
  --output FILE                       Write JSON output to FILE
  --help                              Show this help message
EOF
  exit 0
}

# ── parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hook)   HOOK="$2";   shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --help)   usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ── tool checks ───────────────────────────────────────────────────
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not found." >&2; exit 1; }; }
require git
require jq

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMPDIR_TRACE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TRACE"' EXIT

# ── which hooks ───────────────────────────────────────────────────
declare -a HOOKS_TO_TRACE
case "$HOOK" in
  both)       HOOKS_TO_TRACE=(pre-commit pre-push) ;;
  pre-commit) HOOKS_TO_TRACE=(pre-commit) ;;
  pre-push)   HOOKS_TO_TRACE=(pre-push) ;;
  *) echo "ERROR: --hook must be pre-commit, pre-push, or both" >&2; exit 1 ;;
esac

# ── helpers ───────────────────────────────────────────────────────
hook_exists() {
  local h="$1"
  [[ -x "$REPO_ROOT/.husky/$h" ]] && return 0
  local hp
  hp="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [[ -n "$hp" ]] && [[ -x "$hp/$h" ]]; then return 0; fi
  [[ -x "$REPO_ROOT/.git/hooks/$h" ]] && return 0
  return 1
}

DUMMY_FILE="$REPO_ROOT/.trace-hooks-dummy-$$.ts"
stage_dummy() {
  echo "// trace dummy" > "$DUMMY_FILE"
  git -C "$REPO_ROOT" add "$DUMMY_FILE" 2>/dev/null || true
}
unstage_dummy() {
  git -C "$REPO_ROOT" reset HEAD -- "$DUMMY_FILE" 2>/dev/null || true
  rm -f "$DUMMY_FILE"
}

# ── parse trace log ──────────────────────────────────────────────
# GIT_TRACE2_PERF output is tab-separated with fields:
#   <time> <file>:<line> | <thread> | <event> | <repo> | <elapsed> | <category> | <data>
# We extract child_start / child_exit / region_enter / region_leave events
# and build a phases array.
parse_trace() {
  local trace_file="$1"
  local hook_name="$2"

  # Use awk to extract timing events, then jq to structure
  awk -F'|' '
  {
    # trim whitespace from fields
    for (i=1; i<=NF; i++) {
      gsub(/^[ \t]+|[ \t]+$/, "", $i)
    }
    event = $3
    elapsed = $4
    category = $5
    data = $6

    # Clean up elapsed: remove leading/trailing spaces, convert to number
    gsub(/^[ \t]+|[ \t]+$/, "", elapsed)

    if (event == "child_start") {
      # data contains the command being spawned
      gsub(/^[ \t]+|[ \t]+$/, "", data)
      # Remove argv:[] wrapper if present
      cmd = data
      gsub(/^\[/, "", cmd)
      gsub(/\]$/, "", cmd)
      print "child_start|" elapsed "|" cmd
    }
    else if (event == "child_exit") {
      gsub(/^[ \t]+|[ \t]+$/, "", data)
      print "child_exit|" elapsed "|" data
    }
    else if (event == "region_enter" || event == "region_leave") {
      gsub(/^[ \t]+|[ \t]+$/, "", data)
      print event "|" elapsed "|" category ":" data
    }
    else if (event == "exit") {
      print "exit|" elapsed "|"
    }
  }
  ' "$trace_file" | jq -R -s --arg hook "$hook_name" '
    split("\n") | map(select(length > 0)) |
    # parse each line into {event, elapsed, detail}
    map(split("|") | {event: .[0], elapsed: .[1], detail: .[2]}) |

    # Convert elapsed strings like "0.123456" to milliseconds
    # Some lines may have non-numeric elapsed values — skip those
    map(
      (.elapsed | gsub("[ \t]"; "")) as $e |
      if ($e | test("^[0-9]")) then
        .elapsed_ms = (($e | tonumber) * 1000 | round)
      else
        .elapsed_ms = null
      end
    ) |

    # Build phases array
    . as $events |
    [
      {name: "hook_start", elapsed_ms: 0}
    ] +
    [
      $events[] |
      select(.event == "child_start" or .event == "child_exit") |
      select(.elapsed_ms != null) |
      {
        name: (.event + ":" + (.detail // "unknown")),
        elapsed_ms: .elapsed_ms
      }
    ] +
    (
      [$events[] | select(.event == "exit") | select(.elapsed_ms != null)] |
      if length > 0 then
        [{name: "hook_end", elapsed_ms: .[-1].elapsed_ms}]
      else
        []
      end
    ) |

    # Determine total_ms from hook_end or last event
    . as $phases |
    ([$phases[] | .elapsed_ms // 0] | max) as $total |
    {
      total_ms: $total,
      phases: $phases
    }
  '
}

# ── trace one hook ────────────────────────────────────────────────
trace_hook() {
  local h="$1"
  echo "  Tracing $h ..." >&2

  if ! hook_exists "$h"; then
    jq -n '{total_ms: 0, phases: [], status: "not_configured"}'
    return
  fi

  if [[ "$h" == "pre-commit" ]]; then
    stage_dummy
  fi

  local trace_log="$TMPDIR_TRACE/trace-$h.log"

  # Run the hook with GIT_TRACE2_PERF enabled
  GIT_TRACE2_PERF="$trace_log" git hook run "$h" >/dev/null 2>&1 || true

  if [[ "$h" == "pre-commit" ]]; then
    unstage_dummy
  fi

  if [[ ! -s "$trace_log" ]]; then
    jq -n '{total_ms: 0, phases: [], status: "no_trace_output"}'
    return
  fi

  local result
  result="$(parse_trace "$trace_log" "$h")"
  echo "$result"
}

# ── main ──────────────────────────────────────────────────────────
echo "hooks-audit: trace-hooks" >&2

COLLECTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

HOOKS_JSON="{}"
for h in "${HOOKS_TO_TRACE[@]}"; do
  hook_result="$(trace_hook "$h")"
  HOOKS_JSON=$(echo "$HOOKS_JSON" | jq --arg name "$h" --argjson data "$hook_result" '. + {($name): $data}')
done

FINAL_JSON=$(jq -n \
  --arg ts "$COLLECTED_AT" \
  --argjson hooks "$HOOKS_JSON" \
  '{collected_at: $ts, hooks: $hooks}')

if [[ -n "$OUTPUT" ]]; then
  echo "$FINAL_JSON" | jq . > "$OUTPUT"
  echo "  Results written to $OUTPUT" >&2
fi

echo "$FINAL_JSON" | jq .
echo "  Done." >&2
