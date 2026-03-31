#!/usr/bin/env bash
set -euo pipefail

######################################################################
# benchmark-hooks.sh — Benchmark pre-commit / pre-push hook execution
# time using hyperfine (preferred) or a manual timing loop (fallback).
#
# Structured JSON goes to stdout; human summaries go to stderr.
######################################################################

# ── defaults ──────────────────────────────────────────────────────
HOOK="both"
RUNS=10
WARMUP=2
OUTPUT=""

# ── usage ─────────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Benchmark Git hook execution time.

Options:
  --hook   pre-commit|pre-push|both   Hook(s) to benchmark (default: both)
  --runs   N                          Number of timed runs (default: 10)
  --warmup N                          Warmup runs before timing (default: 2)
  --output FILE                       Write JSON output to FILE
  --help                              Show this help message
EOF
  exit 0
}

# ── parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hook)   HOOK="$2";   shift 2 ;;
    --runs)   RUNS="$2";   shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --help)   usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ── tool checks ───────────────────────────────────────────────────
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not found." >&2; exit 1; }; }
require git
require jq

USE_HYPERFINE=false
if command -v hyperfine >/dev/null 2>&1; then
  USE_HYPERFINE=true
fi

TOOL="manual"
$USE_HYPERFINE && TOOL="hyperfine"

# ── helpers ───────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
TMPDIR_BENCH="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BENCH"' EXIT

# Determine which hooks to benchmark
declare -a HOOKS_TO_BENCH
case "$HOOK" in
  both)       HOOKS_TO_BENCH=(pre-commit pre-push) ;;
  pre-commit) HOOKS_TO_BENCH=(pre-commit) ;;
  pre-push)   HOOKS_TO_BENCH=(pre-push) ;;
  *) echo "ERROR: --hook must be pre-commit, pre-push, or both" >&2; exit 1 ;;
esac

# Check whether a hook is configured
hook_exists() {
  local h="$1"
  # Husky hooks
  [[ -x "$REPO_ROOT/.husky/$h" ]] && return 0
  # core.hooksPath
  local hp
  hp="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [[ -n "$hp" ]] && [[ -x "$hp/$h" ]]; then return 0; fi
  # .git/hooks
  [[ -x "$REPO_ROOT/.git/hooks/$h" ]] && return 0
  return 1
}

# Stage a dummy file so lint-staged has work to do
DUMMY_FILE="$REPO_ROOT/.benchmark-hooks-dummy-$$.ts"
stage_dummy() {
  echo "// benchmark dummy" > "$DUMMY_FILE"
  git -C "$REPO_ROOT" add "$DUMMY_FILE" 2>/dev/null || true
}
unstage_dummy() {
  git -C "$REPO_ROOT" reset HEAD -- "$DUMMY_FILE" 2>/dev/null || true
  rm -f "$DUMMY_FILE"
}

# ── manual timing helpers ─────────────────────────────────────────
compute_stats() {
  # reads newline-separated floats from stdin, outputs JSON object
  jq -R -s '
    split("\n") | map(select(length > 0) | tonumber) |
    sort |
    {
      count: length,
      mean_s:   ((add / length) * 1000 | round / 1000),
      min_s:    (.[0]            * 1000 | round / 1000),
      max_s:    (.[-1]           * 1000 | round / 1000),
      median_s: (if length % 2 == 0 then
                   ((.[length/2 - 1] + .[length/2]) / 2)
                 else
                   .[((length - 1) / 2) | floor]
                 end * 1000 | round / 1000),
      stddev_s: (if length < 2 then 0
                 else
                   (
                     ((map(. - (add / length) | . * .) | add) / (length - 1)) | sqrt
                   ) * 1000 | round / 1000
                 end)
    }
  '
}

# ── benchmark one hook ────────────────────────────────────────────
benchmark_hook() {
  local h="$1"
  echo "  Benchmarking $h ..." >&2

  if ! hook_exists "$h"; then
    echo '{"status":"not_configured"}' | jq --argjson runs "$RUNS" '. + {runs: $runs}'
    return
  fi

  # Stage dummy for pre-commit
  if [[ "$h" == "pre-commit" ]]; then
    stage_dummy
  fi

  local result
  if $USE_HYPERFINE; then
    local hf_json="$TMPDIR_BENCH/hf-$h.json"
    # hyperfine benchmark — allow non-zero exit from hook (some hooks fail on dummy files)
    if hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$hf_json" \
         --ignore-failure \
         "git hook run $h" 2>/dev/null; then
      result=$(jq '{
        status: "benchmarked",
        runs:      .results[0].times | length,
        mean_s:    (.results[0].mean   * 1000 | round / 1000),
        stddev_s:  (.results[0].stddev * 1000 | round / 1000),
        median_s:  (.results[0].median * 1000 | round / 1000),
        min_s:     (.results[0].min    * 1000 | round / 1000),
        max_s:     (.results[0].max    * 1000 | round / 1000)
      }' "$hf_json")
    else
      result='{"status":"error","runs":0,"mean_s":0,"stddev_s":0,"median_s":0,"min_s":0,"max_s":0}'
    fi
  else
    # Manual timing loop
    local timings_file="$TMPDIR_BENCH/timings-$h.txt"
    : > "$timings_file"

    # warmup
    for (( i=0; i<WARMUP; i++ )); do
      git hook run "$h" >/dev/null 2>&1 || true
    done

    # timed runs
    for (( i=0; i<RUNS; i++ )); do
      local t_start t_end dur
      t_start=$(date +%s%N)
      git hook run "$h" >/dev/null 2>&1 || true
      t_end=$(date +%s%N)
      dur=$(echo "scale=6; ($t_end - $t_start) / 1000000000" | bc)
      echo "$dur" >> "$timings_file"
    done

    local stats
    stats=$(compute_stats < "$timings_file")
    result=$(echo "$stats" | jq '{status: "benchmarked"} + .')
    result=$(echo "$result" | jq --argjson r "$RUNS" '.runs = $r | del(.count)')
  fi

  # Unstage dummy for pre-commit
  if [[ "$h" == "pre-commit" ]]; then
    unstage_dummy
  fi

  echo "$result"
}

# ── main ──────────────────────────────────────────────────────────
echo "hooks-audit: benchmark-hooks (tool=$TOOL, runs=$RUNS, warmup=$WARMUP)" >&2

COLLECTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build hooks JSON object
HOOKS_JSON="{}"
for h in "${HOOKS_TO_BENCH[@]}"; do
  hook_result="$(benchmark_hook "$h")"
  HOOKS_JSON=$(echo "$HOOKS_JSON" | jq --arg name "$h" --argjson data "$hook_result" '. + {($name): $data}')
done

FINAL_JSON=$(jq -n \
  --arg ts "$COLLECTED_AT" \
  --arg tool "$TOOL" \
  --argjson hooks "$HOOKS_JSON" \
  '{collected_at: $ts, tool: $tool, hooks: $hooks}')

if [[ -n "$OUTPUT" ]]; then
  echo "$FINAL_JSON" | jq . > "$OUTPUT"
  echo "  Results written to $OUTPUT" >&2
fi

echo "$FINAL_JSON" | jq .
echo "  Done." >&2
