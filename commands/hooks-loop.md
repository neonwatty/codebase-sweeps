---
name: hooks-loop
description: "This command should be used when the user asks to 'loop hooks audit', 'fully optimize git hooks', 'audit all hook dimensions', or 'do a full hooks optimization sweep'. Loops hooks audit iterations until all 6 dimensions are covered and no issues remain. Requires ralph-loop plugin."
argument-hint: "[--max N]"
---

# Hooks Audit Loop

Start a Ralph Loop that repeatedly audits git hooks until all 6 dimensions are covered and no issues remain.

Parse the arguments: extract an optional `--max N` for max iterations (default: 6).

Now invoke the Ralph Loop skill with these parameters:

```
/ralph-loop:ralph-loop "/useful-loops:hooks-audit" --completion-promise "HOOKS_OPTIMIZED" --max-iterations <N>
```

Replace `<N>` with the max iterations (default 6).
