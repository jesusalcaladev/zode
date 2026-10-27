## Summary

<!-- What this PR does: fixes, adds, refactors -->

## Type of change

- [ ] Bug fix (does not change expected behavior, just fixes it)
- [ ] New feature (adds something to the roadmap)
- [ ] Documentation (`AGENTS.md`, `README`, `CONTRIBUTING`)
- [ ] Refactor (moves code, does not change output)
- [ ] Tests (adds or fixes)

## How it was tested

- [ ] `zig build test` passes
- [ ] `zig build -Doptimize=ReleaseSafe` compiles
- [ ] `tools/pty_smoke.py` passes (if applicable)
- [ ] Manual test with `./zig-out/bin/zode --chat "..."`

## Notes for reviewers

- If there is a change in `src/agent.zig` or `src/tui.zig`, explain why it did not break the module-level globals
- If there is a change in the HTTP / SSE / JSON protocol, mention whether it affects `chat.zig` and `dispatch.zig`
- If there is a visual design change, mention whether it affects `drawTest` or `ui-frame`

## Code checklist

- [ ] Comments and test names are in English
- [ ] No `TODO` in the new code
- [ ] The "pure Zig std" rule was not broken (no mandatory `libc`)
- [ ] If a new file was added to `src/lib/`, it has its test in the same file or in `src/lib/*.zig`
