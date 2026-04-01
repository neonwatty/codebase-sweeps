---
name: prototype-from-mockup
description: "This command should be used when the user asks to 'build prototype from mockup', 'implement mockup in the app', 'compare prototype against mockup', or 'close prototype gaps'. Runs one iteration: compares a real app prototype against an HTML/CSS/JS mockup, identifies gaps, and fixes them."
argument-hint: "MOCKUP_DIR APP_DIR"
---

# Prototype from Mockup

You are performing one complete prototype-from-mockup iteration. The mockup is the source of truth. You will deeply read both artifacts, perform a thorough gap analysis, and fix what's missing in the prototype. Report progress at each phase.

Parse the arguments: extract the MOCKUP_DIR path (a directory containing `.html`, `.css`, and `.js` files — the spec) and the APP_DIR path (the directory of the prototype app). Both are required.

**Mockup directory:** `<MOCKUP_DIR>`
**App directory:** `<APP_DIR>`

**Prerequisite check:** If either the mockup directory or the app directory does not exist, stop immediately and tell the user: "Both the mockup directory and the app prototype must already exist before running this skill. Please set up both first, then re-run." Do not create either artifact.

**Build upon what exists:** Do not impose a particular tech stack or architecture. Deeply understand the app's existing structure, conventions, dependencies, and patterns, then build upon them. If the app uses Supabase, use Supabase. If it uses plain React with local state, use that. Follow the app's lead.

Run Phases 1-5 once. If Phase 3 finds zero gaps, output the completion promise and stop.

---

## Phase 1: Read & Understand

1. Read `docs/plans/prototype-from-mockup-tracking.md` to find the last iteration number. Your iteration is N+1. If no iterations exist yet, you are iteration 1. If the tracking file does not exist, create it (run `mkdir -p docs/plans` first if the directory does not exist):
   ```markdown
   # Prototype from Mockup — Tracking

   **Mockup directory:** <path>
   **App directory:** <path>
   **Stack:** <detected from app>

   ---

   ## Iteration Log
   ```

2. If this is iteration 2 or later, review the prior iteration entries in the tracking file. Understand what was already built so you do not re-tread the same ground or revert prior work.

3. **Deep-read the mockup.** Use an explorer agent to thoroughly read and understand the mockup directory. The agent should:
   - Read all HTML, CSS, and JavaScript files in `<MOCKUP_DIR>`
   - Inventory every page/screen, section, component, interactive element, and piece of content
   - Catalog the CSS: colors (exact hex/rgb values), fonts, spacing values, layout approach (grid vs flexbox), responsive breakpoints
   - Catalog the JavaScript: event handlers, state management, animations, form validation, modal behavior
   - Report a structured inventory of everything the mockup contains — this is the spec

4. **Deep-read the prototype.** Use a second explorer agent (in parallel with step 3) to thoroughly read and understand the current prototype app. The agent should:
   - Read `package.json` to understand dependencies, scripts, and stack
   - Explore the full directory structure to map all pages/routes, components, layouts, styles, utilities, and data files
   - Read every page and component file — understand what each renders, what props it takes, what state it manages
   - Catalog the styling: Tailwind config, CSS files, theme tokens, component-level styles
   - Catalog interactions: form handlers, click events, state changes, navigation
   - Identify the data layer: how data flows (props, context, API routes, server actions, local storage)
   - Report a structured inventory of everything the prototype currently implements

Both agents should return detailed, structured inventories — not summaries. The gap analysis in Phase 3 depends on having complete information from both sides. If an agent hits context limits, it should return its partial inventory and note where it stopped so a follow-up agent can continue.

## Phase 2: Reconcile Inventories

With both inventories in hand, create a reconciliation matrix. For each element the mockup contains, determine whether the prototype has it, partially has it, or is missing it entirely. Organize this by dimension:

| Mockup Element | Prototype Status | Gap? |
|---|---|---|
| ... | Present / Partial / Missing | YES / NO |

This matrix is your working document for Phase 3. It ensures nothing from the mockup is overlooked.

## Phase 3: Gap Analysis

Walk through the reconciliation matrix and identify all gaps across six dimensions.

### Dimension 1: Pages & Routes

