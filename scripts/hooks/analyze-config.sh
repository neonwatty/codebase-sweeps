#!/usr/bin/env bash
set -euo pipefail

######################################################################
# analyze-config.sh — Analyze Git hook configuration and report on
# optimization opportunities.
#
# Structured JSON goes to stdout; human summaries go to stderr.
######################################################################

# ── defaults ──────────────────────────────────────────────────────
OUTPUT=""

# ── usage ─────────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze the current Git hook configuration and suggest optimizations.

Options:
  --output FILE   Write JSON output to FILE
  --help          Show this help message
EOF
  exit 0
}

# ── parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
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

echo "hooks-audit: analyze-config" >&2

# ── detect framework ─────────────────────────────────────────────
detect_framework() {
  if [[ -d "$REPO_ROOT/.husky" ]]; then
    echo "husky"
  elif [[ -f "$REPO_ROOT/lefthook.yml" ]] || [[ -f "$REPO_ROOT/lefthook.yaml" ]]; then
    echo "lefthook"
  elif [[ -f "$REPO_ROOT/.simple-git-hooks.json" ]] || \
       (jq -e '."simple-git-hooks"' "$REPO_ROOT/package.json" >/dev/null 2>&1); then
    echo "simple-git-hooks"
  elif [[ -d "$REPO_ROOT/.git/hooks" ]] && \
       find "$REPO_ROOT/.git/hooks" -maxdepth 1 -type f -executable ! -name '*.sample' | grep -q .; then
    echo "raw-git-hooks"
  else
    echo "none"
  fi
}

FRAMEWORK="$(detect_framework)"
echo "  Framework: $FRAMEWORK" >&2

