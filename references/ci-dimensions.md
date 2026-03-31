# CI Audit Dimensions

9 dimensions to evaluate, 1-2 per iteration. Check the tracking file to see which have been covered.

Each dimension lists its **measurement axis** — the metric used to evaluate improvement:

- **Wall-clock**: Job duration deltas (seconds) from before/after CI runs
- **Billable**: Estimated runner-minutes saved (accounts for runner multipliers)
- **Hygiene**: Checklist of configuration best practices (pass/fail items)
- **Flakiness**: Retry configuration and historical failure rates

---

## D1: Caching & Artifacts

**Measurement axis:** Wall-clock, Billable

**Goal:** Minimize redundant work across jobs and runs.

**What to check:**
- Is `node_modules` or the package manager cache configured (`actions/setup-node` with `cache:`)?
- Are build outputs (`.next/cache`, `dist/`) cached between runs?
- Are Playwright browsers cached or downloaded fresh each run?
- Are test reports/artifacts uploaded efficiently (not uploading on success if not needed)?
- Are Docker layers cached for containerized builds?

**What to fix:**
- Enable package manager caching in `actions/setup-node`
- Add build cache for framework-specific outputs
- Cache Playwright browser binaries
- Use `if: failure()` for artifact uploads that are only needed on failure

## D2: Path Filtering

**Measurement axis:** Wall-clock, Billable

**Goal:** Skip expensive jobs when changes don't warrant them.

**What to check:**
- Are E2E, integration, and DB test jobs gated by path filters (e.g., `dorny/paths-filter`)?
- Do docs-only, config-only, or CSS-only PRs skip heavy jobs?
- Are lint and unit tests still running on every PR (they should be)?

**What to fix:**
- Add `dorny/paths-filter` or `paths:` triggers to skip jobs when only non-code files change
- Ensure skip conditions propagate through `needs:` chains

## D3: Parallelization

**Measurement axis:** Wall-clock

**Goal:** Minimize wall-clock time by running independent jobs/steps concurrently.

**What to check:**
- Do lint and typecheck run as separate parallel jobs (or parallel steps via `&`)?
- Are E2E tests sharded across multiple runners?
- Are there serial bottleneck jobs that multiple downstream jobs `needs:`?

**What to fix:**
- Split sequential lint+typecheck into parallel jobs or concurrent steps
- Add E2E sharding with `strategy.matrix`
- Inline build steps into consuming jobs to eliminate serial bottleneck jobs

## D4: Concurrency & Cancellation

**Measurement axis:** Billable

**Goal:** Don't waste minutes on superseded runs.

**What to check:**
- Are concurrency groups defined for PR workflows?
- Do superseded PR runs auto-cancel (`cancel-in-progress: true`)?
- Is the main/production branch protected from cancellation?

**What to fix:**
- Add `concurrency:` block with `group: ${{ github.workflow }}-${{ github.ref }}`
- Set `cancel-in-progress: true` for PR workflows
- Set `cancel-in-progress: false` for main/production

## D5: Dependency PR Handling

**Measurement axis:** Billable

**Goal:** Don't burn CI minutes on PRs that will be reviewed/rolled up anyway.

**What to check:**
- Do Dependabot/Renovate PRs skip heavy CI (E2E, integration, build)?
- Is there a rollup or batch strategy for dependency updates?
- Are dependency PRs using the correct `permissions:` (some fail on secret access)?

**What to fix:**
- Add `if: github.actor != 'dependabot[bot]'` conditions to heavy jobs
- Configure Dependabot grouping in `dependabot.yml`
- Fix permission issues for automated PRs

## D6: Flakiness & Retry Config

**Measurement axis:** Flakiness

**Goal:** Detect flaky tests and right-size retry configuration. Do NOT attempt to fix test code — report flaky tests for manual investigation.

**What to check:**
- What is the current retry count for test runners (Playwright `retries:`, Jest `--retry`)?
- What is the historical failure rate per job? (Query recent CI runs)
- Are excessive retries masking real failures (e.g., `retries: 3` when most tests pass)?
- Are there jobs with >10% failure rate in the last 20 runs?

**What to do:**
- Run `./scripts/ci/score-flakiness.sh --repo <OWNER/REPO> --runs 20` to collect failure rates
- Reduce excessive retry counts (e.g., `retries: 3` → `retries: 1`) if failure rate is low
- Document jobs with >10% failure rate in the tracking file for manual investigation
- Do NOT modify test source code — scope is limited to workflow YAML and runner config

## D7: Timeouts & Pinning

**Measurement axis:** Hygiene

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

**Run hygiene check:** `./scripts/ci/score-hygiene.sh --dir .github/workflows`

## D8: DRY Infrastructure

**Measurement axis:** Hygiene

**Goal:** Eliminate config duplication across workflows.

**What to check:**
- Are there repeated setup steps (checkout + setup-node + install) across multiple jobs?
- Are service configurations (Supabase CLI flags, database URLs) duplicated?
- Could composite actions consolidate shared setup?

**What to fix:**
- Create composite actions in `.github/actions/` for shared setup
- Use workflow-level `env:` for shared variables
- Extract reusable workflows for common patterns

## D9: Secrets & Permissions

**Measurement axis:** Hygiene

**Goal:** Follow principle of least privilege for workflow permissions and secrets.

**What to check:**
- Do workflows declare explicit `permissions:` blocks (at workflow or job level)?
- Are permissions scoped to the minimum needed (e.g., `contents: read` not default write-all)?
- Are secrets scoped to environments rather than globally available?
- Is `GITHUB_TOKEN` using default permissions or restricted?
- Are third-party actions that receive secrets pinned to SHA (supply chain risk)?

**What to fix:**
- Add explicit `permissions:` blocks to every workflow and/or job
- Scope each permission to the minimum required (read vs write)
- Move secrets to environment-scoped secrets where applicable
- Pin any action that receives secrets to a commit SHA
- Add `permissions: {}` at workflow level and grant per-job where needed (deny-by-default)

**Run hygiene check:** `./scripts/ci/score-hygiene.sh --dir .github/workflows`
