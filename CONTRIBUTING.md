# Contributing to zode

Thanks for your interest in `zode`. It is a pure Zig code harness, built to be fast, simple, and free of mandatory external dependencies.

## Before you start

- This project uses **Zig 0.17**. Make sure `zig` is in your `PATH`.
- All code lives under `src/`; tests run with `zig build test`.
- There is no required `CMake`, `Make`, or `npm`: only `zig build`, `zig test`, and `zig build -Doptimize=ReleaseSafe`.

## How to contribute

1. **Fork + branch**: create a descriptive branch (`feat/rol`, `fix/scroll`, etc.).
2. **Keep "pure Zig std"**: no mandatory `libc`, only `libvaxis` as an optional external dependency.
3. **Keep tests green**: `zig build test` must pass. There are 2000+ tests; if you add a file, add its test.
4. **Document with AGENTS.md in mind**: comments and test names should be in English; identifiers are never translated.
5. **No TODOs**: `AGENTS.md` explicitly forbids them.

## Testing

| Command | What it checks |
|---|---|
| `zig build test` | Everything; `-Dtest-filter=name` runs one test group |
| `zig build test -Dlive` | Live-provider tests (needs keys) |
| `zig build test -De2e` | End-to-end scenarios |
| `zig build pty-check` | The pty smoke scripts |
| `zig build hooks-check` | Real headless tool-loop gates: a PostToolUse hook and a background completion drain (fake provider, no key) |
| `zig build ui-frame` | Renders real scenes with real draw functions |
| `zig build memaudit` | Static audit for use-after-free patterns |
| `zig build churn -Drun-args="version --beta"` | A runnable step with arguments (`-Drun-args`) |

Pure logic goes in `src/lib/` with inline tests and an import in `src/test_all.zig`
(otherwise its tests never run). TUI tests live in `src/tui_tests.zig`.

Phase 13 modules have reference harnesses in `tools/`: `remote_server.py` for
`/remote`, `fake_mcp.py` for MCP. See `tools/README.md`.

## Build steps

`zig build --help` lists all steps. The main ones: `build` (default ReleaseSmall),
`debug` (symbolized binary), `tool-test`, `check-probe`, `shell-probe`,
`roster-probe`, `lsp-probe`, `ui-frame`, `pty-check`, `diag`, `memaudit`, `churn`.

## Areas that need help

- **Windows support is not implemented and is not on the roadmap.** The crash
  handler (signals, `/dev/tty`, raw terminal restore), the pty harnesses and the
  keychain backend are POSIX-only. Use WSL or a Linux VM if you need zode on
  Windows; a native port would be a redesign, not a patch.
- End-to-end verification against a real Anthropic key (`zig build test -De2e`).
- The remaining mission-runtime gaps in [`docs/mission-gaps.md`](docs/mission-gaps.md).
  The `TASKS.md` quality backlog (Phases 40–51) is fully closed.

Checksum verification and the generated command reference are DONE (Phases 45.2
and 45.6); they are no longer open areas.

## Code rules

- `std.ArrayList` is **unmanaged** in Zig 0.17: `.empty` + `append(gpa, x)`.
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
