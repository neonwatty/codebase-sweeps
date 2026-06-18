# useful-loops

[![Discord](https://img.shields.io/badge/Discord-Join%20Server-7289da?style=flat&logo=discord&logoColor=white)](https://discord.gg/7xsxU4ZG6A)

A Claude Code plugin for autonomous, iterative codebase improvement. Runs gap analysis, test coverage, security audits, beta-readiness audits, service health audits, funnel audits, plan refinement, document refinement, plan-to-plan alignment, mockup generation, and prototype building in loops that find issues, fix them, PR, pass CI, merge, and repeat.

Designed to work with the [Ralph Loop](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-loop) plugin for automated iteration.

## Install

```bash
claude plugin marketplace add neonwatty/useful-loops
claude plugin install useful-loops@useful-loops
```

Also install the Ralph Loop plugin if you want looping:

```bash
claude plugin install ralph-loop
```

## Commands

### Single Iteration (run once)

| Command | Description |
|---------|-------------|
| `/useful-loops:gap-analysis <repo-url>` | Compare this app against a reference app, fix gaps |
| `/useful-loops:test-coverage [threshold]` | Find untested files, write tests (default: 80%) |
| `/useful-loops:security-audit` | Audit 1-2 OWASP categories, fix findings |
| `/useful-loops:beta-audit` | Holistic beta-readiness review across 5 dimensions |
| `/useful-loops:service-audit` | Audit Vercel, Supabase, PostHog, Sentry, GitHub for issues |
| `/useful-loops:funnel-audit` | Audit one top-of-funnel marketing category, fix issues |
| `/useful-loops:ci-audit <OWNER/REPO> [--branch BRANCH]` | Audit 1-2 CI dimensions, measure and fix, re-measure |
| `/useful-loops:plan-to-plan <source> <target>` | Align a derived plan against its source plan (interactive) |
| `/useful-loops:mockup-from-plan <plan> <mockup-dir>` | Build/refine an HTML mockup from a plan document (interactive) |
| `/useful-loops:prototype-from-mockup <mockup-dir> <app-dir>` | Build/refine an app prototype from an HTML mockup (interactive) |

### Looped (requires ralph-loop plugin)

| Command | Description |
|---------|-------------|
| `/useful-loops:gap-loop <repo-url> [--max N]` | Loop gap analysis until no gaps remain |
| `/useful-loops:test-loop [threshold] [--max N]` | Loop test coverage until threshold met |
| `/useful-loops:security-loop [--max N]` | Loop security audit until all categories clean |
| `/useful-loops:beta-audit-loop [--max N]` | Loop beta audit until no HIGH/MEDIUM code findings |
| `/useful-loops:service-audit-loop [--max N]` | Loop service audit until no CRITICAL/HIGH findings |
| `/useful-loops:funnel-loop` | Guide for running funnel audit iterations (interactive, not automated) |
| `/useful-loops:ci-loop <OWNER/REPO> [--max N]` | Loop CI audit until all 9 dimensions are covered (default max: 9) |
| `/useful-loops:plan-to-plan-loop <source> <target> [--max N]` | Loop plan-to-plan until target fully covers source |
| `/useful-loops:mockup-from-plan-loop <plan> <mockup-dir> [--max N]` | Loop mockup-from-plan until mockup matches plan |
| `/useful-loops:prototype-from-mockup-loop <mockup-dir> <app-dir> [--max N]` | Loop prototype-from-mockup until prototype matches mockup |

Default max iterations: 10 (except ci-loop which defaults to 9).

### Self-Contained (single iteration, no Ralph Loop dependency)

| Command | Description |
|---------|-------------|
| `/useful-loops:plan-refine "<PROMPT>" <PLAN>` | Refine a plan document or directory using a prompt-driven analysis |
| `/useful-loops:doc-refine "<PROMPT>" <DOC_FILE>` | Refine a document using a prompt-driven analysis |

### Self-Contained Loops (requires ralph-loop plugin)

| Command | Description |
|---------|-------------|
| `/useful-loops:plan-refine-loop "<PROMPT>" <PLAN> [--max N]` | Loop plan-refine until no improvements found |
| `/useful-loops:doc-refine-loop "<PROMPT>" <DOC_FILE> [--max N]` | Loop doc-refine until no improvements found |

## How It Works

Each skill follows an 8-phase lifecycle per iteration:

1. **Setup** — checkout main, create iteration branch, read tracking file
2. **Analyze** — domain-specific analysis (compare repos, find untested files, audit security)
3. **Fix** — prioritize and fix HIGH/MEDIUM issues (cap ~12 files per iteration)
4. **Validate** — run lint, typecheck, tests
5. **Track** — append results to tracking file in `docs/plans/`
6. **Ship** — commit, push, create PR
7. **CI & Merge** — poll CI, fix failures, squash-merge when green
8. **Signal** — exit normally (more work to do) or emit completion promise (done)

When run in a Ralph Loop, the same prompt is fed back after each iteration. Claude sees its previous work via the tracking files and git history, focusing on uncovered ground each time.

### Tracking Files

Each skill maintains a tracking file in `docs/plans/`:

- `gap-tracking.md` — gap analysis iterations
- `test-coverage-tracking.md` — test coverage iterations
- `security-audit-tracking.md` — security audit iterations
- `beta-audit-tracking.md` — beta audit iterations
- `beta-manual-todos.md` — accumulating manual to-do checklist from beta audits
- `service-audit-tracking.md` — service health audit iterations
- `service-audit-manual-todos.md` — accumulating manual to-do checklist from service audits
- `funnel-audit-tracking.md` — funnel audit iterations
- `ci-audit-tracking.md` — CI audit iterations and measurements
- `plan-refine-tracking.md` — plan refinement iterations
- `doc-refine-tracking.md` — document refinement iterations
- `plan-to-plan-tracking.md` — plan-to-plan alignment iterations
- `mockup-from-plan-tracking.md` — mockup generation iterations
- `prototype-from-mockup-tracking.md` — prototype building iterations

These files are created automatically on first run and serve as inter-iteration memory.

## Skills Detail

### Gap Analysis

Compares your app against a reference implementation across 6 dimensions:

- Pages & Routes
- Components
- Styling & Visual Design
- Content & Copy
- UX Flows & Interactions
- Assets & Media

Adapts client-side patterns for your architecture (e.g., converting mock data to real queries, client components to server components).

**Completion:** `NO_GAPS_FOUND` when all 6 dimensions are clean.

### Test Coverage

Finds untested files and writes tests in priority order:

- P0: Server actions, API routes, mutation handlers
- P1: Shared utilities and library code
- P2: State management (contexts, stores)
- P3: Custom hooks
- P4: Middleware, auth, route guards
- P5: Email/notification templates

**Completion:** `FULL_COVERAGE` when all P0-P5 files have tests AND coverage >= threshold.

### Security Audit

OWASP-aligned audit covering 10 categories (1-2 per iteration):

1. Auth & Access Control (A01)
2. Input Validation (A03)
3. Authorization / Row-Level Security (A01)
4. Secret Management (A02)
5. Security Headers (A05)
6. Dependency Vulnerabilities (A06)
7. Rate Limiting (A04)
8. Error Handling (A09)
9. CSRF/Session (A07)
10. Data Exposure (A02)

**Completion:** `NO_ISSUES` when all 10 categories audited with no HIGH/MEDIUM findings.

### Beta Audit

Holistic beta-readiness review using 5 parallel explorer agents:

- Feature Completeness — incomplete flows, placeholder data, dead-end UX, compliance gaps
- Error Handling & Edge Cases — missing loading/empty states, validation gaps, network failures
- Polish & UX Quality — accessibility, styling consistency, mobile responsiveness, dead features
- Ops & Infra Readiness — monitoring, email deliverability, production safety guards, rate limiting
- Performance — redundant API calls, unparallelized queries, deferred loading opportunities

Findings are classified by severity (HIGH/MEDIUM/LOW) and type (CODE/MANUAL). Code issues are fixed in the PR. Manual to-dos (service provider config, deployment settings, etc.) are collected into a separate `docs/plans/beta-manual-todos.md` checklist that accumulates across iterations.

**Completion:** `BETA_READY` when no HIGH/MEDIUM code findings remain across all 5 dimensions.

### Service Audit

Checks the health of your service stack (Vercel, Supabase, PostHog, Sentry, GitHub) using a combination of codebase inspection, CLIs/APIs, and browser dashboard checks. Auto-detects which services your project uses by scanning `package.json`, env files, and config files.

Findings are classified by severity (CRITICAL/HIGH/MEDIUM/LOW) and type:

- **CODE** — auto-fixed in the codebase (SDK updates, config fixes, migration files)
- **BROWSER** — fixed interactively via Claude-in-Chrome with user confirmation
- **MANUAL** — collected into `docs/plans/service-audit-manual-todos.md` for human action

**Services & checks:**

- **Vercel** — deployment failures, build warnings, env var drift, config issues, function limits, domain/SSL
- **Supabase** — missing RLS, permissive policies, missing indexes, auth config, storage permissions, migration drift
- **PostHog** — unnamed events, stale feature flags, inconsistent event properties
- **Sentry** — unresolved errors, high-frequency issues, outdated SDK, missing source maps, web vitals
- **GitHub** — failing CI, deprecated actions, dependabot alerts, stale branches, unreviewed PRs, branch protection

**Completion:** `SERVICES_HEALTHY` when all detected services are swept with no CRITICAL/HIGH code findings remaining.

### Funnel Audit

Top-of-funnel marketing audit covering 7 categories (1 per iteration):

1. CTAs & Conversion Points — CTA presence, copy, placement, contrast, mobile-friendliness
2. Referral & Viral Mechanics — share functionality, invite flows, branding on shared content
3. Email Capture & Lead Nurture — capture points, triggers, value props, cooldowns
4. Onboarding & Activation — first-run experience, progress indicators, empty states, time-to-value
5. SEO & Content Discoverability — meta tags, structured data, sitemaps, OG metadata, internal linking
6. Demo-to-Signup Funnel — demo accessibility, feature gating, signup nudges, work preservation
7. Shareable & Exportable Content — branding on exports, attribution, CTAs for share recipients

Each category is checked against a built-in best-practices checklist. Findings are classified as HIGH (missing/broken conversion path), MEDIUM (suboptimal but functional), or LOW (nice-to-have polish). HIGH and MEDIUM findings are fixed; LOW are deferred.

**Completion:** `FUNNEL_OPTIMIZED` when all 7 categories audited with no HIGH/MEDIUM findings.

### Plan Refine

Iteratively improves a plan document or directory of plan documents in-place by applying a user-provided analysis prompt. Each iteration reads the plan, identifies improvements (classified HIGH/MEDIUM/LOW), applies all changes directly, and tracks what was changed. Runs as a self-contained loop — no Ralph Loop dependency, no git branching or PRs.

- Prompt-driven: analysis focus is entirely controlled by the user's prompt
- In-place editing: changes the plan file(s) directly, no branches or PRs
- File or directory: accepts a single `.md` file or a directory of `.md` files
- Tracked: maintains iteration log in `docs/plans/plan-refine-tracking.md`

**Completion:** `PLAN_REFINED` when no improvements are found at any severity level.

### Doc Refine

Iteratively improves a document in-place by applying a user-provided analysis prompt. Same self-contained loop as Plan Refine but with document-oriented severity definitions focused on readability, tone, audience-awareness, and comprehension rather than structural completeness.

- Prompt-driven: analysis focus is entirely controlled by the user's prompt
- Voice-preserving: edits improve readability without changing the document's intent or personality
- Tracked: maintains iteration log in `docs/plans/doc-refine-tracking.md`

**Completion:** `DOC_REFINED` when no improvements are found at any severity level.

### Plan-to-Plan

Aligns a derived plan (target) against its source plan across 5 dimensions:

- Coverage — does the target address every item from the source?
- Depth — does the target elaborate sufficiently at its level of abstraction?
- Accuracy — does the target faithfully represent the source's intent?
- Completeness — are there internal gaps within the target?
- Standalone Clarity — could someone read the target alone and fully understand it?

Handles abstraction shifts (e.g., PRD to screen plan, screen plan to technical spec). Target can be a single file or a directory of `.md` files.

**Completion:** `PLANS_ALIGNED` when no gaps found across all 5 dimensions.

### Mockup-from-Plan

Builds and refines an HTML/CSS/JS mockup to match a plan document across 6 dimensions:

- Pages & Sections — all pages/screens from the plan exist as HTML files
- Components & Elements — all UI elements described in the plan are present
- Layout & Structure — page structure matches the plan's specifications
- Content & Copy — text, labels, and placeholder content match the plan
- Interactions & States — JavaScript behaviors match the plan's interaction descriptions
- Styling & Visual Design — colors, fonts, spacing match any design specs in the plan

**Completion:** `MOCKUP_MATCHES_PLAN` when the mockup faithfully represents everything in the plan.

### Prototype-from-Mockup

Translates an HTML/CSS/JS mockup into a real app prototype across 6 dimensions:

- Pages & Routes — all mockup pages have corresponding app routes
- Components — all UI components from the mockup are implemented
- Layout & Structure — page structure matches the mockup
- Styling & Visual Fidelity — colors, fonts, spacing match exact values from mockup CSS
- Interactions & State — interactive elements work as they do in the mockup
- Data & Backend — mockup data is connected to the app's existing data layer

Follows the app's existing conventions (framework, CSS approach, data layer) rather than imposing new patterns.

**Completion:** `PROTOTYPE_MATCHES_MOCKUP` when no gaps found across all 6 dimensions.

### CI Audit

Script-driven CI pipeline optimization across 9 dimensions and 4 measurement axes:

**Dimensions:**
1. D1: Caching & Artifacts (Wall-clock, Billable)
2. D2: Path Filtering (Wall-clock, Billable)
3. D3: Parallelization (Wall-clock, Billable)
4. D4: Concurrency & Cancellation (Billable)
5. D5: Dependency PR Handling (Wall-clock, Billable)
6. D6: Flakiness (Flakiness)
7. D7: Security Hardening (Hygiene)
8. D8: DRY Infrastructure (Hygiene)
9. D9: Runner Optimization (Hygiene)

**Measurement axes:** Wall-clock timing | Billable minutes | Hygiene checklist | Flakiness score

All detection is script-driven (no LLM judgment for finding issues). Scripts in `scripts/ci/` run deterministic static analysis and GitHub API queries. Audits 1-2 dimensions per iteration, measures before and after, and reports empirical deltas.

**Completion:** `CI_OPTIMIZED` when all 9 dimensions are audited with no HIGH/MEDIUM findings.

## Examples

```bash
# Single CI audit iteration
/useful-loops:ci-audit owner/repo

# Loop CI audit across all 9 dimensions
/useful-loops:ci-loop owner/repo --max 9

# Single gap analysis iteration against a reference app
/useful-loops:gap-analysis https://github.com/org/reference-app

# Loop test coverage to 90% with max 15 iterations
/useful-loops:test-loop 90 --max 15

# Loop security audit with defaults (10 iterations)
/useful-loops:security-loop

# Single beta audit iteration
/useful-loops:beta-audit

# Loop beta audit with max 8 iterations
/useful-loops:beta-audit-loop --max 8

# Single service health audit
/useful-loops:service-audit

# Loop service audit with max 5 iterations
/useful-loops:service-audit-loop --max 5

# Single funnel audit iteration
/useful-loops:funnel-audit

# Run funnel audit interactively (one category at a time)
/useful-loops:funnel-loop

# Single plan-refine iteration (single file)
/useful-loops:plan-refine "examine for gaps in error handling" docs/plans/architecture.md

# Single plan-refine iteration (directory of plan files)
/useful-loops:plan-refine "examine for gaps in error handling" docs/plans/architecture/

# Loop plan-refine with max 3 iterations
/useful-loops:plan-refine-loop "examine for gaps in error handling" docs/plans/architecture.md --max 3

# Single doc-refine iteration
/useful-loops:doc-refine "improve readability for non-technical audience" docs/user-guide.md

# Align a screen plan against a PRD
/useful-loops:plan-to-plan docs/plans/prd.md docs/plans/screen-plan.md

# Loop plan-to-plan until fully aligned
/useful-loops:plan-to-plan-loop docs/plans/prd.md docs/plans/screen-plan/

# Build a mockup from a plan
/useful-loops:mockup-from-plan docs/plans/screen-plan.md mockup/

# Build a prototype from a mockup
/useful-loops:prototype-from-mockup mockup/ .
```

## License

MIT
