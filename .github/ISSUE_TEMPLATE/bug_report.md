---
name: Bug report
about: Create a report to help us improve
---

## What happened?

<!-- Describe the issue clearly -->

## How to reproduce it

<!-- If it is a crash, a network error, or unexpected behavior -->

## Command used

```bash
# Example
zig build -Doptimize=ReleaseSafe
ZODE_PROVIDER=opencode ZODE_MODEL=space-bunny-free ./zig-out/bin/zode --chat "read source/lib/ask.zig"
```

## Environment

- Operating system: [e.g. Linux 6.x]
- Zig version: `zig version`
- Branch: `main` or tag: [e.g. v0.1.0]
- Does `.env` / `auth.json` / `permissions.json` exist? (do not paste values, just confirm they exist)

## Relevant output

- If it crashed: `coredumpctl info` or result of `zig build debug`
- If it is a network error: `ZODE_DBG_ERR=1` and the first lines of the error
- If it is a visual issue (scroll, input, banner): capture with `tools/pty_smoke.py` or describe what appears

## Additional notes

<!-- Any useful context -->
