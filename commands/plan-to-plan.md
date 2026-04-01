---
name: plan-to-plan
description: "This command should be used when the user asks to 'compare plans', 'align a derived plan with its source', 'run plan-to-plan', or 'close gaps between plans'. Runs one iteration: compares a derived plan against its source plan, identifies gaps, and fixes them."
argument-hint: "SOURCE_PLAN TARGET"
---

# Plan to Plan

You are performing one complete plan-to-plan iteration. The source plan is the source of truth. The target plan is a transformation of the source — it may change abstraction level, focus, or format (e.g., PRD → screen plan, screen plan → technical spec, technical spec → implementation plan), but it must faithfully cover everything in the source. You will deeply read both documents, perform a thorough gap analysis, and fix what's missing in the target. Report progress at each phase.

Parse the arguments: extract the SOURCE_PLAN path (the upstream plan — the source of truth) and the TARGET path (the derived plan to refine — either a single `.md` file or a directory of `.md` files). Both are required.

**Source plan:** `<SOURCE_PLAN>`
**Target:** `<TARGET>`

**Prerequisite check:** If either the source plan or the target file/directory does not exist, stop immediately and tell the user: "Both the source plan and the target must already exist before running this skill. Please create the target first, then re-run." Do not create either artifact.

**Target format:** The target can be either:
- **A single file** (e.g., `screen-plan.md`) — all edits go to that file
- **A directory** (e.g., `screen-plan/`) — contains multiple `.md` files organized by topic (e.g., `user-screens.md`, `admin-screens.md`, `api-endpoints.md`). Edits go to the appropriate existing file. New `.md` files may be created inside the directory if a gap naturally belongs in a separate file, but do not create subdirectories.

Run Phases 1-6 once. If Phase 3 finds zero gaps, skip to Phase 6 (signal).

---

## Phase 1: Read & Understand

1. Read `docs/plans/plan-to-plan-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it (run `mkdir -p docs/plans` first if the directory does not exist):
   ```markdown
   # Plan to Plan — Tracking

   **Source plan:** <path>
   **Target:** <path> (file / directory)

   ---

   ## Iteration Log
   ```

2. If this is iteration 2 or later, review the prior iteration entries in the tracking file. Understand what was already changed so you do not re-tread the same ground or revert prior improvements.

3. **Deep-read the source plan.** Use an explorer agent to thoroughly read and understand the source plan. The agent should:
   - Read the entire source plan file
   - Extract every concrete item: requirements, features, user stories, goals, constraints, flows, data models, acceptance criteria, edge cases — whatever the source plan contains
   - Organize findings into a structured inventory, grouped by section or theme
   - Note the level of abstraction and intent of each item (what is the source trying to specify?)

4. **Deep-read the target.** Use a second explorer agent (in parallel with step 3) to thoroughly read and understand the target. The agent should:
   - If `<TARGET>` is a single file, read the entire file
   - If `<TARGET>` is a directory, read every `.md` file in the directory and understand how the content is organized across files
   - Extract every concrete item the target describes, at whatever level of abstraction the target operates
   - Organize findings into a structured inventory, grouped by section or theme (and by file, if a directory)
   - Note the transformation approach: how does the target translate source concepts into its own domain? (e.g., a PRD's "user profile management" might become specific screens, components, and interactions in a screen plan)
   - If a directory, note the organizational scheme — how are topics split across files? This matters for knowing where to place new content

Both agents should return detailed, structured inventories — not summaries. The gap analysis in Phase 3 depends on having complete information from both sides. If an agent hits context limits, it should return its partial inventory and note where it stopped so a follow-up agent can continue.

## Phase 2: Reconcile Inventories

With both inventories in hand, create a reconciliation matrix. For each item in the source plan, determine whether the target plan addresses it, partially addresses it, or is missing it entirely:

| Source Item | Target Coverage | Gap? |
|---|---|---|
| ... | Covered / Partial / Missing | YES / NO |

The transformation between source and target is not 1:1 — a single source requirement may map to multiple target items, or multiple source items may consolidate into one target section. The key question for each source item is: **if someone read only the target plan, would they know about this?**

This matrix is your working document for Phase 3. It ensures nothing from the source is overlooked.

## Phase 3: Gap Analysis

Walk through the reconciliation matrix and identify all gaps across five dimensions.

### Dimension 1: Coverage

Does the target plan address every item from the source? Look for:
- Source requirements with no corresponding target section or mention
- Source features that the target ignores or skips
- Source constraints or edge cases the target doesn't account for
- Source user stories or flows with no target-side representation

### Dimension 2: Depth

Where the target does address a source item, does it elaborate sufficiently for its level of abstraction? Look for:
- Surface-level mentions that need more detail (e.g., target says "settings page" but doesn't describe what settings)
- Placeholder or TODO sections that were never filled in
- Items described at the wrong level of abstraction for what the target plan is (e.g., a screen plan that just restates PRD requirements without describing actual screens)

### Dimension 3: Accuracy

Do the target's details faithfully represent the source's intent? Look for:
- Misinterpretations of source requirements (target describes something different than what the source meant)
- Contradictions between source and target (source says X, target says not-X)
- Scope drift (target adds things the source didn't ask for, or changes the meaning)

### Dimension 4: Completeness

Are there internal gaps within the target plan itself? Look for:
- Sections that reference other sections that don't exist
- Incomplete lists or enumerations (source lists 5 items, target only covers 3)
- Dangling references or forward mentions that are never resolved
- Inconsistent terminology between sections of the target

### Dimension 5: Standalone Clarity

Could someone read the target plan alone and fully understand what needs to happen? Look for:
- Sections that only make sense if you've read the source (implicit context)
- Ambiguous language that the source clarifies but the target doesn't
- Missing context or rationale that the target should carry forward from the source
- Structural issues that make the target hard to follow (poor ordering, missing transitions)

### Classification

For each gap found, classify its severity:
- **HIGH** — Missing coverage of a source requirement, factual inaccuracy, significant misinterpretation
- **MEDIUM** — Insufficient depth, partial coverage, unclear language, minor inconsistency
- **LOW** — Phrasing improvement, structural polish, minor clarity enhancement

If zero gaps are found across all five dimensions, append a minimal tracking entry ("Iteration N: Zero gaps found — convergence achieved") to the tracking file, then skip to Phase 6 (signal).

If gaps were found, proceed to Phase 4.

## Phase 4: Clarify & Fix

> **Loop-awareness:** If this skill was invoked by a Ralph Loop (check if the prompt mentions ralph-loop or was re-fed by a loop wrapper), do NOT use `AskUserQuestion`. Instead, pick the recommended interpretation for each ambiguous item and note the decision in the tracking file under "Auto-resolved (loop mode)". Only use `AskUserQuestion` when running interactively.

### Ambiguity Check

Plan-to-plan transformations often involve interpretation — a source requirement can map to multiple valid target elaborations. Before fixing, review the gaps for any that have multiple reasonable interpretations. Use `AskUserQuestion` to clarify:

```
AskUserQuestion:
  question: "The source says '<quote from source>'. The target doesn't cover this. How should it be represented?"
  header: "Transform"
  options:
    - label: "<interpretation A> (Recommended)"
      description: "<how this would appear in the target>"
    - label: "<interpretation B>"
      description: "<how this would appear in the target>"
    - label: "Not needed in target"
      description: "This source item doesn't need representation in the target plan"
    - label: "Skip this for now"
      description: "Defer to a later iteration"
