# Contributing to zode

Thanks for your interest in `zode`. It is a pure Zig code harness, built to be fast, simple, and free of mandatory external dependencies.

## Before you start

- This project uses **Zig 0.16**. Make sure `zig` is in your `PATH`.
- All code lives under `src/`; tests run with `zig build test`.
- There is no required `CMake`, `Make`, or `npm`: only `zig build`, `zig test`, and `zig build -Doptimize=ReleaseSafe`.

## How to contribute

1. **Fork + branch**: create a descriptive branch (`feat/rol`, `fix/scroll`, etc.).
2. **Keep "pure Zig std"**: no mandatory `libc`, only `libvaxis` as an optional external dependency.
3. **Keep tests green**: `zig build test` must pass. There are 800+ tests; if you add a file, add its test.
4. **Document with AGENTS.md in mind**: comments and test names should be in English; identifiers are never translated.
5. **No TODOs**: `AGENTS.md` explicitly forbids them.

## Areas that need help

- `task` / subagents (priority 1 in the roadmap)
- MCP over stdio (priority 2)
- `@file` mentions (priority 4)
- Skills (`.zode/skills/`)
- End-to-end against Anthropic with your own key

## Code rules

- `std.ArrayList` is **unmanaged** in Zig 0.16: `.empty` + `append(gpa, x)`.
- `Mutex`: `std.atomic.Mutex`; `std.Thread.Mutex` no longer exists.
- `sendBodyComplete` requires a mutable `[]u8`; JSON bodies are built in stack buffers and passed with `@constCast`.
- `Writer.fixed` does not write to the terminal; use `File.Writer` + flush.
- `graphemes NEVER with &[_]u8{c}`: use `Painter.putText` or `putStable`.

## Reporting issues

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include:

- Zig version (`zig version`)
- The failing command (`zig build`, `./zig-out/bin/zode --chat ...`, etc.)
- `ZODE_DBG_ERR=1` output if applicable
- If it crashes: `coredumpctl info <pid>` result or whether `zig build debug` reproduces it

## License

MIT (see [`LICENSE`](LICENSE)). By contributing, you agree your code is licensed under MIT.