# ── discover hooks ────────────────────────────────────────────────
# Returns JSON: { "pre-commit": { "commands": [...], "raw": "..." }, ... }
discover_hooks() {
  local hooks_json="{}"
  local hooks_dir=""

  case "$FRAMEWORK" in
    husky)
      hooks_dir="$REPO_ROOT/.husky"
      ;;
    raw-git-hooks)
      hooks_dir="$REPO_ROOT/.git/hooks"
      ;;
    lefthook|simple-git-hooks|none)
      # For lefthook / simple-git-hooks / none, we still check common locations
      if [[ -d "$REPO_ROOT/.husky" ]]; then
        hooks_dir="$REPO_ROOT/.husky"
      elif [[ -d "$REPO_ROOT/.git/hooks" ]]; then
        hooks_dir="$REPO_ROOT/.git/hooks"
      fi
      ;;
  esac

  # Also check core.hooksPath
  local custom_hooks_path
  custom_hooks_path="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [[ -n "$custom_hooks_path" ]]; then
    # Resolve relative path
    if [[ "$custom_hooks_path" != /* ]]; then
      custom_hooks_path="$REPO_ROOT/$custom_hooks_path"
    fi
    if [[ -d "$custom_hooks_path" ]]; then
      hooks_dir="$custom_hooks_path"
    fi
  fi

  if [[ -z "$hooks_dir" ]] || [[ ! -d "$hooks_dir" ]]; then
    echo "{}"
    return
  fi

  # Iterate over known hook names
  local hook_names=(pre-commit pre-push commit-msg prepare-commit-msg post-merge pre-rebase)
  for h in "${hook_names[@]}"; do
    local hook_file="$hooks_dir/$h"
    if [[ -f "$hook_file" ]]; then
      # Read hook contents, extract meaningful command lines
      local raw
      raw="$(cat "$hook_file")"
      local commands
      commands=$(echo "$raw" | grep -v '^\s*#' | grep -v '^\s*$' | grep -v '^#!/' | grep -v '^\. "' | grep -v '^set ' || true)

      # Build commands array
      local cmds_json="[]"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        cmds_json=$(echo "$cmds_json" | jq --arg c "$line" '. + [$c]')
      done <<< "$commands"

      # Estimate weight
      local weight="light"
      if echo "$commands" | grep -qiE '(npm test|npx jest|yarn test|vitest|mocha|npm run test)'; then
        weight="heavy"
      elif echo "$commands" | grep -qiE '(npm run build|tsc|typecheck|type-check)'; then
        weight="heavy"
      elif echo "$commands" | grep -qiE '(eslint|prettier|lint-staged)'; then
        weight="light"
      fi

      hooks_json=$(echo "$hooks_json" | jq \
        --arg name "$h" \
        --argjson cmds "$cmds_json" \
        --arg w "$weight" \
        '. + {($name): {commands: $cmds, estimated_weight: $w}}')
    fi
  done

  echo "$hooks_json"
}

HOOKS_JSON="$(discover_hooks)"

# ── parse lint-staged config ─────────────────────────────────────
parse_lint_staged() {
  local config_source=""
  local config_content=""

  # Check config sources in priority order
  if [[ -f "$REPO_ROOT/lint-staged.config.js" ]]; then
    config_source="lint-staged.config.js"
    config_content="$(cat "$REPO_ROOT/lint-staged.config.js")"
  elif [[ -f "$REPO_ROOT/lint-staged.config.mjs" ]]; then
    config_source="lint-staged.config.mjs"
    config_content="$(cat "$REPO_ROOT/lint-staged.config.mjs")"
  elif [[ -f "$REPO_ROOT/.lintstagedrc" ]]; then
    config_source=".lintstagedrc"
    config_content="$(cat "$REPO_ROOT/.lintstagedrc")"
  elif [[ -f "$REPO_ROOT/.lintstagedrc.json" ]]; then
    config_source=".lintstagedrc.json"
    config_content="$(cat "$REPO_ROOT/.lintstagedrc.json")"
  elif [[ -f "$REPO_ROOT/.lintstagedrc.yml" ]]; then
    config_source=".lintstagedrc.yml"
    config_content="$(cat "$REPO_ROOT/.lintstagedrc.yml")"
  elif [[ -f "$REPO_ROOT/package.json" ]] && \
       jq -e '."lint-staged"' "$REPO_ROOT/package.json" >/dev/null 2>&1; then
    config_source="package.json"
    config_content="$(jq '."lint-staged"' "$REPO_ROOT/package.json")"
  fi

  if [[ -z "$config_source" ]]; then
    jq -n '{config_source: "none", patterns: [], concurrent: null}'
    return
  fi

  echo "  lint-staged config: $config_source" >&2

  # Try to parse patterns from JSON config sources
  local patterns="[]"
  local concurrent=true

  case "$config_source" in
    .lintstagedrc.json|package.json)
      # These are straight JSON
      local json_config
      if [[ "$config_source" == "package.json" ]]; then
        json_config="$(jq '."lint-staged"' "$REPO_ROOT/package.json")"
      else
        json_config="$(cat "$REPO_ROOT/.lintstagedrc.json")"
      fi

      patterns=$(echo "$json_config" | jq '
        [to_entries[] | {
          glob: .key,
          commands: (if (.value | type) == "array" then .value
                     elif (.value | type) == "string" then [.value]
                     else [(.value | tostring)]
                     end)
        }]
      ' 2>/dev/null || echo "[]")
      ;;

    lint-staged.config.js|lint-staged.config.mjs|.lintstagedrc)
      # JS/MJS configs — best effort: extract quoted glob patterns and commands
      patterns=$(echo "$config_content" | grep -oE '"[^"]+"\s*:\s*\[?[^]]*\]?' | head -20 | \
        jq -R -s '
          split("\n") | map(select(length > 0)) |
          map(
            capture("\"(?<glob>[^\"]+)\"\\s*:\\s*(?<cmds>.*)") // null |
            select(. != null) |
            {
              glob: .glob,
              commands: (
                .cmds | gsub("^\\s*\\[?\\s*|\\s*\\]?\\s*$"; "") |
                split(",") | map(gsub("^\\s*\"|\"\\s*$"; "") | select(length > 0))
              )
            }
          )
        ' 2>/dev/null || echo "[]")
      ;;
  esac

  # Check for --concurrent flag in lint-staged invocation
  if echo "$HOOKS_JSON" | jq -r '.. | strings' 2>/dev/null | grep -q '\-\-concurrent'; then
    concurrent=true
  fi

  # Check for explicit concurrent: false in config
  if echo "$config_content" | grep -qiE 'concurrent\s*[:=]\s*false'; then
    concurrent=false
  fi

  jq -n \
    --arg src "$config_source" \
    --argjson pats "$patterns" \
    --argjson conc "$concurrent" \
    '{config_source: $src, patterns: $pats, concurrent: $conc}'
}

LINT_STAGED_JSON="$(parse_lint_staged)"

# ── produce findings ──────────────────────────────────────────────
generate_findings() {
  local findings="[]"

  # Helper to add a finding
  add_finding() {
    local sev="$1" msg="$2"
    findings=$(echo "$findings" | jq --arg s "$sev" --arg m "$msg" '. + [{severity: $s, message: $m}]')
  }

  # Check: test suite in pre-commit
  local pre_commit_cmds
  pre_commit_cmds="$(echo "$HOOKS_JSON" | jq -r '.["pre-commit"].commands[]? // empty' 2>/dev/null || true)"
  if echo "$pre_commit_cmds" | grep -qiE '(npm test|npx jest|yarn test|vitest|mocha|npm run test)'; then
    add_finding "HIGH" "Full test suite runs in pre-commit; should be pre-push or CI-only"
  fi

  # Check: typecheck in pre-commit
  if echo "$pre_commit_cmds" | grep -qiE '(tsc|typecheck|type-check)'; then
    add_finding "MEDIUM" "typecheck in pre-commit runs on all files, not just staged; consider moving to pre-push"
  fi

  # Check: build in pre-commit
  if echo "$pre_commit_cmds" | grep -qiE '(npm run build|yarn build|npx webpack|npx vite build)'; then
    add_finding "HIGH" "Build step runs in pre-commit; should be CI-only"
  fi

  # Check: heavy pre-push operations
  local pre_push_cmds
  pre_push_cmds="$(echo "$HOOKS_JSON" | jq -r '.["pre-push"].commands[]? // empty' 2>/dev/null || true)"
  if echo "$pre_push_cmds" | grep -qiE '(npm run build|yarn build)'; then
    add_finding "MEDIUM" "Build step in pre-push may slow down pushes; consider CI-only"
  fi

  # Check lint-staged patterns — eslint without --cache
  local ls_commands
  ls_commands="$(echo "$LINT_STAGED_JSON" | jq -r '.patterns[].commands[]? // empty' 2>/dev/null || true)"
  if echo "$ls_commands" | grep -q 'eslint' && ! echo "$ls_commands" | grep -q '\-\-cache'; then
    add_finding "LOW" "ESLint runs without --cache flag; adding --cache can speed up repeated runs"
  fi

  # Check: lint-staged concurrent is false
  if echo "$LINT_STAGED_JSON" | jq -e '.concurrent == false' >/dev/null 2>&1; then
    add_finding "LOW" "lint-staged concurrency is disabled; enabling it may improve performance"
  fi

  # Check: no hooks configured
  local hook_count
  hook_count="$(echo "$HOOKS_JSON" | jq 'keys | length')"
  if [[ "$hook_count" -eq 0 ]]; then
    add_finding "INFO" "No Git hooks are configured in this repository"
  fi

  # Check: lint-staged patterns that catch all files (too broad)
  if echo "$LINT_STAGED_JSON" | jq -e '.patterns[] | select(.glob == "*" or .glob == "**/*")' >/dev/null 2>&1; then
    add_finding "MEDIUM" "lint-staged glob matches all files; consider scoping to specific extensions"
  fi

  # Check: typecheck in lint-staged (runs tsc per file, very slow)
  if echo "$ls_commands" | grep -qiE '^tsc|typescript'; then
    add_finding "HIGH" "tsc/typecheck in lint-staged runs per-file which is very slow; run tsc separately on the full project"
  fi

  echo "$findings"
}

FINDINGS_JSON="$(generate_findings)"

# ── assemble final output ─────────────────────────────────────────
FINAL_JSON=$(jq -n \
  --arg fw "$FRAMEWORK" \
  --argjson hooks "$HOOKS_JSON" \
  --argjson ls "$LINT_STAGED_JSON" \
  --argjson findings "$FINDINGS_JSON" \
  '{
    framework: $fw,
    hooks: $hooks,
    lint_staged: $ls,
    findings: $findings
  }')

if [[ -n "$OUTPUT" ]]; then
  echo "$FINAL_JSON" | jq . > "$OUTPUT"
  echo "  Results written to $OUTPUT" >&2
fi

echo "$FINAL_JSON" | jq .

# Print summary to stderr
finding_count="$(echo "$FINDINGS_JSON" | jq 'length')"
echo "  Found $finding_count optimization finding(s)." >&2
echo "$FINDINGS_JSON" | jq -r '.[] | "    [\(.severity)] \(.message)"' >&2
echo "  Done." >&2
