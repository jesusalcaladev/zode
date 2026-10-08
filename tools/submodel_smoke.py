#!/usr/bin/env python3
"""`/submodel` end to end in a real pty, with no network and no key.

Unit tests cover the resolution (which of session/config/environment wins) and
the notes. What they cannot cover is the WIRING: the submit chain dispatching
`submodel`, `cmdGroup` putting it in the palette's group, and `pushInfoFmt`
painting the report through vaxis — a command can be perfectly unit-tested and
still do nothing when typed, which is how `/free-auto` went unnoticed.

It runs on the local state only, so unlike `router_smoke.py` it needs no key and
no account: the report is what decides, and the report is composed before any
request would be made.

What it asserts:
  1. `/submodel` with no args reports that subagents follow the main turn;
  2. `/submodel <model>` resolves against the ACTIVE provider and says so;
  3. it names `/submodel off` as the way back;
  4. `off` is reported as no override again;
  5. an unknown provider comes back as "CANNOT be used", not as a dead TUI.

It uses its own HOME, like every other pty script here: the app writes
`~/.config/zode/auth.json` and `sessions/`, and an automated script must not
touch the config of whoever runs it.
"""
import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "zig-out", "bin", "zode")
HOME = "/tmp/opencode/zode-submodel-home"

FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


def run(env, feed, cols=160, rows=44, settle=1.2):
    """Starts the TUI, sends `keys` spaced out, and returns everything it painted."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env)
        os.environ["HOME"] = HOME
        os.environ["TERM"] = "xterm-256color"
        try:
            os.execv(BIN, [BIN])
        finally:
            os._exit(127)

    # TIOCSWINSZ FIRST: vaxis does `width_pix / width` and exits with a division
    # by zero on a size of 0.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    out = bytearray()

    def drain(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if fd in r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                out.extend(chunk)
        return True

    drain(settle)
    for keys, wait in feed:
        os.write(fd, keys)
        if not drain(wait):
            break
    try:
        os.write(fd, b"\x03")  # ctrl+c, the documented exit
        drain(1.0)
    except OSError:
        pass
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
    os.close(fd)
    return out.decode("utf-8", errors="replace")


def strip_ansi(s):
    # The COLON in a truecolor SGR matters (see router_smoke.py): zode emits
    # `\x1b[38:2:74:81:112m` and a `[0-9;?]*` pattern leaves the escape alive
    # inside the string a check asserts on.
    return re.sub(r"\x1b\[[0-9;:?]*[a-zA-Z@]|\x1b\][^\x07]*\x07|\x1b[()][B0]", "", s)


def main():
    if not os.path.exists(BIN):
        print(f"submodel smoke: {BIN} is missing. Run `zig build` first.")
        return 1
    os.makedirs(HOME, exist_ok=True)

    # A key is present so the report shows the RESOLVED state (`.ok`) rather
    # than "no API key" — the wiring being tested is the report, and a report
    # that stops at a missing credential would not exercise the happy path.
    env = {"ZODE_AUTO_BG": "0", "ZODE_API_KEY": "smoke-test-key-not-real"}

    text = strip_ansi(run(env, [
        (b"/submodel\n", 1.5),
        (b"/submodel kimi-k2.6\n", 1.5),
        (b"/submodel\n", 1.5),
        (b"/submodel off\n", 1.5),
    ]))

    if "the same model as the main turn (no override)" in text:
        ok("with no override it says subagents follow the main turn")
    else:
        fail("the empty /submodel report never appeared")

    if "opencode/kimi-k2.6 (/submodel)" in text:
        ok("a model-only set resolves against the active provider")
    else:
        fail("the set was not reported as opencode/kimi-k2.6 (/submodel)")

    if "Off with /submodel off." in text:
        ok("the report names /submodel off as the way back")
    else:
        fail("the report does not say how to undo it")

    if text.count("the same model as the main turn") >= 2:
        ok("off is reported as no override again")
    else:
        fail("/submodel off did not report no override")

    # A spelling nobody can have: the report has to say WHY it cannot be used,
    # because a stored pick that says nothing looks like a pick that works.
    text2 = strip_ansi(run(env, [
        (b"/submodel proveedor-inexistente some-model\n", 1.5),
        (b"/submodel\n", 1.5),
    ]))
    if "CANNOT be used" in text2 and "proveedor-inexistente" in text2:
        ok("an unknown provider is reported as unusable, not fatal")
    else:
        fail("an unknown provider was not reported as unusable")
        if os.environ.get("SMOKE_DUMP"):
            print(text2[-2500:])

    if FAILURES:
        print(f"\nsubmodel smoke: {len(FAILURES)} FAILURE(S)")
        return 1
    print("\nsubmodel smoke: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
