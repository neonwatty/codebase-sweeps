# Git Hooks Audit Dimensions

6 dimensions to evaluate, 1-2 per iteration. Check the tracking file to see which have been covered.

## D1: Scope Filtering

**Goal:** Hooks should only process files that are actually affected, not the entire repo.

**What to check:**
- Is `lint-staged` (or equivalent) used to scope linting/formatting to staged files only?
- Are there hooks running full-repo commands (`eslint .` instead of `eslint --staged`)?
- Does the typecheck run on all files or only affected ones?
- Are there file-type filters so irrelevant files are skipped (e.g., don't lint `.md` files with ESLint)?

**What to fix:**
- Install and configure `lint-staged` if not present
- Replace full-repo lint/format commands with staged-file-scoped equivalents
- Add appropriate glob patterns to lint-staged config

## D2: Parallelization

**Goal:** Run independent checks concurrently to minimize wall-clock time.

**What to check:**
- Does lint-staged run tasks concurrently (`--concurrent` flag, default is true)?
- Are independent checks (lint, format, type) configured as separate lint-staged entries?
- Are there sequential `&&` chains in hook scripts that could run in parallel?

**What to fix:**
- Ensure lint-staged `concurrent` is not set to `false`
- Split combined commands into separate lint-staged entries for parallelism
- Use `concurrently` or background processes (`&` + `wait`) for non-lint-staged hooks

## D3: CI Redundancy

**Goal:** Don't duplicate work locally that CI already catches reliably.

**What to check:**
- Is the full test suite running in pre-push AND in CI? (Redundant)
- Is a full build running in hooks? (Usually CI-only)
- Are there checks that only make sense in CI (coverage thresholds, bundle size)?

**What to fix:**
- Remove full test suite from pre-push if CI runs it on every PR
- Keep only fast, high-signal checks locally (lint staged files, typecheck)
- Move build, coverage, and bundle checks to CI-only

## D4: Graduated Enforcement

**Goal:** Put lightweight checks in pre-commit and heavier checks in pre-push.

**What to check:**
- Is typecheck running in pre-commit? (Should be pre-push — it's slow and operates on all files)
- Are fast formatters (Prettier) in pre-commit? (Good)
- Are slow linters in pre-commit when they should be in pre-push?
- Is there a pre-push hook at all, or is everything crammed into pre-commit?

**Recommended graduation:**
| Hook | What belongs here |
|------|-------------------|
| pre-commit | Format staged files (Prettier), lint staged files (ESLint --fix) |
| pre-push | Typecheck (tsc --noEmit), fast unit tests (optional) |
| CI only | Full test suite, E2E, build, coverage, bundle size |

**What to fix:**
- Move typecheck from pre-commit to pre-push
- Move test suite from hooks to CI
- Ensure pre-commit stays under ~5s for good DX

## D5: Escape Hatches & DX

**Goal:** Hooks should help, not frustrate developers.

**What to check:**
- Is `--no-verify` documented somewhere for emergencies?
- Do hook failures give clear, actionable error messages?
- Are there hooks that silently modify files without explaining what changed?
- Is there a way to run hooks manually for debugging (`git hook run pre-commit`)?

**What to fix:**
- Add a note in CONTRIBUTING.md about `--no-verify` for urgent hotfixes
- Ensure hook scripts print which check failed and why
- Add `--verbose` or `--debug` flags to hook scripts for troubleshooting

## D6: Tool Versions & Overhead

**Goal:** Minimize startup cost and avoid version drift.

**What to check:**
- Are hooks using `npx` (cold start penalty) or project-local binaries (`./node_modules/.bin/`)?
- Is there unnecessary overhead from Husky's shell initialization?
- Are hook tools (ESLint, Prettier) using the same versions as CI?
- Is the `.husky/` structure current (Husky v9+ uses simple shell scripts)?

**What to fix:**
- Replace `npx lint-staged` with `./node_modules/.bin/lint-staged` to avoid npx resolution
- Upgrade to Husky v9+ if on older version (simpler, less overhead)
- Ensure package.json tool versions match CI
- Consider `prek` as a faster alternative to `pre-commit` (Python ecosystem)
