---
name: security-audit
description: "This command should be used when the user asks to 'run a security audit', 'check for OWASP vulnerabilities', 'find security issues', or 'harden the app'. Runs one iteration: systematically checks 1-2 OWASP categories, fixes issues, validates, PRs, runs CI, and merges."
---

# Security Audit — Full Cycle

You are performing one complete security audit iteration. Report progress at each phase.

## Phase 1: Setup

1. Ensure you are on main with the latest code:
   ```bash
   git checkout main && git pull origin main
   ```

2. Read `docs/plans/security-audit-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it:
   ```markdown
   # Security Audit Tracking

   Automated OWASP-aligned security audit. 10 categories to cover.

   ---

   ## Iteration Log
   ```

3. Create an iteration branch:
   ```bash
   git checkout -b security-audit/iteration-<N>
   ```

4. Review which categories were already audited in prior iterations. Pick the next 1-2 unaudited categories from the list below.

## Phase 2: Audit Categories

Work through 1-2 categories per iteration, thoroughly. Read every relevant file.

### Category List

| # | Category | What to check | OWASP |
|---|----------|---------------|-------|
| 1 | **Auth & Access Control** | Every mutation requires authentication. Every query scopes data to the authenticated user/tenant. No privilege escalation paths. No way to access another user's data. | A01 |
| 2 | **Input Validation** | All user inputs validated before use (Zod, Joi, or equivalent). No raw string interpolation in queries. Max lengths enforced. Enum validation on constrained fields. | A03 |
| 3 | **Authorization & Row-Level Security** | Database-level authorization (RLS policies, tenant scoping) on every table. All CRUD operations have policies. Privacy filters on sensitive data. | A01 |
| 4 | **Secret Management** | No hardcoded secrets. No secrets in client bundles or public env vars. Secrets validated before use. Service keys restricted to server-only code. | A02 |
| 5 | **Security Headers** | CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy present and restrictive. All responses include headers. | A05 |
| 6 | **Dependency Vulnerabilities** | Run `npm audit` (or equivalent). Check for known CVEs. Apply non-breaking fixes. Flag breaking changes as deferred. | A06 |
| 7 | **Rate Limiting** | Check all public-facing endpoints. Identify unprotected surfaces. Add rate limiting where straightforward. | A04 |
| 8 | **Error Handling** | No stack traces or internal details in error responses. Generic messages for auth failures. No database details leaked. | A09 |
| 9 | **CSRF/Session** | Auth cookies use HttpOnly + Secure + SameSite. No session tokens in URLs. Session refresh on every request. No session fixation vectors. | A07 |
| 10 | **Data Exposure** | No sensitive data in logs. No PII in URL parameters. Data export requires auth. Privacy flags respected in all queries. | A02 |

### How to Audit Each Category

For each category:
1. **Identify relevant files** — check project structure, find all files that touch this category
2. **Read every relevant file** — don't sample, be exhaustive
3. **Check positive cases** — verify the pattern IS applied where it should be
4. **Check negative cases** — verify the pattern is NOT violated anywhere
5. **Classify findings**: HIGH (exploitable vulnerability, missing auth), MEDIUM (defense-in-depth gap, missing rate limit), LOW (minor hardening opportunity)

## Phase 3: Fix

1. List ALL findings across audited categories
2. Classify by severity (HIGH, MEDIUM, LOW)
3. Fix all HIGH and MEDIUM findings
4. For enhancements (new rate limiting, audit logging): implement if straightforward (< 50 lines), defer if complex
5. For dependency vulnerabilities: apply non-breaking fixes, flag breaking as deferred
6. **Never weaken existing security to fix something else**
7. Cap at ~12 files per iteration; defer the rest

## Phase 4: Validate

Follow the **Validate** phase in `references/common-lifecycle.md`. Security fixes are particularly likely to break E2E tests — check for stale assertions on auth flows, headers, and redirects.

## Phase 5: Update Tracking

Append a new entry to `docs/plans/security-audit-tracking.md`:

```markdown
### Iteration N (YYYY-MM-DD)

**Categories Audited:** [list]
**Findings:** X (Y HIGH, Z MEDIUM)
**Fixed:** A
**Deferred:** B

#### Fixed

- [x] Description (category: X, severity: HIGH/MEDIUM)

#### Deferred

- [ ] Description (category: X, severity: Y, reason)

#### Categories Remaining

- [list of unaudited categories]
```

## Phase 6: Ship

**If issues were found and fixed:** follow the **Ship** phase in `references/common-lifecycle.md` with:
- **Branch:** `security-audit/iteration-<N>`
- **Commit:** `security: fix findings from security audit iteration N`
- **PR title:** `Security Audit: Iteration N`
- **PR body:** `Automated OWASP security audit. See docs/plans/security-audit-tracking.md for details.`

**If NO issues found AND all 10 categories audited:** skip to Phase 8.

## Phase 7: CI & Merge

Follow the **CI & Merge** phase in `references/common-lifecycle.md`.

## Phase 8: Signal

Completion requires ALL conditions:
1. All 10 OWASP categories have been audited (check tracking file)
2. No HIGH or MEDIUM findings remain unfixed
3. This iteration found zero new findings — if this iteration found and fixed issues, exit normally so the next iteration can verify the fixes from scratch

**If both conditions met**, output exactly:

```
<promise>NO_ISSUES</promise>
```

**If either condition is NOT met**, exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

Only output this promise if you genuinely audited all categories and verified no actionable findings remain.
