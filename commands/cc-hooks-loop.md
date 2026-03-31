---
name: cc-hooks-loop
description: "This command should be used when the user asks to 'loop CC hooks audit', 'fully optimize Claude Code hooks', 'audit all CC hook dimensions', or 'do a full CC hooks optimization sweep'. Loops CC hooks audit iterations until all 6 dimensions are covered and no issues remain. Requires ralph-loop plugin."
argument-hint: "[--max N]"
---

# Claude Code Hooks Audit Loop

Start a Ralph Loop that repeatedly audits Claude Code hooks until all 6 dimensions are covered and no issues remain.

Parse the arguments: extract an optional `--max N` for max iterations (default: 6).

Now invoke the Ralph Loop skill with these parameters:

```
/ralph-loop:ralph-loop "/useful-loops:cc-hooks-audit" --completion-promise "CC_HOOKS_OPTIMIZED" --max-iterations <N>
```

Replace `<N>` with the max iterations (default 6).