Does the prototype have routes for all pages/screens in the mockup? Look for:
- Missing pages (mockup has a settings screen but app has no `/settings` route)
- Missing layouts (mockup has a shared sidebar layout, app doesn't)
- Missing navigation (mockup links between pages, app has dead-end routes)

### Dimension 2: Components

Are all UI components from the mockup implemented? Look for:
- Missing components entirely (mockup has a card grid, app has none)
- Components present but incomplete (mockup card has 5 fields, app card shows 3)
- Missing component variants (mockup has primary/secondary buttons, app has one style)

### Dimension 3: Layout & Structure

Does each page's structure match the mockup? Look for:
- Different column layouts (mockup is 2-column, app is single column)
- Missing or wrongly placed sections (mockup has footer, app doesn't)
- Spacing and proportion differences

### Dimension 4: Styling & Visual Fidelity

Does the prototype visually match the mockup? Look for:
- Color mismatches (extract exact hex/rgb values from mockup CSS, compare to app)
- Typography differences (font family, size, weight, line height)
- Spacing inconsistencies (padding, margin, gaps — compare exact pixel values)
- Missing visual elements (borders, shadows, gradients, icons)
- Missing responsive behavior shown in the mockup

### Dimension 5: Interactions & State

Do interactive elements in the prototype match the mockup's behavior? Look for:
- Missing click handlers that the mockup implements
- Missing form validation the mockup has
- Missing modal/dialog behavior
- Missing state transitions (tabs, accordions, toggles)
- Missing loading or empty states shown in the mockup

### Dimension 6: Data & Backend

If the mockup displays data, is it properly represented in the prototype? Look for:
- Hardcoded mockup data that needs a real data source in the prototype (using whatever data layer the app already has)
- Forms in the mockup that need API endpoints, server actions, or handlers (using the app's existing patterns)
- Authentication flows implied by the mockup (using whatever auth the app already has set up)
- CRUD operations visible in the mockup UI that need backend support

### Classification

For each gap found, classify its severity:
- **HIGH** — Missing page/route, missing core component, fundamentally different layout, broken interaction
- **MEDIUM** — Missing secondary element, styling mismatch, incomplete interaction, partial data integration
- **LOW** — Minor visual difference, subtle spacing, polish item

If zero gaps are found across all six dimensions, append a minimal tracking entry ("Iteration N: Zero gaps found — convergence achieved") to the tracking file, then skip to Phase 6 (signal).

If gaps were found, proceed to Phase 4.

## Phase 4: Clarify, Prioritize & Fix

> **Loop-awareness:** If this skill was invoked by a Ralph Loop (check if the prompt mentions ralph-loop or was re-fed by a loop wrapper), do NOT use `AskUserQuestion`. Instead, pick the recommended interpretation for each ambiguous item and note the decision in the tracking file under "Auto-resolved (loop mode)". Only use `AskUserQuestion` when running interactively.

### Ambiguity Check

Some mockup elements may have multiple valid implementations in the app's stack. Use `AskUserQuestion` for decisions that affect architecture:

```
AskUserQuestion:
  question: "The mockup shows <element>. How should this work in the prototype?"
  header: "Approach"
  options:
    - label: "<approach A> (Recommended)"
      description: "<tradeoff explanation>"
    - label: "<approach B>"
      description: "<tradeoff explanation>"
    - label: "Skip this for now"
      description: "Defer to a later iteration"
```

Common decision points:
- **Data source:** How should this data be stored, given the app's existing data layer?
- **Auth:** How should auth work, given what the app already has set up?
- **Forms:** Where should form submissions go, given the app's existing API/action patterns?
- **State management:** How should cross-page state work, given the app's existing approach?

Only ask about genuinely ambiguous items — if the mockup clearly shows a simple interaction, just implement it.

### Prioritize

Order the work for this iteration:
1. HIGH gaps first — these are structural and often unblock other work
2. MEDIUM gaps next — fill in the details
3. LOW gaps if time/scope allows

Cap at ~12 files changed per iteration. If more are needed, defer the lowest-priority remaining items.

### Fix

Implement the prioritized gaps in the prototype:

1. **Follow the app's conventions** — use its existing component patterns, CSS approach, file organization, naming conventions, and data layer. Do not introduce new patterns or dependencies unless absolutely necessary. If the app uses Tailwind, translate mockup CSS to Tailwind classes. If the app uses CSS modules, create scoped stylesheets. Match what's already there.

2. **Translate, don't copy-paste** — the mockup uses vanilla HTML/CSS/JS. The prototype should use the app's stack idioms:
   - HTML elements → the app's component patterns (React, Vue, Svelte, etc.)
   - Inline styles → the app's styling approach (Tailwind, CSS modules, styled-components, etc.)
   - Vanilla JS event handlers → the app's state and event patterns
   - Multi-page HTML navigation → the app's routing approach
   - Hardcoded data → the app's existing data layer

3. **Preserve visual fidelity** — the mockup is the spec. Colors, spacing, typography, and layout should match. Extract exact values from the mockup's CSS.

4. **Wire up interactions** — if the mockup has a working modal, the prototype's modal should work the same way. If the mockup has form validation, the prototype needs equivalent validation.

5. **Build upon the existing data layer** — use whatever data approach the app already has. If it has Supabase, use Supabase. If it has local JSON, use that. Do not introduce a new data layer.

After building, verify the prototype runs without errors:

```bash
cd <APP_DIR> && npm run build 2>&1 || true
cd <APP_DIR> && npm run lint 2>&1 || true
```

If build or lint fails, fix the issues. Max 3 fix attempts. If still failing, revert the problematic change and note it as deferred.

## Phase 5: Track

Append an iteration entry to `docs/plans/prototype-from-mockup-tracking.md`:

```markdown
### Iteration N (YYYY-MM-DD)

**Gaps found:** X (Y HIGH, Z MEDIUM, W LOW)
**Gaps fixed:** A
**Deferred:** B
**User clarifications:** C

#### Dimensions Covered

- Pages & Routes: [summary]
- Components: [summary]
- Layout & Structure: [summary]
- Styling & Visual Fidelity: [summary]
- Interactions & State: [summary]
- Data & Backend: [summary]

#### Changes Applied

- [HIGH] Description of change (files: ...)
- [MEDIUM] Description of change (files: ...)
- [LOW] Description of change (files: ...)

#### Deferred

- [ ] Description (reason)

#### User Decisions

- "<question>" → "<user's choice>"
```

## Phase 6: Signal

**If gaps were found and fixed:** exit normally. If running in a Ralph Loop, the loop will re-invoke for the next iteration.

**If NO gaps were found across all six dimensions:** output exactly:

```
<promise>PROTOTYPE_MATCHES_MOCKUP</promise>
```

Only output this promise if you genuinely compared every dimension and found nothing actionable.
