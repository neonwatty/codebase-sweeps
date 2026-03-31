---
name: ci-loop
description: "This command should be used when the user asks to 'loop CI audit', 'fully optimize CI', 'audit all CI dimensions', or 'do a full CI optimization sweep'. Loops CI audit iterations until all 9 dimensions are covered and no issues remain. Requires ralph-loop plugin."
argument-hint: "OWNER/REPO [--max N]"
---

# CI Audit Loop

Start a Ralph Loop that repeatedly audits CI until all 9 dimensions are covered and no issues remain.

Parse the arguments: extract the OWNER/REPO and optional `--max N` for max iterations (default: 9).

Now invoke the Ralph Loop skill with these parameters:

```
/ralph-loop:ralph-loop "/useful-loops:ci-audit <OWNER/REPO>" --completion-promise "CI_OPTIMIZED" --max-iterations <N>
```

Replace `<OWNER/REPO>` with the repository and `<N>` with the max iterations (default 9).
