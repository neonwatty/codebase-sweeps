---
name: ci-audit
description: "This command should be used when the user asks to 'optimize CI', 'audit CI pipeline', 'speed up GitHub Actions', 'reduce CI time', or 'make CI faster'. Runs one iteration: analyzes 1-2 CI dimensions, measures baseline timing, applies fixes, re-measures, and merges."
argument-hint: "OWNER/REPO [--branch BRANCH]"
---

# CI Audit — Full Cycle

You are performing one complete CI audit iteration. Improvements MUST be measured empirically using real CI runs. Report progress at each phase.

Parse the arguments: extract the OWNER/REPO and optional --branch (default: the repo's default branch).

**Repository:** $ARGUMENTS

If no repository was provided above, check if the current directory is a GitHub repo and use its origin remote.

## Phase 1: Setup

1. Ensure you are on the default branch with the latest code:
   ```bash
   git checkout main && git pull origin main
   ```

2. Read `docs/plans/ci-audit-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it:
   ```markdown
   # CI Audit Tracking

   Automated CI pipeline optimization. 8 dimensions to cover. All improvements measured empirically.

   ---

   ## Iteration Log
   ```

3. Create an iteration branch:
   ```bash
   git checkout -b ci-audit/iteration-<N>
   ```

4. Review which dimensions were already audited in prior iterations. Pick the next 1-2 unaudited dimensions from `references/ci-dimensions.md`.

## Phase 2: Measure Baseline

Before making any changes, collect baseline measurements:

1. **Static analysis** — run actionlint:
   ```bash
   ./scripts/ci/run-actionlint.sh --format json --output /tmp/ci-audit-actionlint-before.json
   ```
   Review the findings. Note structural issues that relate to your chosen dimensions.

2. **Timing baseline** — collect timing from recent passing CI runs:
   ```bash
   ./scripts/ci/collect-baseline.sh --repo <OWNER/REPO> --runs 3 --output /tmp/ci-audit-baseline.json
   ```
   Review the per-job timing. Identify the slowest jobs and any that relate to your chosen dimensions.

3. Report the baseline: which jobs exist, their median durations, total wall-clock time, and actionlint findings.

## Phase 3: Analyze & Fix

For each chosen dimension, follow the analysis steps in `references/ci-dimensions.md`.

1. **Identify relevant workflow files** — read every `.github/workflows/*.yml` file
2. **Analyze against dimension criteria** — check positive and negative cases
3. **Classify findings**: HIGH (>30s savings or critical reliability fix), MEDIUM (10-30s savings or best practice), LOW (minor improvement)
4. **Fix all HIGH and MEDIUM findings**
5. Cap at ~12 files per iteration; defer the rest

## Phase 4: Validate & Re-Measure

1. **Static analysis** — re-run actionlint to confirm no new issues:
   ```bash
   ./scripts/ci/run-actionlint.sh --format json --output /tmp/ci-audit-actionlint-after.json
   ```
   If new issues were introduced, fix them before proceeding.

2. Follow the **Ship** phase in `references/common-lifecycle.md` with:
   - **Branch:** `ci-audit/iteration-<N>`
   - **Commit:** `ci: optimize <dimension names> from ci audit iteration N`
   - **PR title:** `CI Audit: Iteration N — <dimension names>`
   - **PR body:** `Automated CI optimization. See docs/plans/ci-audit-tracking.md for measurements.`

3. **Wait for CI to complete** on the PR:
   ```bash
   gh pr checks <number> --watch
   ```

4. **Collect post-change timing** from the CI run triggered by the PR:
   ```bash
   # Get the run ID from the PR's check suite
   RUN_ID=$(gh run list --branch ci-audit/iteration-<N> --limit 1 --json databaseId --jq '.[0].databaseId')
   ./scripts/ci/collect-run-timing.sh --repo <OWNER/REPO> --run-id "$RUN_ID" --output /tmp/ci-audit-current.json
   ```

5. **Generate comparison report:**
   ```bash
   ./scripts/ci/compare-runs.sh --baseline /tmp/ci-audit-baseline.json --current /tmp/ci-audit-current.json --format markdown
   ```

6. If CI fails, read logs, fix, push, and re-measure (max 3 attempts):
   ```bash
   gh run view <run-id> --log-failed
   ```

## Phase 5: Update Tracking

Append a new entry to `docs/plans/ci-audit-tracking.md`. Include the ACTUAL measurements from the comparison script:

```markdown
### Iteration N (YYYY-MM-DD)

**Dimensions Audited:** [list]
**Findings:** X (Y HIGH, Z MEDIUM)
**Fixed:** A
**Deferred:** B

#### Measurements

| Job | Baseline (s) | After (s) | Delta | % Change |
|-----|-------------|-----------|-------|----------|
| <paste comparison table from compare-runs.sh> |

**actionlint findings:** before: X, after: Y

#### Fixed

- [x] Description (dimension: X, severity: HIGH/MEDIUM, estimated impact: Ys)

#### Deferred

- [ ] Description (dimension: X, severity: Y, reason)

#### Dimensions Remaining

- [list of unaudited dimensions]
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
1. All 8 CI dimensions have been audited (check tracking file)
2. No HIGH or MEDIUM findings remain unfixed

**If both conditions met**, output exactly:

```
<promise>CI_OPTIMIZED</promise>
```

**If either condition is NOT met**, exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

Only output this promise if you genuinely audited all dimensions and verified no actionable findings remain.
