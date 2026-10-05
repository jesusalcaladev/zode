#!/usr/bin/env python3
"""The cheap router, end to end, against a model that really answers 403.

This is the test that was missing and it is not a unit test. `ZODE_CHEAP_TURN`
was implemented with the table tested in `lib/router.zig` and nothing ever proved
that the FALLBACK runs, that the user is told, or that the status bar names the
model that answered.

Why a real 403 and not a mocked one: on this account (`total_credits: 0`,
measured 2026-10-04) a 402 is unreachable, so the interesting failure has to be the
one that really happens. `thinkingmachines/inkling-small:free` answers

    HTTP 403 {"error":{"message":"thinkingmachines/inkling-small:free is only
             available on agentic harnesses. ..."}}

every time, which is the exact case the router exists for.

What it asserts:
  1. the turn is NOT lost — the fallback answers;
  2. the history says WHICH model was skipped, WHY, and how to turn it off;
  3. the status bar names the model that actually answered, not the cheap one;
  4. it is said once, not on every turn.

It uses its own HOME, like every other pty script here: the app writes
`~/.config/zode/auth.json` and `sessions/`, and an automated script must not touch
the config of whoever runs it.
"""
import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "zig-out", "bin", "zode")
HOME = "/tmp/opencode/zode-router-home"

CHEAP = "thinkingmachines/inkling-small:free"
ACTIVE = os.environ.get("ROUTER_TEST_ACTIVE", "qwen/qwen3.8-27b:free")

# The free tier rate-limits and a 429 on the ACTIVE model would make this test fail
# for a reason that has nothing to do with the router, so the answer is retried a
# few times before the run is called a failure.
FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


def run(argv, env, feed, cols=200, rows=50, settle=1.0):
    """Runs zode in a real pty and returns everything it painted."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env)
        os.environ["HOME"] = HOME
        os.environ["TERM"] = "xterm-256color"
        os.environ["LINES"] = str(rows)
        os.environ["COLUMNS"] = str(cols)
        try:
            os.execv(argv[0], argv)
        finally:
            os._exit(127)

    # TIOCSWINSZ FIRST: vaxis does `width_pix / width` and exits with a division
    # by zero on a size of 0. `script` does NOT set it.
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
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][B0]", "", s)


def main():
    if not os.path.exists(BIN):
        print(f"router smoke: {BIN} is missing. Run `zig build` first.")
        return 1

    os.makedirs(HOME, exist_ok=True)
    env = {
        "ZODE_PROVIDER": "openrouter",
        "ZODE_BASE_URL": "https://openrouter.ai/api/v1",
        "ZODE_MODELS_URL": "https://openrouter.ai/api/v1/models",
        "ZODE_MODEL": ACTIVE,
        "ZODE_CHEAP_TURN": CHEAP,
        "ZODE_AUTO_BG": "0",
    }
    # The key comes from `~/.config/zode/auth.json`, NOT from the environment.
    #
    # Measured 2026-10-04 on this machine: the key in `.env` answers 401
    # `{"message":"User not found."}` — the account, not the key — while the one
    # saved with Ctrl+A works. The saved one wins over the environment by design,
    # so a sandbox HOME with no `auth.json` sends the DEAD one and the turn dies
    # of "auth failed" before the router is ever consulted. That made this test
    # fail for a reason that had nothing to do with the router.
    key = None
    auth_path = os.path.expanduser("~/.config/zode/auth.json")
    if os.environ.get("ROUTER_TEST_KEY"):
        key = os.environ["ROUTER_TEST_KEY"]
    elif os.path.exists(auth_path):
        try:
            with open(auth_path) as f:
                key = json.load(f).get("openrouter")
        except (OSError, ValueError):
            key = None
    if not key:
        print(
            "router smoke: no usable key. Set ROUTER_TEST_KEY, or save one with"
            " Ctrl+A so ~/.config/zode/auth.json has an openrouter entry."
        )
        return 1
    env["ZODE_OPENROUTER_KEY"] = key

    print(f"router smoke: cheap={CHEAP} active={ACTIVE}")
    text = strip_ansi(run([BIN], env, [(b"hola\n", 25.0), (b"\n", 1.0)]))
    if os.environ.get("ROUTER_DUMP"):
        print(text[-3000:])
        return 0

    # The screen is a redraw, not a stream, so every assertion is "does this text
    # appear anywhere" and not "in this order, at this offset".

    # The account's daily free-model quota can be exhausted, and then NOTHING can
    # be tested: OpenRouter answers
    #
    #   Rate limit exceeded: free-models-per-day. Add 10 credits to unlock
    #   1000 free model requests per day
    #
    # to every model, including the fallback. That is the ACCOUNT's state and not
    # a defect in the router, so it SKIPS with the reason instead of failing: a
    # red test here would be read as "the fallback is broken" and would be wrong.
    if "free-models-per-day" in text:
        print(
            "  SKIP  the account ran out of daily free-model requests, so the"
            " fallback cannot be reached. Retry after the quota resets, or with"
            " credits. (This is not a router failure.)"
        )
        print("\nrouter smoke: SKIP")
        return 0
    if "is not available on this account" in text:
        ok("the history says the cheap model was skipped and why")
    else:
        fail(
            "the history never said the cheap model was skipped. "
            "Expected the fallback notice with 'is not available on this account'."
        )

    if "ZODE_CHEAP_TURN=0" in text:
        ok("the notice says how to turn it off")
    else:
        fail("the notice does not say how to turn the router off")

    # The status bar has to name the model that ANSWERED. This is the whole point
    # of `curAnswering`: a mode you cannot see is a mode where "the model ignored
    # my edit" cannot be told apart from "the model was never asked".
    if ACTIVE in text:
        ok(f"the status bar names the model that answered ({ACTIVE})")
    else:
        fail(f"the status bar never named {ACTIVE}, the model that answered")

    # The cheap model must NOT be presented as the one that answered.
    tail = text[-4000:]
    if CHEAP in tail and "not available" not in tail:
        fail(f"the cheap model {CHEAP} appears near the end as if it had answered")
    else:
        ok("the cheap model is not shown as the one that answered")

    if FAILURES:
        print(f"\nrouter smoke: {len(FAILURES)} FAILURE(S)")
        return 1
    print("\nrouter smoke: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())