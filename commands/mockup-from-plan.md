---
name: mockup-from-plan
description: "This command should be used when the user asks to 'build a mockup from a plan', 'generate mockup from plan', 'create HTML mockup', or 'compare mockup against plan'. Runs one iteration: compares an HTML/CSS/JS mockup against a plan document, identifies gaps, and fixes them."
argument-hint: "PLAN MOCKUP_DIR"
---

# Mockup from Plan

You are performing one complete mockup-from-plan iteration. The plan is the source of truth. You will deeply read both artifacts, perform a thorough gap analysis, and fix what's missing in the mockup. Report progress at each phase.

Parse the arguments: extract the PLAN path (a single `.md` file or a directory of `.md` files) and the MOCKUP_DIR path (a directory containing `.html`, `.css`, and `.js` files). Both are required.

**Plan:** `<PLAN>`
**Mockup directory:** `<MOCKUP_DIR>`

**Prerequisite check:** If either the plan file/directory or the mockup directory does not exist, stop immediately and tell the user: "Both the plan and the mockup directory must already exist before running this skill. Please create them first, then re-run." Do not create either artifact.

**Plan format:** The plan can be either:
- **A single file** (e.g., `screen-plan.md`) — one document describing the full plan
- **A directory** (e.g., `plans/`) — contains multiple `.md` files organized by topic (e.g., `user-screens.md`, `admin-screens.md`, `api-endpoints.md`). All files together form the complete plan.

**In-place editing only:** All changes are made directly to existing files within `<MOCKUP_DIR>`. Do not create new directories. If a gap requires a new file (e.g., a new page), create it inside the existing mockup directory.

Run Phases 1-5 once. If Phase 3 finds zero gaps, output the completion promise and stop.

---

## Phase 1: Read & Understand