```

This is especially important for:
- **Abstraction shifts** — how should a high-level requirement break down into specific items at the target's level?
- **Scope decisions** — should the target include this item, or is it outside the target plan's scope?
- **Priority calls** — when the source lists many items, which should the target prioritize elaborating?

Only ask about genuinely ambiguous items. If the gap is clearly a missing item that should be added, just add it.

### Fix

Apply gap fixes to the target. Prioritize HIGH findings first, then MEDIUM, then LOW. Each edit should be surgical: add what's missing, correct what's wrong, and deepen what's shallow — without disrupting sections that are already good.

**If target is a single file:** edit `<TARGET>` directly in place.

**If target is a directory:** place each fix in the most appropriate existing file based on topic. If a gap doesn't fit naturally into any existing file, create a new `.md` file in the directory following the existing naming convention. Do not create subdirectories.

Guidelines:
- **Preserve the target's voice and structure** — add content that fits naturally into the existing document(s)
- **Match the target's level of abstraction** — don't paste source-level language into a target that operates at a different level
- **Add, don't duplicate** — if the target already partially covers something, extend that section rather than creating a new one
- **Maintain internal consistency** — new additions should use the same terminology, formatting, and structure as the rest of the target
- **Respect the directory organization** — if the target splits user-facing vs admin content into separate files, new user-facing content goes in the user file, not the admin file

After all edits are applied, re-read the changed files to verify:
- Each document flows coherently
- New additions integrate naturally with existing content
- No contradictions were introduced
- Formatting and structure are consistent throughout
- If a directory, cross-file references are accurate and no content is duplicated across files

## Phase 5: Track

Append an iteration entry to `docs/plans/plan-to-plan-tracking.md`:

```markdown
### Iteration N (YYYY-MM-DD)

**Gaps found:** X (Y HIGH, Z MEDIUM, W LOW)
**Gaps fixed:** A
**Deferred:** B
**User clarifications:** C

#### Dimensions Covered

- Coverage: [summary]
- Depth: [summary]
- Accuracy: [summary]
- Completeness: [summary]
- Standalone Clarity: [summary]

#### Changes Applied

- [HIGH] Description of change
- [MEDIUM] Description of change
- [LOW] Description of change

#### Deferred

- [ ] Description (reason)

#### User Decisions

- "<question>" → "<user's choice>"
```

## Phase 6: Signal

**If gaps were found and fixed:** exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

**If NO gaps were found across all five dimensions:** output exactly:

```
<promise>PLANS_ALIGNED</promise>
```

Only output this promise if you genuinely compared every dimension and found nothing actionable.
