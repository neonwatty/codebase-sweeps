#!/usr/bin/env bash
set -euo pipefail

# analyze-workflows.sh — Deterministic static analysis of GitHub Actions workflows.
# Covers dimensions D1 (Caching), D2 (Path Filtering), D3 (Parallelization),
# D5 (Dependency PR Handling), D8 (DRY Infrastructure).
#
# Structured JSON to stdout; human-readable summary to stderr.
# Optionally accepts baseline timing data to identify "heavy" jobs (>60s).

usage() {
  cat <<'USAGE'
Usage: analyze-workflows.sh [--dir .github/workflows] [--baseline FILE]
                            [--dimensions D1,D2,D3,D5,D8] [--heavy-threshold SECS]
                            [--output FILE] [--format json|markdown]

Deterministic static analysis of GitHub Actions workflow files.

Options:
  --dir DIR               Workflow directory (default: .github/workflows)
  --baseline FILE         Baseline timing JSON (from collect-baseline.sh) for
                          identifying heavy jobs. If omitted, all jobs are analyzed.
  --dimensions LIST       Comma-separated dimensions to check (default: D1,D2,D3,D5,D8)
  --heavy-threshold SECS  Duration threshold for "heavy" job (default: 60)
  --output FILE           Write output to FILE instead of stdout
  --format FMT            Output format: json (default) or markdown
  --help                  Show this help message
USAGE
}

for arg in "$@"; do
  [[ "$arg" == "--help" ]] && { usage; exit 0; }
done

# --- Check required tools ---
for tool in jq yq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Error: '$tool' is required but not installed." >&2
    [[ "$tool" == "yq" ]] && echo "  Install: brew install yq" >&2
    exit 1
  fi
done

# --- Parse arguments ---
DIR=".github/workflows"
BASELINE=""
DIMENSIONS="D1,D2,D3,D5,D8"
HEAVY_THRESHOLD=60
OUTPUT=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)             DIR="$2"; shift 2 ;;
    --baseline)        BASELINE="$2"; shift 2 ;;
    --dimensions)      DIMENSIONS="$2"; shift 2 ;;
    --heavy-threshold) HEAVY_THRESHOLD="$2"; shift 2 ;;
    --output)          OUTPUT="$2"; shift 2 ;;
    --format)          FORMAT="$2"; shift 2 ;;
    --help)            usage; exit 0 ;;
    *)                 echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -d "$DIR" ]] || { echo "Error: Workflow directory not found: $DIR" >&2; exit 1; }
[[ "$FORMAT" == "json" || "$FORMAT" == "markdown" ]] || { echo "Error: --format must be 'json' or 'markdown'." >&2; exit 1; }

# --- Collect workflow files ---
WORKFLOW_FILES=()
for ext in yml yaml; do
  for f in "$DIR"/*."$ext"; do
    [[ -f "$f" ]] && WORKFLOW_FILES+=("$f")
  done
done
[[ ${#WORKFLOW_FILES[@]} -gt 0 ]] || { echo "Error: No workflow files in $DIR" >&2; exit 1; }
echo "Analyzing ${#WORKFLOW_FILES[@]} workflow(s) in $DIR..." >&2

# --- Load baseline timing (if provided) ---
HEAVY_JOBS="[]"
if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
  HEAVY_JOBS=$(jq --argjson thresh "$HEAVY_THRESHOLD" '
    .jobs | to_entries | map(select(.value.median_duration_s >= $thresh)) | map(.key)
  ' "$BASELINE")
  HEAVY_COUNT=$(echo "$HEAVY_JOBS" | jq 'length')
  echo "Baseline loaded: $HEAVY_COUNT heavy job(s) (>= ${HEAVY_THRESHOLD}s)." >&2
else
  echo "No baseline provided — skipping timing-dependent checks." >&2
fi

# --- Heavy job matching helper ---
# Handles template expressions in YAML names like "CI — Web / e2e (${{ matrix.shard }})"
# matching baseline names like "CI — Web / e2e (1/3)" via prefix match.
is_heavy_job() {
  local job_name="$1"
  [[ $(echo "$HEAVY_JOBS" | jq 'length') -eq 0 ]] && echo "false" && return

  # First try exact match
  local exact
  exact=$(echo "$HEAVY_JOBS" | jq --arg name "$job_name" 'map(select(. == $name)) | length > 0')
  if [[ "$exact" == "true" ]]; then
    echo "true"
    return
  fi

  # Strip parenthesized suffixes for prefix match
  # "CI — Web / e2e (${{ matrix.shard }})" → "CI — Web / e2e"
  local prefix
  prefix=$(echo "$job_name" | sed 's/ *(.*//; s/ *$//')
  if [[ -n "$prefix" && "$prefix" != "$job_name" ]]; then
    local prefix_match
    prefix_match=$(echo "$HEAVY_JOBS" | jq --arg pfx "$prefix" 'map(select(startswith($pfx))) | length > 0')
    echo "$prefix_match"
    return
  fi

  echo "false"
}