1. Read `docs/plans/mockup-from-plan-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it (run `mkdir -p docs/plans` first if the directory does not exist):
   ```markdown
   # Mockup from Plan — Tracking

   **Plan:** <path> (file / directory)
   **Mockup directory:** <path>

   ---

   ## Iteration Log
   ```

2. If this is iteration 2 or later, review the prior iteration entries in the tracking file. Understand what was already changed so you do not re-tread the same ground or revert prior improvements.

3. **Deep-read the plan.** Use an explorer agent to thoroughly read and understand the plan. The agent should:
   - If `<PLAN>` is a single file, read the entire file
   - If `<PLAN>` is a directory, read every `.md` file in the directory and understand how the content is organized across files
   - Extract every concrete requirement: pages, screens, components, layout descriptions, content/copy, interactions, styling specs, user flows, data models
   - Organize findings into a structured inventory of what the plan specifies
   - Note any vague or ambiguous requirements that may need user clarification

4. **Deep-read the mockup.** Use a second explorer agent (in parallel with step 3) to thoroughly read and understand the current mockup directory. The agent should:
   - Read all HTML, CSS, and JavaScript files in `<MOCKUP_DIR>`
   - Inventory every page/screen, section, component, interactive element, and piece of content
   - Catalog the CSS: colors, fonts, spacing, layout approach, responsive breakpoints
   - Catalog the JavaScript: event handlers, state management, animations, form validation
   - Report a structured inventory of what the mockup currently contains

Both agents should return detailed, structured inventories — not summaries. The gap analysis in Phase 3 depends on having complete information from both sides. If an agent hits context limits, it should return its partial inventory and note where it stopped so a follow-up agent can continue.

## Phase 2: Reconcile Inventories

With both inventories in hand, create a reconciliation matrix. For each item the plan specifies, determine whether the mockup has it, partially has it, or is missing it entirely. Organize this by dimension:

| Plan Requirement | Mockup Status | Gap? |
|---|---|---|
| ... | Present / Partial / Missing | YES / NO |

This matrix is your working document for Phase 3. It ensures nothing from the plan is overlooked.

## Phase 3: Gap Analysis

Walk through the reconciliation matrix and identify all gaps across six dimensions.

### Dimension 1: Pages & Screens

Does the mockup contain all pages or screens described in the plan? Look for:
- Missing pages entirely (plan describes a settings page but mockup has none)
- Pages present but with wrong scope (plan says 3 tabs, mockup shows 1)
- Navigation between pages (plan describes a flow, mockup has dead-end pages)

### Dimension 2: Layout & Structure

Does each page's layout match the plan? Look for:
- Missing sections (plan describes a sidebar, mockup has none)
- Wrong arrangement (plan says 2-column grid, mockup uses single column)
- Missing structural elements (headers, footers, navigation bars)

### Dimension 3: Components & UI Elements

Are all interactive and static elements present? Look for:
- Missing buttons, forms, inputs, dropdowns, modals, cards, tables, lists
- Missing form fields the plan specifies
- Missing navigation elements (tabs, breadcrumbs, menus)

### Dimension 4: Content & Copy

Does the mockup's text content match the plan? Look for:
- Missing or wrong headings, labels, descriptions
- Placeholder text where the plan specifies actual content
- Missing empty states, error messages, or status text the plan describes

### Dimension 5: Interactions & Behavior

Does the mockup's JavaScript behavior match the plan? Look for:
- Missing click handlers (buttons that should open modals, toggle views, submit forms)
- Missing state changes (tabs that should switch content, toggles, accordions)
- Missing form validation the plan describes
- Missing transitions or animations the plan calls for

### Dimension 6: Styling & Visual Design

Does the mockup's appearance match any design specs in the plan? Look for:
- Missing or wrong colors, fonts, spacing
- Missing responsive behavior the plan describes
- Missing visual cues (icons, badges, indicators)
- Inconsistencies with a design system or style guide referenced in the plan

### Classification

For each gap found, classify its severity:
- **HIGH** — Missing page, missing core component, broken interaction, structural mismatch with plan
- **MEDIUM** — Missing secondary element, incomplete content, partial interaction, styling mismatch
- **LOW** — Minor copy difference, subtle spacing, polish item

If zero gaps are found across all six dimensions, append a minimal tracking entry ("Iteration N: Zero gaps found — convergence achieved") to the tracking file, then skip to Phase 6 (signal).

If gaps were found, proceed to Phase 4.

## Phase 4: Clarify & Fix

> **Loop-awareness:** If this skill was invoked by a Ralph Loop (check if the prompt mentions ralph-loop or was re-fed by a loop wrapper), do NOT use `AskUserQuestion`. Instead, pick the recommended interpretation for each ambiguous item and note the decision in the tracking file under "Auto-resolved (loop mode)". Only use `AskUserQuestion` when running interactively.

### Ambiguity Check

Before fixing, review the gaps for any that require interpretation. The plan may be vague or open to multiple visual/UX interpretations. For each ambiguous item, use `AskUserQuestion` to clarify:

```
AskUserQuestion:
  question: "The plan says '<quote from plan>'. How should this appear in the mockup?"
  header: "Clarify"
  options:
    - label: "<interpretation A> (Recommended)"
      description: "<what this would look like>"
    - label: "<interpretation B>"
      description: "<what this would look like>"
    - label: "Skip this for now"
      description: "Defer to a later iteration"
```

Group related ambiguities into a single question when possible (max 4 options per question). Only ask about genuinely ambiguous items — if the plan is clear, just build it.

### Fix

Apply gap fixes directly to the existing files in `<MOCKUP_DIR>`. Prioritize HIGH findings first, then MEDIUM, then LOW. Each edit should be surgical: add what's missing without disrupting what already works. Edit files in place — do not create new directories or restructure the mockup.

After all edits are applied, re-read the changed files to verify:
- The HTML is valid and well-structured
- CSS doesn't have conflicting styles
- JavaScript doesn't have errors
- All internal navigation still works

## Phase 5: Track

Append an iteration entry to `docs/plans/mockup-from-plan-tracking.md`:

```markdown
### Iteration N (YYYY-MM-DD)

**Gaps found:** X (Y HIGH, Z MEDIUM, W LOW)
**Gaps fixed:** A
**Deferred:** B
**User clarifications:** C

#### Dimensions Covered

- Pages & Screens: [summary]
- Layout & Structure: [summary]
- Components & UI Elements: [summary]
- Content & Copy: [summary]
- Interactions & Behavior: [summary]
- Styling & Visual Design: [summary]

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

**If NO gaps were found across all six dimensions:** output exactly:

```
<promise>MOCKUP_MATCHES_PLAN</promise>
```

Only output this promise if you genuinely compared every dimension and found nothing actionable.
