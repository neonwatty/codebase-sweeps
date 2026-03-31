---
name: ci-audit
description: "This command should be used when the user asks to 'optimize CI', 'audit CI pipeline', 'speed up GitHub Actions', 'reduce CI time', 'make CI faster', or 'harden CI permissions'. Runs one iteration: analyzes 1-2 CI dimensions across multiple measurement axes (timing, billable minutes, hygiene, flakiness), applies fixes, re-measures, and merges."
argument-hint: "OWNER/REPO [--branch BRANCH]"
---

# CI Audit — Full Cycle

You are performing one complete CI audit iteration. All detection is driven by script output — do not invent findings beyond what the scripts report. Report progress at each phase.

Parse the arguments: extract the OWNER/REPO and optional --branch (default: the repo's default branch).

**Repository:** $ARGUMENTS

If no repository was provided above, check if the current directory is a GitHub repo and use its origin remote.

## Measurement Axes

Different dimensions are measured differently. Refer to `references/ci-dimensions.md` for each dimension's axis:

| Axis | What it measures | Detection script | Comparison script |
|------|-----------------|-----------------|-------------------|
| **Wall-clock** | Job duration deltas (seconds) | `analyze-workflows.sh` | `compare-runs.sh` |
| **Billable** | Estimated runner-minutes (with OS multipliers) | `analyze-workflows.sh` | `compare-runs.sh` |
| **Hygiene** | Configuration best-practices checklist | `score-hygiene.sh` | `compare-runs.sh` |
| **Flakiness** | Failure rates and retry config | `score-flakiness.sh` | `compare-runs.sh` |

## Phase 1: Setup

1. Ensure you are on the default branch with the latest code:
   ```bash
   git checkout main && git pull origin main
   ```

2. Read `docs/plans/ci-audit-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it:
   ```markdown
   # CI Audit Tracking

   Automated CI pipeline optimization. 9 dimensions across 4 measurement axes. All improvements measured empirically.

   **Measurement axes:** Wall-clock timing | Billable minutes | Hygiene checklist | Flakiness score

   ---

   ## Iteration Log
   ```

3. Create an iteration branch:
   ```bash
   git checkout -b ci-audit/iteration-<N>
   ```

4. Review which dimensions were already audited in prior iterations. Pick the next 1-2 unaudited dimensions from `references/ci-dimensions.md`.

## Phase 2: Collect Data

Before making any changes, run all relevant detection scripts. These produce the findings you will act on — do not skip them.

**Always collect (every iteration):**

1. **Static analysis** — run actionlint (if installed):
   ```bash
   ./scripts/ci/run-actionlint.sh --format json --output /tmp/ci-audit-actionlint-before.json
   ```

2. **Timing baseline** — collect timing from recent passing CI runs:
   ```bash
   ./scripts/ci/collect-baseline.sh --repo <OWNER/REPO> --runs 3 --output /tmp/ci-audit-baseline.json
   ```

3. **Workflow analysis** — run deterministic checks for your chosen dimensions (D1, D2, D3, D5, D8):
   ```bash
   ./scripts/ci/analyze-workflows.sh \
     --baseline /tmp/ci-audit-baseline.json \
     --dimensions <D1,D2,...> \
     --format json --output /tmp/ci-audit-analysis.json
   ```
   Also run in markdown format for human-readable review:
   ```bash
   ./scripts/ci/analyze-workflows.sh \
     --baseline /tmp/ci-audit-baseline.json \
     --dimensions <D1,D2,...> \
     --format markdown
   ```

**Collect if auditing a Hygiene-axis dimension (D7, D8, D9):**

4. **Hygiene baseline:**
   ```bash
   ./scripts/ci/score-hygiene.sh --output /tmp/ci-audit-hygiene-before.json
   ```

**Collect if auditing D6 (Flakiness):**

5. **Flakiness report:**
   ```bash
   ./scripts/ci/score-flakiness.sh --repo <OWNER/REPO> --runs 20 --output /tmp/ci-audit-flakiness.json
   ```

6. Report the collected data: which jobs exist, their median durations, and the specific findings from each script.

## Phase 3: Fix

Fix the findings reported by the scripts. Do NOT invent additional findings — the scripts are the source of truth.

1. **Review script output** — read the JSON/markdown from Phase 2
2. **Fix all HIGH findings** from `analyze-workflows.sh` and `score-hygiene.sh`
3. **Fix all MEDIUM findings** from `analyze-workflows.sh` and `score-hygiene.sh`
4. **For D6 (Flakiness):** adjust retry config in workflow YAML as indicated by `score-flakiness.sh`. Do NOT modify test source code — only workflow YAML and runner config. Document flaky jobs in the tracking file for manual investigation.
5. **Defer LOW findings** — log them in the tracking file but do not fix
6. Cap at ~12 files per iteration; defer the rest

## Phase 4: Validate & Re-Measure

1. **Static analysis** — re-run actionlint to confirm no new issues:
   ```bash
   ./scripts/ci/run-actionlint.sh --format json --output /tmp/ci-audit-actionlint-after.json
   ```
   If new issues were introduced, fix them before proceeding.

2. **Re-run detection scripts** to confirm findings are resolved:
   ```bash
   ./scripts/ci/analyze-workflows.sh \
     --baseline /tmp/ci-audit-baseline.json \
     --dimensions <same dimensions> \
     --format markdown
   ```
   The previously-reported HIGH and MEDIUM findings should no longer appear.

3. **Hygiene re-score** (if auditing D7, D8, or D9):
   ```bash
   ./scripts/ci/score-hygiene.sh --output /tmp/ci-audit-hygiene-after.json
   ```

4. Follow the **Ship** phase in `references/common-lifecycle.md` with:
   - **Branch:** `ci-audit/iteration-<N>`
   - **Commit:** `ci: optimize <dimension names> from ci audit iteration N`
   - **PR title:** `CI Audit: Iteration N — <dimension names>`
   - **PR body:** `Automated CI optimization. See docs/plans/ci-audit-tracking.md for measurements.`

5. **Wait for CI to complete** on the PR:
   ```bash
   gh pr checks <number> --watch
   ```

6. **Collect post-change timing** from the CI run triggered by the PR:
   ```bash
   RUN_ID=$(gh run list --branch ci-audit/iteration-<N> --limit 1 --json databaseId --jq '.[0].databaseId')
   ./scripts/ci/collect-run-timing.sh --repo <OWNER/REPO> --run-id "$RUN_ID" --output /tmp/ci-audit-current.json
   ```

7. **Generate multi-axis comparison report:**
   ```bash
   ./scripts/ci/compare-runs.sh \
     --baseline /tmp/ci-audit-baseline.json \
     --current /tmp/ci-audit-current.json \
     --hygiene-before /tmp/ci-audit-hygiene-before.json \
     --hygiene-after /tmp/ci-audit-hygiene-after.json \
     --flakiness /tmp/ci-audit-flakiness.json \
     --format markdown
   ```
   Note: only include `--hygiene-*` and `--flakiness` flags if those files exist (i.e., you collected them in Phase 2).

8. If CI fails, read logs, fix, push, and re-measure (max 3 attempts):
   ```bash
   gh run view <run-id> --log-failed
   ```

## Phase 5: Update Tracking

Append a new entry to `docs/plans/ci-audit-tracking.md`. Include the ACTUAL measurements from the scripts. Only include sections relevant to the dimensions you audited:

```markdown
### Iteration N (YYYY-MM-DD)

**Dimensions Audited:** [list with measurement axis in parentheses]
**Findings:** X (Y HIGH, Z MEDIUM) — from analyze-workflows.sh / score-hygiene.sh / score-flakiness.sh
**Fixed:** A
**Deferred:** B

#### Timing (if Wall-clock or Billable dimensions were audited)

| Job | Baseline (s) | After (s) | Delta | % Change |
|-----|-------------|-----------|-------|----------|
| <paste from compare-runs.sh> |

#### Billable Minutes (if Billable dimensions were audited)

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Total billable min | X | Y | Z |

#### Hygiene Checklist (if Hygiene dimensions were audited)

| Check | Before | After |
|-------|--------|-------|
| <paste from compare-runs.sh> |

#### Flakiness (if D6 was audited)

| Job | Failure Rate | Retry Config | Action Taken |
|-----|-------------|-------------|--------------|
| <from score-flakiness.sh> |

**actionlint findings:** before: X, after: Y

#### Fixed

- [x] Description (dimension: DX, axis: Wall-clock/Billable/Hygiene/Flakiness, severity: HIGH/MEDIUM)

#### Deferred

- [ ] Description (dimension: DX, severity: Y, reason)

#### Dimensions Remaining

- [list of unaudited dimensions with their axes]
```

Push the tracking update:
```bash
git add docs/plans/ci-audit-tracking.md
git commit -m "docs: update ci-audit tracking with iteration N measurements"
git push
```

## Phase 6: Merge

Follow the **CI & Merge** phase in `references/common-lifecycle.md`.

## Phase 7: Signal

Completion requires BOTH conditions:
1. All 9 CI dimensions have been audited (check tracking file)
2. No HIGH or MEDIUM findings remain unfixed (re-run all detection scripts to confirm)

**If both conditions met**, output exactly:

```
<promise>CI_OPTIMIZED</promise>
```

**If either condition is NOT met**, exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

Only output this promise if you genuinely audited all dimensions and verified no actionable findings remain.
