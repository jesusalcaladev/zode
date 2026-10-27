#!/usr/bin/env python3
"""`/copy` end to end in a real pty, with no network and no key.

The unit tests cover the text (the arithmetic of `/copy N`, the fences, the
labels) and the wiring of the command (the picker opens, the file is written,
the message names the path). What they cannot cover is the app: the submit
chain, the modal picker painted by vaxis, and the answer on the screen — a
command can be perfectly unit-tested and still do nothing when it is typed,
which is how `/free-auto` went unnoticed.

So this drives the REAL binary with a REAL session (a fixture with an
assistant answer in it, resumed with `--resume`), and it asserts:

  1. `/copy` opens the picker with the whole answer, the code blocks and the
     "always" row;
  2. taking the whole answer writes the file the message names, with the
     answer in it;
  3. ESC is a cancel ("Copy cancelled"), not a failure.

It uses its own HOME and its own working directory, like every other pty
script here: the app writes `~/.config/zode/auth.json` and `sessions/`, and an
automated script must not touch the config — or the sessions — of whoever runs
it.

NOTE: no API key is set, on purpose. The ReleaseSmall build stops answering
keys when the active provider HAS a key (an open bug, see AGENTS.md), and
`/copy` needs no provider at all: it works on the session's own text.
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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "zig-out", "bin", "zode")
HOME = "/tmp/opencode/zode-copy-home"
CWD = "/tmp/opencode/zode-copy-cwd"
TMP = "/tmp/opencode/zode-copy-tmp"

FAILURES = []

ANSWER = (
    "Here is the snippet you asked for:\n"
    "\n"
    "```zig\n"
    "const smoke = 1;\n"
    "```\n"
    "\n"
    "And a second one:\n"
    "\n"
    "```zig\n"
    "const other = 2;\n"
    "```\n"
)


def fail(msg):
    FAILURES.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


def fixture_session():
    """A session with an assistant answer, so `/copy` has something to copy."""
    sessions = os.path.join(CWD, "sessions")
    os.makedirs(sessions, exist_ok=True)
    path = os.path.join(sessions, "zode-smoke1.jsonl")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write('{"role":"user","content":"give me a snippet"}\n')
        # The loader reads a plain JSON line; the answer is the model output.
        content = ANSWER.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        fh.write('{"role":"assistant","content":"%s"}\n' % content)
    return path


def run(env, feed, cols=160, rows=44, settle=1.5):
    """Starts the TUI, sends `keys` spaced out, and returns everything it painted."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(CWD)
        os.environ.update(env)
        os.environ["HOME"] = HOME
        os.environ["TERM"] = "xterm-256color"
        try:
            os.execv(BIN, [BIN, "--resume"])
        finally:
            os._exit(127)

    # TIOCSWINSZ FIRST: vaxis does `width_pix / width` and exits with a
    # division by zero on a size of 0.
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
    s = re.sub(r"\x1b\[[0-9;:?]*[a-zA-Z@]|\x1b\][^\x07]*\x07|\x1b[()][B0]", "", s)
    # The OSC 52 that vaxis writes carries the copied text in base64: it is
    # not part of the screen, and it would only make the checks noisier.
    s = re.sub(r"\x1b\]52;[^\x07\x1b]*(\x07|\x1b\\)", "", s)
    return s


def main():
    if not os.path.exists(BIN):
        print(f"copy smoke: {BIN} is missing. Run `zig build` first.")
        return 1
    for path in (HOME, CWD, TMP):
        shutil.rmtree(path, ignore_errors=True)
    os.makedirs(HOME, exist_ok=True)
    os.makedirs(CWD, exist_ok=True)
    os.makedirs(TMP, exist_ok=True)
    fixture_session()

    env = {"ZODE_AUTO_BG": "0", "TMPDIR": TMP}

    # 1. `/copy` opens the picker.
    text = strip_ansi(run(env, [
        (b"/copy\n", 2.0),
    ]))

    if "Full response" in text:
        ok("the picker offers the whole response")
    else:
        fail("the picker did not open (no 'Full response' row)")

    if "const smoke = 1;" in text:
        ok("the picker lists the code blocks by their first line")
    else:
        fail("the code block did not show up in the picker")

    if "Always copy full response" in text:
        ok("the picker has the 'always' row")
    else:
        fail("the 'always copy full response' row is missing")

    # 2. Taking the whole answer writes the file and says so.
    text2 = strip_ansi(run(env, [
        (b"/copy\n", 2.0),
        (b"\r", 2.0),
    ]))
    if "Copied to" in text2:
        ok("the copy says what it copied")
    else:
        fail("no 'Copied to' line after taking the whole answer")

    written = os.path.join(TMP, "zode", "response.md")
    if os.path.exists(written):
        with open(written, encoding="utf-8") as fh:
            body = fh.read()
        if "const smoke = 1;" in body:
            ok("the file on disk has the answer in it")
        else:
            fail(f"{written} does not have the answer in it")
    else:
        fail(f"{written} was not written")

    # 3. ESC is a cancel, not a failure.
    text3 = strip_ansi(run(env, [
        (b"/copy\n", 2.0),
        (b"\x1b", 1.5),
    ]))
    if "Copy cancelled" in text3:
        ok("ESC says the copy was cancelled")
    else:
        fail("ESC did not say 'Copy cancelled'")

    if FAILURES:
        print(f"\ncopy smoke: {len(FAILURES)} FAILURE(S)")
        if os.environ.get("SMOKE_DUMP"):
            print(text[-4000:])
            print("---- second run ----")
            print(text2[-4000:])
        return 1
    print("\ncopy smoke: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
