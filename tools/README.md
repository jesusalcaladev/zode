# tools/ — zode's development harnesses

Every script is standalone. Run from the repo root unless noted.

## Primary gates (run these)

| Script / step | Purpose | Invocation |
|---|---|---|
| `zig build test` | All pure and integration tests | `zig build test` (filter: `-Dtest-filter=name`) |
| `pty_smoke.py` | Real 200x50 pty: startup, banner, input, palette, scroll, `!cmd`, no panic | `python3 tools/pty_smoke.py` |
| `copy_smoke.py` | `/copy` flow in a real pty | `python3 tools/copy_smoke.py` |
| `hooks_smoke.py` | Real PostToolUse hook in the headless tool loop, no key needed | `zig build hooks-check` |
| `background_smoke.py` | Real `bash run_in_background` job and its completion drain | `zig build hooks-check` |
| `segv_probe.py` | SIGSEGV: terminal restored, `pc:` line in `/tmp/zode-crash.log` | `python3 tools/segv_probe.py` |
| `zig build ui-frame` | Renders scenes with real draw functions | `zig build ui-frame` |
| `zig build memaudit` | Static audit for the two crash classes | `zig build memaudit` |

## Fixture servers (start first, then run the client)

| Script | Purpose | Invocation |
|---|---|---|
| `fake_provider.py` | Stateless OpenAI-compatible SSE server on `:11434` with scripted scenarios | `python3 tools/fake_provider.py &` |
| `fake_mcp.py` | Fake MCP stdio server | `python3 tools/fake_mcp.py` |
| `fake_lsp.py` | Fake language server | `python3 tools/fake_lsp.py` |
| `remote_server.py` | Reference `/remote` HTTP server over a sessions directory | `python3 tools/remote_server.py --dir <sessions> --token <token>` |

## Probes and reproductions (on demand)

| Script | Purpose |
|---|---|
| `ab_probe.py`, `input_probe.py`, `hang_probe.py`, `esc_kill_pty.py` | Input / pty edge cases |
| `ram_probe.py`, `ram_probe_replay.py` | Memory growth over long sessions |
| `scroll_repro.py`, `blocked_probe.py`, `crash_repro.py`, `stress_tui.py` | Historical TUI bug reproductions |
| `github_smoke.py`, `router_smoke.py`, `submodel_smoke.py`, `acp_smoke.py` | Feature-specific end-to-end checks |
| `measure.py` | Token / latency measurements |

## Release tooling

- `churn.zig` (built by `zig build churn`) — `churn --help` lists the four commands.
- `generate_changelog.py` — regenerates `CHANGELOG.md` from git history; derives the repo root from its own path, so it works from any cwd.
