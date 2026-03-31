---
name: hooks-audit
description: "This command should be used when the user asks to 'optimize git hooks', 'speed up pre-commit', 'audit Husky hooks', 'make hooks faster', or 'fix slow pre-push'. Runs one iteration: analyzes 1-2 hook dimensions, benchmarks performance, applies fixes, re-benchmarks, and records improvements."
---

# Hooks Audit — Full Cycle

You are performing one complete git hooks audit iteration. Improvements MUST be measured empirically using real hook execution benchmarks. Report progress at each phase.

This is a **self-contained loop**: edits are made in-place on the current branch. No iteration branches or PRs are created — hooks config changes are small and tightly coupled.

## Phase 1: Setup

1. Read `docs/plans/hooks-audit-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it (run `mkdir -p docs/plans` first if needed):
   ```markdown
   # Hooks Audit Tracking

   Automated git hook optimization. 6 dimensions to cover. All improvements measured with benchmarks.

   ---

   ## Iteration Log
   ```

2. Review which dimensions were already audited in prior iterations. Pick the next 1-2 unaudited dimensions from `references/hooks-dimensions.md`.

## Phase 2: Measure Baseline

Before making any changes, collect baseline measurements:

1. **Analyze current configuration:**
   ```bash
   ./scripts/hooks/analyze-config.sh --output /tmp/hooks-audit-config.json
   ```
   Review the configuration analysis. Note findings that relate to your chosen dimensions.

2. **Benchmark current hook performance:**
   ```bash
   ./scripts/hooks/benchmark-hooks.sh --hook both --runs 10 --warmup 2 --output /tmp/hooks-audit-baseline.json
   ```

3. **Trace detailed timing** (to identify where time is spent):
   ```bash
   ./scripts/hooks/trace-hooks.sh --hook both --output /tmp/hooks-audit-trace.json
   ```

4. Report the baseline: which hooks exist, their median execution times, and configuration findings.

## Phase 3: Analyze & Fix

For each chosen dimension, follow the analysis steps in `references/hooks-dimensions.md`.

1. **Identify relevant config files** — check `.husky/`, `lint-staged.config.*`, `.lintstagedrc*`, `package.json`
2. **Analyze against dimension criteria** — check positive and negative cases
3. **Classify findings**: HIGH (>2s savings or blocks developer flow), MEDIUM (0.5-2s savings or best practice), LOW (minor improvement)
4. **Fix all HIGH and MEDIUM findings**
5. Cap at ~8 files per iteration; defer the rest

After making changes, verify hooks still work:
```bash
git hook run pre-commit 2>&1 || true
git hook run pre-push 2>&1 || true
```

If a hook breaks, fix it before proceeding.

## Phase 4: Re-Measure

Run the same benchmark after changes:

```bash
./scripts/hooks/benchmark-hooks.sh --hook both --runs 10 --warmup 2 --output /tmp/hooks-audit-current.json
```

Generate comparison report:

```bash
./scripts/hooks/compare-benchmarks.sh --baseline /tmp/hooks-audit-baseline.json --current /tmp/hooks-audit-current.json --format markdown
```

If the benchmarks show a regression (hooks got slower), investigate and fix before proceeding.

## Phase 5: Update Tracking

Append a new entry to `docs/plans/hooks-audit-tracking.md`. Include the ACTUAL measurements from the comparison script:

```markdown
### Iteration N (YYYY-MM-DD)

**Dimensions Audited:** [list]
**Findings:** X (Y HIGH, Z MEDIUM)
**Fixed:** A
**Deferred:** B

#### Benchmarks

| Hook | Baseline (median) | After (median) | Delta | % Change |
|------|-------------------|----------------|-------|----------|
| <paste comparison table from compare-benchmarks.sh> |

#### Configuration Changes

- [x] Description (dimension: X, severity: HIGH/MEDIUM, measured impact: X.Xs → Y.Ys)

#### Deferred

- [ ] Description (dimension: X, severity: Y, reason)

#### Dimensions Remaining

- [list of unaudited dimensions]
```

## Phase 6: Signal

Completion requires BOTH conditions:
1. All 6 hook dimensions have been audited (check tracking file)
2. No HIGH or MEDIUM findings remain unfixed

**If both conditions met**, output exactly:

```
<promise>HOOKS_OPTIMIZED</promise>
```

**If either condition is NOT met**, exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

Only output this promise if you genuinely audited all dimensions and verified no actionable findings remain.
