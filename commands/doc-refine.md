---
name: doc-refine
description: "This command should be used when the user asks to 'refine a document', 'improve this doc', 'polish documentation', or 'apply a prompt to a document'. Runs one iteration: applies a prompt-driven analysis to a document, identifies improvements, and applies them."
argument-hint: "\"PROMPT\" DOC_FILE"
---

# Doc Refine

You are performing one complete doc-refine iteration. Apply the user's analysis prompt to the document, identify improvements, and apply them. Report progress at each phase.

Parse the arguments: extract the quoted PROMPT string and the DOC_FILE path. If the prompt is not quoted, treat everything before the last path-like argument as the prompt.

**Prompt:** `<PROMPT>`
**Document file:** `<DOC_FILE>`

Run Phases 1-5 once. If Phase 2 finds zero improvements, skip to Phase 5 (signal).

---

## Phase 1: Read

1. Read the document file at `<DOC_FILE>`. If the file does not exist, stop and tell the user.

2. Read `docs/plans/doc-refine-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it (run `mkdir -p docs/plans` first if the directory does not exist):
   ```markdown
   # Doc Refine Tracking

   **Prompt:** "<user's prompt>"
   **Document File:** <path>

   ---

   ## Iteration Log
   ```

3. If this is iteration 2 or later, review the prior iteration entries in the tracking file. Understand what was already changed so you do not re-tread the same ground or revert prior improvements.

## Phase 2: Analyze

Apply the user's prompt to the current document content. Read the document carefully and identify specific, actionable improvements.

For each improvement found, classify its severity:
- **HIGH** — Confusing or misleading content, missing critical information, wrong audience level, structural issues that impede comprehension
- **MEDIUM** — Unclear wording, inconsistent tone, weak transitions, missing context, formatting issues
- **LOW** — Minor phrasing, redundancy, stylistic polish, typos

If zero improvements are found at any severity level, append a minimal tracking entry ("Iteration N: Zero improvements found — convergence achieved") to the tracking file, then skip to Phase 5 (signal).

If improvements were found, proceed to Phase 3.

## Phase 3: Edit

Apply ALL findings (HIGH, MEDIUM, and LOW) directly to the document file in-place. Edit the file at `<DOC_FILE>` — do not create a copy or a new file.

Prioritize HIGH findings first, then MEDIUM, then LOW. Each edit should be surgical: change only what the finding calls for without disrupting surrounding content. Preserve the author's voice — edits should improve readability without changing the document's intent or personality.

After all edits are applied, re-read the document file to verify the changes look correct and the document is coherent.

## Phase 4: Track

Append an iteration entry to `docs/plans/doc-refine-tracking.md`:

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
<promise>DOC_REFINED</promise>
```

Only output this promise if you genuinely analyzed the full document against the prompt and found nothing actionable.
