# Security Policy

## Supported Versions

Only the `main` branch (or the latest tagged release) receives security fixes. There is no LTS support.

## Reporting a Vulnerability

Do not open a public issue for security vulnerabilities. Reach out directly:

- Email: `jesusalcaladev` (replace with the domain from the GitHub profile: `jesusalcaladev`)
- Or open a [draft security advisory](https://github.com/jesusalcaladev/zode/security/advisories/new) on GitHub if available.

Include:

- A brief description of the risk
- If applicable: reproduction steps (`zig build`, a specific command, a malicious URL)
- Environment (`Linux`, Zig 0.16, release or debug)
- If there is a core dump or `ZODE_DBG_ERR=1` message, include it

## What counts as a vulnerability

- Arbitrary code execution through `bash` or a subagent
- API key leakage (`~/.config/zode/auth.json`, `.env`, environment variables)
- Unauthorized file access outside the project directory through `read`, `glob`, `grep`
- Memory leaks that enable DoS (`std.Io.Mutex`, unfreed arena, orphaned child processes)
- TLS/HTTP issues that expose data to intermediaries

## What is NOT a vulnerability (report as a bug)

- A model that responds poorly or generates incorrect code
- The app not starting without `zig` in `PATH`
- A reproducible crash with `zig build debug` that is a code segfault, not an exploit
- A leftover temporary file (`.tmp`) in `sessions/` after an abrupt shutdown

## Response Time

I aim to confirm within 72 hours and publish a patch or advisory within a week if it is reproducible.
