# CI Audit Dimensions

8 dimensions to evaluate, 1-2 per iteration. Check the tracking file to see which have been covered.

## D1: Path Filtering

**Goal:** Skip expensive jobs when changes don't warrant them.

**What to check:**
- Are E2E, integration, and DB test jobs gated by path filters (e.g., `dorny/paths-filter`)?
- Do docs-only, config-only, or CSS-only PRs skip heavy jobs?
- Are lint and unit tests still running on every PR (they should be)?

**What to fix:**
- Add `dorny/paths-filter` or `paths:` triggers to skip jobs when only non-code files change
- Ensure skip conditions propagate through `needs:` chains

## D2: Parallelization

**Goal:** Minimize wall-clock time by running independent jobs/steps concurrently.

**What to check:**
- Do lint and typecheck run as separate parallel jobs (or parallel steps via `&`)?
- Are E2E tests sharded across multiple runners?
- Are there serial bottleneck jobs that multiple downstream jobs `needs:`?

**What to fix:**
- Split sequential lint+typecheck into parallel jobs or concurrent steps
- Add E2E sharding with `strategy.matrix`
- Inline build steps into consuming jobs to eliminate serial bottleneck jobs

## D3: Dependency PR Handling

**Goal:** Don't burn CI minutes on PRs that will be reviewed/rolled up anyway.

**What to check:**
- Do Dependabot/Renovate PRs skip heavy CI (E2E, integration, build)?
- Is there a rollup or batch strategy for dependency updates?
- Are dependency PRs using the correct `permissions:` (some fail on secret access)?

**What to fix:**
- Add `if: github.actor != 'dependabot[bot]'` conditions to heavy jobs
- Configure Dependabot grouping in `dependabot.yml`
- Fix permission issues for automated PRs

## D4: Flakiness & Retries

**Goal:** Fix root causes of flaky tests rather than masking with retries.

**What to check:**
- What is the current retry count for test runners (Playwright `retries:`, Jest `--retry`)?
- What is the historical failure rate? (Check recent CI runs for patterns)
- Are there tests that fail intermittently on specific shards?

**What to fix:**
- Identify and fix root causes (race conditions, missing waits, shared state)
- After fixing, reduce retry count (2→1 or 1→0)
- Add test isolation (unique data per test, proper teardown)

## D5: Timeouts & Pinning

**Goal:** Prevent runaway jobs and dependency drift.

**What to check:**
- Does every job have `timeout-minutes` set?
- Are GitHub Actions (e.g., `actions/setup-node`) pinned to specific versions or using floating tags?
- Are CLI tools (Supabase CLI, Playwright) pinned to specific versions?
- Is the Node.js version current?

**What to fix:**
- Add `timeout-minutes` to every job (lint: 5, unit: 10, E2E: 20, etc.)
- Pin actions to SHA or major version
- Pin CLI tool versions in workflow files

## D6: Concurrency & Cancellation

**Goal:** Don't waste minutes on superseded runs.

**What to check:**
- Are concurrency groups defined for PR workflows?
- Do superseded PR runs auto-cancel (`cancel-in-progress: true`)?
- Is the main/production branch protected from cancellation?

**What to fix:**
- Add `concurrency:` block with `group: ${{ github.workflow }}-${{ github.ref }}`
- Set `cancel-in-progress: true` for PR workflows
- Set `cancel-in-progress: false` for main/production

## D7: DRY Infrastructure

**Goal:** Eliminate config duplication across workflows.

**What to check:**
- Are there repeated setup steps (checkout + setup-node + install) across multiple jobs?
- Are service configurations (Supabase CLI flags, database URLs) duplicated?
- Could composite actions consolidate shared setup?

**What to fix:**
- Create composite actions in `.github/actions/` for shared setup
- Use workflow-level `env:` for shared variables
- Extract reusable workflows for common patterns

## D8: Caching & Artifacts

**Goal:** Minimize redundant work across jobs and runs.

**What to check:**
- Is `node_modules` or the package manager cache configured (`actions/setup-node` with `cache:`)?
- Are build outputs (`.next/cache`, `dist/`) cached between runs?
- Are Playwright browsers cached or downloaded fresh each run?
- Are test reports/artifacts uploaded efficiently (not uploading on success if not needed)?

**What to fix:**
- Enable package manager caching in `actions/setup-node`
- Add build cache for framework-specific outputs
- Cache Playwright browser binaries
- Use `if: failure()` for artifact uploads that are only needed on failure