# --- Global findings accumulator ---
FINDINGS="[]"

add_finding() {
  local dimension="$1" check="$2" severity="$3" file="$4" job="$5" detail="$6"
  FINDINGS=$(echo "$FINDINGS" | jq \
    --arg dim "$dimension" --arg chk "$check" --arg sev "$severity" \
    --arg f "$file" --arg j "$job" --arg d "$detail" \
    '. + [{dimension: $dim, check: $chk, severity: $sev, file: $f, job: $j, detail: $d}]')
}

# =====================================================================
# D1: Caching & Artifacts
# =====================================================================
check_d1() {
  echo "  Checking D1: Caching & Artifacts..." >&2

  for f in "${WORKFLOW_FILES[@]}"; do
    local jobs
    jobs=$(yq -r '.jobs // {} | keys[]' "$f" 2>/dev/null || true)

    for job in $jobs; do
      local steps_json
      steps_json=$(yq -o=json ".jobs[\"$job\"].steps // []" "$f" 2>/dev/null || echo "[]")

      # --- Check 1: setup-node without cache ---
      local setup_node_count cache_count
      setup_node_count=$(echo "$steps_json" | jq '[.[] | select(.uses // "" | test("actions/setup-node"))] | length')
      if [[ "$setup_node_count" -gt 0 ]]; then
        cache_count=$(echo "$steps_json" | jq '[.[] | select((.uses // "" | test("actions/setup-node")) and (.with.cache // "" | length > 0))] | length')
        if [[ "$cache_count" -eq 0 ]]; then
          add_finding "D1" "pkg-manager-cache" "HIGH" "$f" "$job" "actions/setup-node used without cache: key"
        fi
      fi

      # --- Check 2: Playwright install without browser cache ---
      local has_pw_install has_pw_cache
      has_pw_install=$(echo "$steps_json" | jq '[.[] | select(.run // "" | test("playwright install"))] | length')
      if [[ "$has_pw_install" -gt 0 ]]; then
        has_pw_cache=$(echo "$steps_json" | jq '[.[] | select((.uses // "" | test("actions/cache")) and ((.with.path // "") | test("playwright|ms-playwright")))] | length')
        if [[ "$has_pw_cache" -eq 0 ]]; then
          add_finding "D1" "playwright-browser-cache" "MEDIUM" "$f" "$job" "playwright install runs without browser cache"
        fi
      fi

      # --- Check 3: Unconditional artifact upload ---
      local unconditional_upload
      unconditional_upload=$(echo "$steps_json" | jq '[.[] | select((.uses // "" | test("actions/upload-artifact")) and (.if // "" | test("failure") | not))] | length')
      if [[ "$unconditional_upload" -gt 0 ]]; then
        add_finding "D1" "unconditional-artifact-upload" "LOW" "$f" "$job" "upload-artifact runs on success too (use if: failure() to save minutes)"
      fi

      # --- Check 4: Docker build without layer cache ---
      local has_docker_build has_docker_cache
      has_docker_build=$(echo "$steps_json" | jq '[.[] | select(.run // "" | test("docker build"))] | length')
      if [[ "$has_docker_build" -gt 0 ]]; then
        has_docker_cache=$(echo "$steps_json" | jq '[.[] | select((.uses // "" | test("docker/build-push-action")) and ((.with["cache-from"] // "") | length > 0))] | length')
        if [[ "$has_docker_cache" -eq 0 ]]; then
          add_finding "D1" "docker-layer-cache" "HIGH" "$f" "$job" "docker build without layer caching"
        fi
      fi

      # --- Check 5: Build step without framework cache ---
      # Check for Next.js, Turbo, or Vite builds without corresponding cache
      local has_next_build has_next_cache
      has_next_build=$(echo "$steps_json" | jq '[.[] | select(.run // "" | test("next build|pnpm build|npm run build|yarn build"))] | length')
      if [[ "$has_next_build" -gt 0 ]]; then
        has_next_cache=$(echo "$steps_json" | jq '[.[] | select((.uses // "" | test("actions/cache")) and ((.with.path // "") | test("\\.next/cache|\\.turbo|node_modules/\\.cache")))] | length')
        if [[ "$has_next_cache" -eq 0 ]]; then
          # Check if the build command is in a step that looks like it might build
          # Only flag if there's no cache action at all for build outputs
          local any_cache
          any_cache=$(echo "$steps_json" | jq '[.[] | select(.uses // "" | test("actions/cache"))] | length')
          if [[ "$any_cache" -eq 0 ]]; then
            add_finding "D1" "build-output-cache" "MEDIUM" "$f" "$job" "build step runs without framework output cache (e.g., .next/cache)"
          fi
        fi
      fi
    done
  done
}

