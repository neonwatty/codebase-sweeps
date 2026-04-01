---
name: gap-analysis
description: "This command should be used when the user asks to 'run a gap analysis', 'compare against a reference app', 'find gaps versus a reference', or 'close feature gaps'. Runs one iteration: compares this app against a reference app, fixes gaps, validates, PRs, runs CI, and merges."
argument-hint: "REFERENCE_REPO_URL"
---

# Gap Analysis — Full Cycle

You are performing one complete gap analysis iteration. Report progress at each phase.

**Reference repo:** `$ARGUMENTS`

If no reference repo URL was provided above, check `docs/plans/gap-tracking.md` for the reference repo URL from prior iterations. If still not found, ask the user.

## Phase 1: Setup

1. Ensure you are on main with the latest code:
   ```bash
   git checkout main && git pull origin main
   ```

2. Read `docs/plans/gap-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it:
   ```markdown
   # Gap Analysis Tracking

   Automated tracking of gaps found between this app and the reference app.

   **Reference:** <reference repo URL>

   ---

   ## Iteration Log
   ```

3. Create an iteration branch:
   ```bash
   git checkout -b gap-analysis/iteration-<N>
   ```

4. Clone or update the reference app:
   ```bash
   REFERENCE_DIR="/tmp/reference-app-$(echo '<REFERENCE_REPO_URL>' | md5sum | cut -c1-8 || echo 'default')"
   git clone <REFERENCE_REPO_URL> "$REFERENCE_DIR" 2>/dev/null || git -C "$REFERENCE_DIR" pull origin main
   ```
   Use `$REFERENCE_DIR` (or the resolved path) in all subsequent references to the reference app.

5. Review which dimensions and files were already covered in prior iterations. Focus effort on uncovered ground.

## Phase 2: Systematic Comparison

Compare these six dimensions. For each, read the relevant source files in **both** repos. Use explorer agents in parallel to cover more ground.

1. **Pages & Routes** — Compare all pages in the reference app to this app. Missing pages, incomplete pages, layout differences.
2. **Components** — Compare component structure, props, variants, rendered output. Missing components, missing variants.
3. **Styling & Visual Design** — Compare Tailwind classes, colors, spacing, typography, responsive breakpoints, animations.
4. **Content & Copy** — Compare headings, labels, descriptions, button text, placeholders, error messages, empty states.
5. **UX Flows & Interactions** — Compare navigation, form behavior, loading states, transitions, modals.
6. **Assets & Media** — Compare icons, images, illustrations, SVGs.

### Exclusions

Tell explorer agents about these exclusions upfront so they don't waste time reporting them. Flag these in the tracking file as "intentionally skipped" rather than fixing:

- Test/demo pages that are prototype artifacts
- Test files using a different test framework than this project
- Mock data patterns if this project uses a real backend
- Architectural differences that are intentional (e.g., client-side localStorage vs server actions, mock data vs real backend queries)

## Phase 3: Prioritize & Fix

1. List ALL gaps found across all dimensions
2. Classify: **HIGH** (missing feature, broken UX, major visual diff), **MEDIUM** (styling mismatch, missing copy), **LOW** (minor text, subtle spacing)
3. Fix all HIGH and MEDIUM gaps
4. Cap at ~12 files per iteration. If more need changes, fix the highest priority ones and defer the rest.
5. Adapt reference app patterns for this project's architecture (e.g., client-side patterns may need server-side equivalents, mock data may need real queries).

**Constraints**: Follow this project's conventions (check CLAUDE.md if it exists). Do not modify database schema or migrations. Do not break existing tests — when you change content/copy, proactively update any unit tests AND E2E tests that assert on the old text.

## Phase 4: Validate

Follow the **Validate** phase in `references/common-lifecycle.md`. Also search E2E test files for old text that was replaced and update stale assertions.

## Phase 5: Update Tracking

Append a new entry to `docs/plans/gap-tracking.md`:

```markdown
### Iteration N (YYYY-MM-DD)

**Findings:** X
**Fixed:** Y
**Deferred:** Z
**Dimensions Covered:** [list which dimensions had gaps]

#### Fixed

- [x] Description (dimension: X, severity: HIGH/MEDIUM)

#### Deferred

- [ ] Description (reason)

#### Intentionally Skipped

- Description (reason)
```

## Phase 6: Ship

**If gaps were found and fixed:** follow the **Ship** phase in `references/common-lifecycle.md` with:
- **Branch:** `gap-analysis/iteration-<N>`
- **Commit:** `fix: close gaps from gap analysis iteration N`
- **PR title:** `Gap Analysis: Iteration N`
- **PR body:** `Automated gap analysis. See docs/plans/gap-tracking.md for details.`

**If NO gaps were found across all six dimensions:** skip to Phase 8.

## Phase 7: CI & Merge

Follow the **CI & Merge** phase in `references/common-lifecycle.md`.

## Phase 8: Signal

**If gaps were found and fixed:** exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

**If NO gaps were found across all six dimensions:** output exactly:

```
<promise>NO_GAPS_FOUND</promise>
```

Only output this promise if you genuinely compared all six dimensions and found nothing actionable. If coverage was incomplete, exit normally and let the next iteration continue.
