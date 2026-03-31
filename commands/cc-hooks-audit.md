---
name: cc-hooks-audit
description: "This command should be used when the user asks to 'optimize Claude Code hooks', 'audit CC hooks', 'speed up hooks', 'fix slow Claude hooks', or 'improve hook configuration'. Runs one iteration: analyzes 1-2 hook dimensions, profiles performance, applies fixes, re-profiles, and records improvements."
---

# Claude Code Hooks Audit — Full Cycle

You are performing one complete Claude Code hooks audit iteration. Improvements MUST be measured empirically using hook profiling. Report progress at each phase.

This is a **self-contained loop**: edits are made in-place on the current branch. No iteration branches or PRs are created — hook config changes are small and tightly coupled.

## Phase 1: Setup

1. Read `docs/plans/cc-hooks-audit-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it (run `mkdir -p docs/plans` first if needed):
   ```markdown
   # Claude Code Hooks Audit Tracking

   Automated Claude Code hook optimization. 6 dimensions to cover. All improvements measured with profiling.

   ---

   ## Iteration Log
   ```

2. Review which dimensions were already audited in prior iterations. Pick the next 1-2 unaudited dimensions from `references/cc-hooks-dimensions.md`.

## Phase 2: Measure Baseline

Before making any changes, collect baseline measurements:

1. **Analyze current configuration:**
   ```bash
   ./scripts/cc-hooks/analyze-settings.sh --output /tmp/cc-hooks-audit-config.json
   ```
   Review the configuration analysis. Note findings that relate to your chosen dimensions.

2. **Profile current hook performance:**
   ```bash
   ./scripts/cc-hooks/profile-hooks.sh --iterations 5 --output /tmp/cc-hooks-audit-baseline.json
   ```

3. Report the baseline: how many hooks are configured, their median execution times, and configuration findings.

## Phase 3: Analyze & Fix

For each chosen dimension, follow the analysis steps in `references/cc-hooks-dimensions.md`.

1. **Identify relevant config files** — check `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`
2. **Read all hook scripts** referenced by the configuration
3. **Analyze against dimension criteria** — check positive and negative cases
4. **Classify findings**: HIGH (>500ms latency, blocks every tool call, missing timeout), MEDIUM (100-500ms, broad matcher, missing filter), LOW (minor improvement, missing statusMessage)
5. **Fix all HIGH and MEDIUM findings**

After making changes, verify hooks still work by checking the configuration is valid JSON:
```bash
cat .claude/settings.json | jq . > /dev/null 2>&1 && echo "Valid JSON" || echo "INVALID JSON"
```

If hooks reference scripts, verify the scripts exist and are executable.

## Phase 4: Re-Measure

Run the same profiling after changes:

```bash
./scripts/cc-hooks/profile-hooks.sh --iterations 5 --output /tmp/cc-hooks-audit-current.json
```

Generate comparison report:

```bash
./scripts/cc-hooks/compare-profiles.sh --baseline /tmp/cc-hooks-audit-baseline.json --current /tmp/cc-hooks-audit-current.json --format markdown
```

If the profile shows a regression (hooks got slower), investigate and fix before proceeding.

## Phase 5: Update Tracking

Append a new entry to `docs/plans/cc-hooks-audit-tracking.md`. Include the ACTUAL measurements from the comparison script:

```markdown
### Iteration N (YYYY-MM-DD)

**Dimensions Audited:** [list]
**Findings:** X (Y HIGH, Z MEDIUM)
**Fixed:** A
**Deferred:** B

#### Performance Profile

| Hook (event → matcher) | Baseline (median ms) | After (median ms) | Delta | % Change |
|------------------------|---------------------|---------------------|-------|----------|
| <paste comparison table from compare-profiles.sh> |

#### Configuration Changes

- [x] Description (dimension: X, severity: HIGH/MEDIUM, measured impact: Xms → Yms)

#### Deferred

- [ ] Description (dimension: X, severity: Y, reason)

#### Dimensions Remaining

- [list of unaudited dimensions]
```

## Phase 6: Signal

Completion requires BOTH conditions:
1. All 6 CC hooks dimensions have been audited (check tracking file)
2. No HIGH or MEDIUM findings remain unfixed

**If both conditions met**, output exactly:

```
<promise>CC_HOOKS_OPTIMIZED</promise>
```

**If either condition is NOT met**, exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

Only output this promise if you genuinely audited all dimensions and verified no actionable findings remain.
