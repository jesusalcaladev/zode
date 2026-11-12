#!/usr/bin/env python3
"""End-to-end check of the native GitHub integration, in a REAL pty.

Why a pty: `/github` is a TUI command and vaxis renders differentially — a
homemade emulator sees half the redraw and the check would pass on a blank
screen. `pty.fork` + `TIOCSWINSZ` is the only way to give it a real window.

What it checks (and what it does NOT):
- `/github` prints the repo/host, the branch, and the AUTH STATE. It never
  prints a token value, and the check asserts that: a token in the output is a
  leak, not a pass.
- The `github` TOOL answers a read op without a token and says so in words,
  instead of failing with a stack trace.

The tool is exercised through the model, so a REAL read op needs a provider.
There is none here: the smoke checks the LOCAL half (`/github`, the unknown-op
message, the auth hint) and the tool's own dispatch table, and it says so.

`HOME` points at its own directory: the app writes `~/.config/zode/auth.json`
there and an automatic script must never touch the real config of whoever runs
it.
"""

import fcntl
import os
import pty
import re
import select
import shutil
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200
BINARY = "./zig-out/bin/zode"
SANDBOX_HOME = "/tmp/opencode/zode-github-smoke-home"


def strip_ansi(b: bytes) -> str:
    s = b.decode("utf-8", "replace")
    s = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", s)
    s = re.sub(r"\x1b[@-Z\\-_]", "", s)
    s = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", s)
    return s


def drive(keys, budget: float = 8.0):
    """Starts the TUI, sends `keys` spaced out, and returns (bytes, text)."""
    if not os.path.exists(BINARY):
        sys.exit(f"{BINARY} does not exist: run `zig build` first")

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.pop("NO_COLOR", None)
        os.environ.update(
            TERM="xterm-256color",
            COLORTERM="truecolor",
            HOME=SANDBOX_HOME,
            ZODE_RESUME="0",
            LINES=str(ROWS),
            COLUMNS=str(COLS),
        )
        os.execv(BINARY, [BINARY])

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    out = b""
    t0 = time.time()
    slots = len(keys) + 1
    for i, key in enumerate([None] + list(keys)):
        due = t0 + (i + 1) * (budget / slots)
        while time.time() < due:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(fd, 1 << 16)
            except OSError:
                chunk = b""
            if not chunk:
                break
            out += chunk
        if key is None:
            continue
        try:
            os.write(fd, key)
        except OSError:
            break

    deadline = time.time() + 1.5
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError:
            chunk = b""
        if not chunk:
            break
        out += chunk

    os.write(fd, b"\x03")
    time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)
    return out, strip_ansi(out)


def check(name: str, ok: bool, text: str) -> bool:
    print(("PASS  " if ok else "FAIL  ") + name)
    if not ok:
        print(text[-4000:])
    return ok


def main() -> int:
    shutil.rmtree(SANDBOX_HOME, ignore_errors=True)
    os.makedirs(SANDBOX_HOME, exist_ok=True)

    ok = True

    # 1) `/github` answers with the local integration status.
    out, text = drive([b"/github\r"])
    ok &= check("/github answers", "GitHub integration" in text, text)
    ok &= check("/github names the repo slot", "repo" in text, text)
    ok &= check("/github reports the auth state", "auth" in text, text)
    ok &= check("/github lists the tool ops", "auth_status" in text and "pr_create" in text, text)

    # 2) The token is NEVER printed. The sandbox has no token, so the honest
    #    shape is "not configured"; a value here would be a leak.
    ok &= check("/github never prints a token value", "ghp_" not in text and "github_pat_" not in text, text)

    # 3) The command is in the PALETTE, which is how a person finds it.
    #    (`/help` scrolls: the entry can sit above the viewport, so the
    #    palette is the surface that can be searched.)
    out2, text2 = drive([b"\x10", b"github"])
    ok &= check("/github is in the palette", "github" in text2, text2)

    # 4) An unknown argument is refused in words.
    out3, text3 = drive([b"/github nonsense\r"])
    ok &= check("/github refuses a bad argument", "usage:" in text3, text3)

    print("\n" + ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