# =====================================================================
# D2: Path Filtering
# =====================================================================
check_d2() {
  echo "  Checking D2: Path Filtering..." >&2

  for f in "${WORKFLOW_FILES[@]}"; do
    # Check if workflow triggers on pull_request
    local has_pr_trigger
    has_pr_trigger=$(yq -r '.on | has("pull_request") // false' "$f" 2>/dev/null || echo "false")

    [[ "$has_pr_trigger" != "true" ]] && continue

    # Check if there's a path-filter job or paths: trigger
    local has_paths_trigger has_filter_job
    has_paths_trigger=$(yq -r '.on.pull_request.paths // null' "$f" 2>/dev/null || echo "null")
    has_filter_job=$(yq -r '.jobs // {} | to_entries[] | select(.value.steps[]?.uses // "" | test("dorny/paths-filter")) | .key' "$f" 2>/dev/null | head -1 || true)

    # Check if push trigger has paths: but pull_request doesn't (and no dorny filter)
    local push_has_paths
    push_has_paths=$(yq -r '.on.push.paths // null' "$f" 2>/dev/null || echo "null")

    if [[ "$has_paths_trigger" == "null" && -z "$has_filter_job" ]]; then
      # No path filtering at all on PR trigger
      # Only flag if there are heavy jobs (or no baseline to check)
      local jobs
      jobs=$(yq -r '.jobs // {} | keys[]' "$f" 2>/dev/null || true)

      for job in $jobs; do
        local job_name
        job_name=$(yq -r ".jobs[\"$job\"].name // \"$job\"" "$f" 2>/dev/null || echo "$job")

        # Check if this is a heavy job (from baseline timing)
        local is_heavy
        is_heavy=$(is_heavy_job "$job_name")

        if [[ "$is_heavy" == "true" ]]; then
          add_finding "D2" "heavy-job-no-path-filter" "HIGH" "$f" "$job" "Heavy job ($job_name) runs on all PRs without path filtering"
        fi
      done

      # General finding if no path filtering exists at all
      if [[ "$push_has_paths" != "null" ]]; then
        add_finding "D2" "push-paths-no-pr-filter" "MEDIUM" "$f" "" "push trigger has paths: filter but pull_request has no filtering"
      fi
    fi

    # Check if filter job outputs propagate to downstream jobs
    if [[ -n "$has_filter_job" ]]; then
      # Use yq -o=json + jq instead of yq conditionals (yq v4 doesn't support if/then/else)
      local downstream_jobs
      downstream_jobs=$(yq -o=json '.jobs // {}' "$f" 2>/dev/null | jq -r --arg fj "$has_filter_job" '
        to_entries[] | select(
          (.value.needs // null) |
          if type == "array" then map(select(. == $fj)) | length > 0
          elif type == "string" then . == $fj
          else false
          end
        ) | .key
      ' 2>/dev/null || true)

      for djob in $downstream_jobs; do
        local job_if
        job_if=$(yq -r ".jobs[\"$djob\"].if // \"\"" "$f" 2>/dev/null || echo "")
        # Use yq -o=json + jq for recursive string search (yq type == "string" doesn't work; it uses !!str)
        local has_env_check
        has_env_check=$(yq -o=json ".jobs[\"$djob\"]" "$f" 2>/dev/null | \
          jq -r --arg pat "SHOULD_RUN|needs\\.$has_filter_job\\.outputs" \
            '[.. | strings | select(test($pat))] | first // empty' 2>/dev/null || true)

        if [[ -z "$job_if" && -z "$has_env_check" ]]; then
          add_finding "D2" "filter-output-unused" "MEDIUM" "$f" "$djob" "Job depends on filter job '$has_filter_job' but doesn't check its output"
        fi
      done
    fi
  done
}

# =====================================================================
# D3: Parallelization
# =====================================================================
check_d3() {
  echo "  Checking D3: Parallelization..." >&2

  for f in "${WORKFLOW_FILES[@]}"; do
    local jobs_json
    jobs_json=$(yq -o=json '.jobs // {}' "$f" 2>/dev/null || echo "{}")

    # --- Check 1: Serial bottleneck jobs ---
    # Find jobs that are the sole dependency for 2+ other jobs
    local job_names
    job_names=$(echo "$jobs_json" | jq -r 'keys[]')

    for job in $job_names; do
      # Count how many other jobs list this one as their only dependency
      local sole_dep_count
      sole_dep_count=$(echo "$jobs_json" | jq --arg j "$job" '
        to_entries | map(select(
          (.value.needs // null) |
          if type == "array" then (. == [$j])
          elif type == "string" then (. == $j)
          else false
          end
        )) | length
      ')

      if [[ "$sole_dep_count" -ge 2 ]]; then
        # Check if this job is heavy (blocking multiple downstream jobs)
        local job_name
        job_name=$(echo "$jobs_json" | jq -r --arg j "$job" '.[$j].name // $j')
        local is_heavy
        is_heavy=$(is_heavy_job "$job_name")

        if [[ "$is_heavy" == "true" ]]; then
          add_finding "D3" "serial-bottleneck" "HIGH" "$f" "$job" "Heavy job '$job_name' blocks $sole_dep_count downstream jobs as sole dependency"
        else
          add_finding "D3" "serial-bottleneck" "LOW" "$f" "$job" "Job '$job_name' is sole dependency for $sole_dep_count downstream jobs"
        fi
      fi
    done

    # --- Check 2: E2E tests without sharding ---
    for job in $job_names; do
      local job_name steps_json
      job_name=$(echo "$jobs_json" | jq -r --arg j "$job" '.[$j].name // $j')
      steps_json=$(echo "$jobs_json" | jq --arg j "$job" '.[$j].steps // []')

      # Detect test jobs (playwright, cypress, jest e2e)
      local has_e2e
      has_e2e=$(echo "$steps_json" | jq '[.[] | select(.run // "" | test("playwright test|cypress run|jest.*e2e|vitest.*e2e"))] | length')
      if [[ "$has_e2e" -gt 0 ]]; then
        local has_matrix
        has_matrix=$(echo "$jobs_json" | jq --arg j "$job" '.[$j].strategy.matrix // null | if . != null then "true" else "false" end' -r)
        if [[ "$has_matrix" != "true" ]]; then
          add_finding "D3" "e2e-no-sharding" "MEDIUM" "$f" "$job" "E2E test job '$job_name' runs without matrix sharding"
        fi
      fi
    done

    # --- Check 3: Sequential lint && typecheck in single step ---
    for job in $job_names; do
      local steps_json
      steps_json=$(echo "$jobs_json" | jq --arg j "$job" '.[$j].steps // []')

      local sequential_checks
      sequential_checks=$(echo "$steps_json" | jq -r '[.[] | select(.run // "" | test("(lint|eslint).*(typecheck|tsc)|(typecheck|tsc).*(lint|eslint)"; "i"))] | length')
      if [[ "$sequential_checks" -gt 0 ]]; then
        add_finding "D3" "sequential-lint-typecheck" "MEDIUM" "$f" "$job" "lint and typecheck run sequentially in a single step — could parallelize"
      fi
    done
  done

  # --- Check 4: Critical path analysis (if baseline available) ---
  if [[ $(echo "$HEAVY_JOBS" | jq 'length') -gt 0 && -n "$BASELINE" ]]; then
    for f in "${WORKFLOW_FILES[@]}"; do
      local jobs_json
      jobs_json=$(yq -o=json '.jobs // {}' "$f" 2>/dev/null || echo "{}")
      local job_names
      job_names=$(echo "$jobs_json" | jq -r 'keys[]')

      # Compute total serial chain length for each terminal job
      for job in $job_names; do
        # Check if this is a terminal job (nothing depends on it)
        local is_terminal
        is_terminal=$(echo "$jobs_json" | jq --arg j "$job" '
          to_entries | map(select(
            (.value.needs // []) |
            if type == "array" then map(select(. == $j)) | length > 0
            elif type == "string" then . == $j
            else false
            end
          )) | length == 0
        ')

        if [[ "$is_terminal" == "true" ]]; then
          # Walk the needs: chain to compute depth
          local depth=0
          local current="$job"
          while true; do
            local needs_list
            needs_list=$(echo "$jobs_json" | jq -r --arg j "$current" '
              .[$j].needs // null |
              if type == "array" then .[0] // empty
              elif type == "string" then .
              else empty
              end
            ')
            [[ -z "$needs_list" ]] && break
            depth=$((depth + 1))
            current="$needs_list"
            [[ $depth -gt 20 ]] && break  # safety valve
          done

          if [[ $depth -ge 3 ]]; then
            local job_name
            job_name=$(echo "$jobs_json" | jq -r --arg j "$job" '.[$j].name // $j')
            add_finding "D3" "deep-dependency-chain" "MEDIUM" "$f" "$job" "Job '$job_name' has a dependency chain $depth levels deep"
          fi
        fi
      done
    done
  fi
}

# =====================================================================
# D5: Dependency PR Handling
# =====================================================================
check_d5() {
  echo "  Checking D5: Dependency PR Handling..." >&2

  # --- Check 1: dependabot.yml grouping ---
  local dependabot_file=""
  for candidate in .github/dependabot.yml .github/dependabot.yaml; do
    [[ -f "$candidate" ]] && dependabot_file="$candidate"
  done

  if [[ -n "$dependabot_file" ]]; then
    local has_groups
    has_groups=$(yq -r '.. | select(type == "!!map" and has("groups")) | .groups | length' "$dependabot_file" 2>/dev/null | head -1 || echo "0")
    has_groups="${has_groups:-0}"
    if [[ "$has_groups" -eq 0 ]]; then
      add_finding "D5" "dependabot-no-grouping" "MEDIUM" "$dependabot_file" "" "dependabot.yml exists but has no groups: — each dependency gets its own PR"
    fi
  else
    # No dependabot file — check for renovate
    local has_renovate="false"
    for candidate in renovate.json renovate.json5 .renovaterc .renovaterc.json; do
      [[ -f "$candidate" ]] && has_renovate="true"
    done
    if [[ "$has_renovate" == "false" ]]; then
      add_finding "D5" "no-dependency-manager" "LOW" "" "" "No dependabot.yml or renovate config found"
    fi
  fi

  # --- Check 2: Heavy jobs without dependabot skip condition ---
  for f in "${WORKFLOW_FILES[@]}"; do
    # Only check workflows triggered by pull_request
    local has_pr_trigger
    has_pr_trigger=$(yq -r '.on | has("pull_request") // false' "$f" 2>/dev/null || echo "false")
    [[ "$has_pr_trigger" != "true" ]] && continue

    local jobs
    jobs=$(yq -r '.jobs // {} | keys[]' "$f" 2>/dev/null || true)

    for job in $jobs; do
      local job_name job_if
      job_name=$(yq -r ".jobs[\"$job\"].name // \"$job\"" "$f" 2>/dev/null || echo "$job")
      job_if=$(yq -r ".jobs[\"$job\"].if // \"\"" "$f" 2>/dev/null || echo "")

      # Check if job already has a dependabot skip
      if echo "$job_if" | grep -qi "dependabot\|renovate"; then
        continue
      fi

      # Check if this is a heavy job
      local is_heavy
      is_heavy=$(is_heavy_job "$job_name")

      if [[ "$is_heavy" == "true" ]]; then
        add_finding "D5" "heavy-job-no-bot-skip" "HIGH" "$f" "$job" "Heavy job '$job_name' runs on dependency PRs without skip condition"
      fi
    done
  done
}

# =====================================================================
# D8: DRY Infrastructure
# =====================================================================
check_d8() {
  echo "  Checking D8: DRY Infrastructure..." >&2

  # --- Check 1: Duplicated setup sequences ---
  # Extract the first N action steps (uses: lines) per job across all files, find duplicates
  local setup_hashes=()
  local setup_jobs=()

  for f in "${WORKFLOW_FILES[@]}"; do
    local jobs
    jobs=$(yq -r '.jobs // {} | keys[]' "$f" 2>/dev/null || true)

    for job in $jobs; do
      # Extract the first uses: steps (the setup sequence)
      local setup_seq
      setup_seq=$(yq -o=json ".jobs[\"$job\"].steps // []" "$f" 2>/dev/null | \
        jq -r '[.[] | select(.uses != null) | .uses | split("@")[0]] | .[0:5] | join("|")')

      if [[ -n "$setup_seq" && "$setup_seq" != "" ]]; then
        setup_hashes+=("$setup_seq")
        setup_jobs+=("$f:$job")
      fi
    done
  done

  # Find sequences that appear 3+ times
  if [[ ${#setup_hashes[@]} -gt 0 ]]; then
    local seen_seqs=()
    local counted_seqs=()

    for i in "${!setup_hashes[@]}"; do
      local seq="${setup_hashes[$i]}"
      local already_counted="false"
      for cs in "${counted_seqs[@]+"${counted_seqs[@]}"}"; do
        [[ "$cs" == "$seq" ]] && { already_counted="true"; break; }
      done
      [[ "$already_counted" == "true" ]] && continue

      local count=0
      local instances=""
      for j in "${!setup_hashes[@]}"; do
        if [[ "${setup_hashes[$j]}" == "$seq" ]]; then
          count=$((count + 1))
          instances+="${setup_jobs[$j]}, "
        fi
      done

      if [[ $count -ge 3 ]]; then
        counted_seqs+=("$seq")
        local readable_seq
        readable_seq=$(echo "$seq" | tr '|' ' → ')
        add_finding "D8" "duplicated-setup" "MEDIUM" "(multiple)" "" "Setup sequence [$readable_seq] duplicated in $count jobs: ${instances%, }"
      fi
    done
  fi

  # --- Check 2: Composite actions directory ---
  if [[ ! -d ".github/actions" ]]; then
    local dup_count=0
    for cs in "${counted_seqs[@]+"${counted_seqs[@]}"}"; do
      dup_count=$((dup_count + 1))
    done
    if [[ $dup_count -gt 0 ]]; then
      add_finding "D8" "no-composite-actions" "LOW" ".github/actions/" "" "No composite actions directory exists — duplicated setup could be consolidated"
    fi
  fi

  # --- Check 3: Duplicated env blocks ---
  local env_blocks=()
  local env_sources=()

  for f in "${WORKFLOW_FILES[@]}"; do
    local jobs
    jobs=$(yq -r '.jobs // {} | keys[]' "$f" 2>/dev/null || true)

    for job in $jobs; do
      # Extract job-level env as sorted key=value pairs
      local job_env
      job_env=$(yq -o=json ".jobs[\"$job\"].env // {}" "$f" 2>/dev/null | jq -r 'to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(";")' || echo "")
      if [[ -n "$job_env" && "$job_env" != "" ]]; then
        env_blocks+=("$job_env")
        env_sources+=("$f:$job")
      fi
    done
  done

  # Find env blocks that appear 2+ times with 2+ variables
  if [[ ${#env_blocks[@]} -gt 0 ]]; then
    local counted_envs=()
    for i in "${!env_blocks[@]}"; do
      local env="${env_blocks[$i]}"
      local var_count
      var_count=$(echo "$env" | tr ';' '\n' | wc -l | tr -d ' ')
      [[ "$var_count" -lt 2 ]] && continue

      local already_counted="false"
      for ce in "${counted_envs[@]+"${counted_envs[@]}"}"; do
        [[ "$ce" == "$env" ]] && { already_counted="true"; break; }
      done
      [[ "$already_counted" == "true" ]] && continue

      local count=0
      for j in "${!env_blocks[@]}"; do
        [[ "${env_blocks[$j]}" == "$env" ]] && count=$((count + 1))
      done

      if [[ $count -ge 2 ]]; then
        counted_envs+=("$env")
        add_finding "D8" "duplicated-env" "LOW" "(multiple)" "" "Identical env block ($var_count vars) duplicated across $count jobs — consider workflow-level env:"
      fi
    done
  fi
}

# =====================================================================
# Main
# =====================================================================

# Run selected dimensions
IFS=',' read -ra DIM_ARRAY <<< "$DIMENSIONS"
for dim in "${DIM_ARRAY[@]}"; do
  case "$dim" in
    D1) check_d1 ;;
    D2) check_d2 ;;
    D3) check_d3 ;;
    D5) check_d5 ;;
    D8) check_d8 ;;
    *)  echo "Warning: Unknown dimension '$dim' — skipping." >&2 ;;
  esac
done

# --- Build result ---
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESULT=$(echo "$FINDINGS" | jq --arg ts "$COLLECTED_AT" --arg dir "$DIR" \
  --arg dims "$DIMENSIONS" --argjson thresh "$HEAVY_THRESHOLD" '
  {
    collected_at: $ts,
    directory: $dir,
    dimensions_checked: ($dims | split(",")),
    heavy_threshold_s: $thresh,
    findings: .,
    by_dimension: (group_by(.dimension) | map({(.[0].dimension): .}) | add // {}),
    summary: {
      total: length,
      high: [.[] | select(.severity == "HIGH")] | length,
      medium: [.[] | select(.severity == "MEDIUM")] | length,
      low: [.[] | select(.severity == "LOW")] | length,
      by_dimension: (group_by(.dimension) | map({key: .[0].dimension, value: length}) | from_entries)
    }
  }
')

# --- Format output ---
format_markdown() {
  echo "$RESULT" | jq -r '
    "## Workflow Analysis",
    "",
    "Dimensions checked: \(.dimensions_checked | join(", "))",
    "Heavy job threshold: \(.heavy_threshold_s)s",
    "",
    "### Summary",
    "",
    "| Severity | Count |",
    "|----------|-------|",
    "| HIGH | \(.summary.high) |",
    "| MEDIUM | \(.summary.medium) |",
    "| LOW | \(.summary.low) |",
    "| **Total** | **\(.summary.total)** |",
    "",
    "### Findings",
    "",
    if (.findings | length) == 0 then
      "No findings."
    else
      (
        "| Dimension | Check | Severity | File | Job | Detail |",
        "|-----------|-------|----------|------|-----|--------|",
        (.findings[] |
          "| \(.dimension) | \(.check) | \(.severity) | \(.file) | \(.job) | \(.detail) |"
        )
      )
    end
  '
}

if [[ "$FORMAT" == "markdown" ]]; then
  FORMATTED=$(format_markdown)
else
  FORMATTED=$(echo "$RESULT" | jq '.')
fi

if [[ -n "$OUTPUT" ]]; then
  echo "$FORMATTED" > "$OUTPUT"
  echo "Results written to $OUTPUT" >&2
else
  echo "$FORMATTED"
fi

# --- Human summary to stderr ---
echo "" >&2
echo "=== Workflow Analysis ===" >&2
echo "$RESULT" | jq -r '
  "Findings: \(.summary.total) (\(.summary.high) HIGH, \(.summary.medium) MEDIUM, \(.summary.low) LOW)",
  (.summary.by_dimension | to_entries[] | "  \(.key): \(.value)")
' >&2
