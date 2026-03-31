# Claude Code Hooks Audit Dimensions

6 dimensions to evaluate, 1-2 per iteration. Check the tracking file to see which have been covered.

## D1: Event Coverage

**Goal:** Hooks should cover the right lifecycle events without gaps or wasted effort.

**What to check:**
- Which events have hooks configured? Which are missing?
- Are there high-value events with no hooks? (e.g., PreToolUse for safety, PostToolUse for formatting)
- Are there hooks on low-frequency events that provide little value?
- Are SessionStart hooks used to set up environment or inject context?

**Key events by value:**
| Event | Common use | Frequency |
|-------|-----------|-----------|
| PreToolUse | Block dangerous commands, validate inputs | Every tool call |
| PostToolUse | Format files, run lint, log actions | Every tool call |
| UserPromptSubmit | Inject context, validate prompts | Every prompt |
| SessionStart | Set up environment, load context | Once per session |
| Stop | Verify work, run checks | Every response |
| Notification | Custom alerting | Varies |

**What to fix:**
- Add hooks for critical safety checks if missing
- Remove hooks on events that don't provide value for this project

## D2: Scope & Matching

**Goal:** Hooks should fire only when relevant, not on every tool call.

**What to check:**
- Are there empty matchers (`""`) on high-frequency events (PreToolUse, PostToolUse)?
- Could broad matchers (e.g., matching all tools) be narrowed to specific tools?
- Are `if` argument filters used where applicable? (e.g., `Bash(git *)` instead of all Bash)
- Are matchers using precise regex or overly broad patterns?

**What to fix:**
- Replace empty matchers with specific tool names: `"Bash|Edit|Write"`
- Add `if` filters for argument-level scoping: `"if": "Bash(npm test*)"`
- Remove hooks from tools they don't need to intercept (e.g., Read, Glob usually don't need PostToolUse hooks)

## D3: Performance

**Goal:** Keep hook execution fast to avoid blocking Claude's workflow.

**What to check:**
- Run `scripts/cc-hooks/profile-hooks.sh` to measure per-hook latency
- Are any hooks taking >500ms? (Threshold for perceptible delay)
- Are command hooks spawning heavy processes (full lint, test suite)?
- Is shell profile loading adding overhead? (Complex .zshrc/.bashrc sourced per hook)
- Are there hooks using prompt or agent types on frequent events? (Expensive LLM calls)

**What to fix:**
- Optimize slow scripts: fast-path exits, skip unnecessary work
- Move heavy checks to async: `"async": true`
- Use compiled binaries (Go, Rust) instead of interpreted scripts for hot paths
- Simplify shell profile or use absolute paths to avoid sourcing
- Replace prompt/agent hooks with command hooks where deterministic logic suffices

## D4: Redundancy

**Goal:** Don't check the same thing multiple times.

**What to check:**
- Are there hooks that overlap in function? (e.g., two separate format hooks)
- Are PreToolUse AND PostToolUse both checking the same condition?
- Are hooks duplicating checks that Claude Code does natively?
- Are there hooks across settings files (global + project) that conflict or duplicate?

**What to fix:**
- Consolidate overlapping hooks into a single hook per event
- Choose the right event: PreToolUse for blocking, PostToolUse for reacting
- Remove hooks that duplicate Claude's built-in behavior
- Audit global vs. project hooks for conflicts

## D5: Error Handling

**Goal:** Hooks should fail gracefully without blocking productive work.

**What to check:**
- Do hook scripts handle missing tools gracefully (e.g., `jq` not installed)?
- Are timeouts explicitly set? (Default 600s for command hooks is dangerously long)
- Do PreToolUse hooks use exit code 2 (block) vs other codes (non-blocking error) correctly?
- Is the Stop hook checking `stop_hook_active` to prevent infinite loops?
- Are hook errors logged somewhere for debugging?

**What to fix:**
- Add explicit `timeout` to every hook (5-30s for command hooks)
- Add tool availability checks at the top of hook scripts
- Use correct exit codes: 0 (allow), 2 (block), 1 (non-blocking error)
- Add `stop_hook_active` check to Stop hooks
- Log errors to a file for post-session debugging

## D6: Composability & Organization

**Goal:** Hook configuration should be maintainable and well-organized.

**What to check:**
- Are hooks split appropriately across settings files? (Global for personal prefs, project for team standards)
- Are hook scripts in a dedicated directory (`.claude/hooks/`) or scattered?
- Are there hooks that should be plugins instead of local config?
- Is the hook configuration documented for team members?
- Are `statusMessage` fields set for hooks that take >1s? (User feedback)

**What to fix:**
- Move team-relevant hooks to `.claude/settings.json` (committed)
- Move personal hooks to `.claude/settings.local.json` (gitignored)
- Organize hook scripts into `.claude/hooks/` directory
- Add `statusMessage` to slow hooks so users know what's happening
- Document hook setup in project CONTRIBUTING.md or CLAUDE.md
