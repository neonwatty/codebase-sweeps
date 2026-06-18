---
name: plan-refine
description: "This command should be used when the user asks to 'refine a plan', 'improve this plan', 'polish a plan document', or 'apply a prompt to a plan'. Runs one iteration: applies a prompt-driven analysis to a plan document or directory of plan documents, identifies improvements, and applies them."
argument-hint: "\"PROMPT\" PLAN"
---

# Plan Refine

You are performing one complete plan-refine iteration. Apply the user's analysis prompt to the plan document, identify improvements, and apply them. Report progress at each phase.

Parse the arguments: extract the quoted PROMPT string and the PLAN path (either a single `.md` file or a directory of `.md` files). If the prompt is not quoted, treat everything before the last path-like argument as the prompt.

**Prompt:** `<PROMPT>`
**Plan:** `<PLAN>`

**Plan format:** The plan can be either:
- **A single file** (e.g., `architecture.md`) — all edits go to that file
- **A directory** (e.g., `plans/`) — contains multiple `.md` files. Edits go to the appropriate existing file. New `.md` files may be created if an improvement naturally belongs in a separate file, but do not create subdirectories.

Run Phases 1-5 once. If Phase 2 finds zero improvements, skip to Phase 5 (signal).

---

## Phase 1: Read

1. Read the plan at `<PLAN>`. If the path does not exist, stop and tell the user.
   - **Single file:** read the file
   - **Directory:** read every `.md` file in the directory and note the organizational scheme (how topics are split across files)

2. Read `docs/plans/plan-refine-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it (run `mkdir -p docs/plans` first if the directory does not exist):
   ```markdown
   # Plan Refine Tracking

   **Prompt:** "<user's prompt>"
   **Plan:** <path> (file / directory)

   ---

   ## Iteration Log
   ```

3. If this is iteration 2 or later, review the prior iteration entries in the tracking file. Understand what was already changed so you do not re-tread the same ground or revert prior improvements.

## Phase 2: Analyze

Apply the user's prompt to the current plan content. Read the plan carefully and identify specific, actionable improvements.

For each improvement found, classify its severity:
- **HIGH** — Structural issue, missing critical section, incorrect or misleading information, logical gap
- **MEDIUM** — Unclear wording, weak justification, missing detail, inconsistent formatting
- **LOW** — Minor phrasing, typos, stylistic polish, redundant wording

If zero improvements are found at any severity level, append a minimal tracking entry ("Iteration N: Zero improvements found — convergence achieved") to the tracking file, then skip to Phase 5 (signal).

If improvements were found, proceed to Phase 3.

## Phase 3: Edit

Apply ALL findings (HIGH, MEDIUM, and LOW) directly to the plan in-place. Prioritize HIGH findings first, then MEDIUM, then LOW. Each edit should be surgical: change only what the finding calls for without disrupting surrounding content.

**If plan is a single file:** edit `<PLAN>` directly in place. Do not create a copy or a new file.

**If plan is a directory:** place each fix in the most appropriate existing file based on topic. If an improvement doesn't fit naturally into any existing file, create a new `.md` file in the directory following the existing naming convention. Do not create subdirectories.

After all edits are applied, re-read the changed files to verify:
- The changes look correct and each document is coherent
- If a directory, cross-file references are accurate and no content is duplicated across files

## Phase 4: Track

Append an iteration entry to `docs/plans/plan-refine-tracking.md`:

```markdown
### Iteration N (YYYY-MM-DD)

**Findings:** X (Y HIGH, Z MEDIUM, W LOW)

#### Changes Applied

- [HIGH] Description of change
- [MEDIUM] Description of change
- [LOW] Description of change
```

## Phase 5: Signal

**If improvements were found and applied:** exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

**If NO improvements were found:** output exactly:

```
<promise>PLAN_REFINED</promise>
```

Only output this promise if you genuinely analyzed the full plan against the prompt and found nothing actionable.
