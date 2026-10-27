#!/usr/bin/env python3
"""Hammer the TUI's agent loop until it crashes, or until we are bored.

It needs `tools/fake_provider.py` running (no key, no quota, no internet):

    python3 tools/fake_provider.py &
    python3 tools/stress_tui.py [--bin zig-out/bin/zode-debug] [--seconds 180]

Every prompt is a scenario the fake provider answers with real tool calls
(background bash, edits, a big diff, an `ask`, parallel reads, a repeated call),
and between turns it presses the keys that have actually broken this app before:
ctrl+r on a diff, scrolling while text arrives, the palette, `/new`, `/resume`,
ESC mid-stream and mouse motion.

Its own HOME, so a run never touches the real config — the fuzzing session of
2026-06-26 saved a pasted key into the real `auth.json` through a test like
this one.

A crash is reported with the signal and the shell's own message, which is the
only witness that has ever been reliable here: `waitpid` on a SIGILL/SIGSEGV
child prints nothing, and a probe that kills the child first reports the kill.
"""
import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

HOME = "/tmp/opencode/zode-stress-home"
ROWS, COLS = 45, 140

# (prompt, seconds to let it run, keys to press afterwards).
#
# NO `\x03` in here on purpose: ctrl+c QUITS the app, and a driver that sends it
# mid-round reports "the app died during beat N" about a quit it asked for. The
# round ends with one ctrl+c and checks THAT exit (see below).
BEATS = [
    ("edit the file please", 8, ["\x12", "\x15", "\x10\x1b"]),        # ctrl+r, ctrl+u, ctrl+p, esc
    ("run something in the background", 10, ["\x12", "\x0c"]),
    ("make a plan first", 8, ["\x12", "\x1b"]),
    ("ask me which database", 6, ["\x1b", "\x1b"]),                    # esc declines the ask
    ("read three files at once", 8, ["\x12", "\x1b"]),
    ("rewrite the big file", 10, ["\x12", "\x12", "\x15\x0b", "\x12"]),  # expand, collapse, half page up
    ("read the same file again", 12, ["\x12", "\x1b"]),
]

EXTRA_KEYS = [
    "\x1b[<35;12;7M", "\x1b[<35;40;20M", "\x1b[<0;40;20M",   # mouse motion + press
    "\x1b[5~", "\x1b[6~",                                     # page up / down
    "\x0c",                                                   # ctrl+l
]


def drain(fd, seconds):
    """Read for `seconds`, always keeping the pty buffer empty: a full buffer
    blocks the child and looks exactly like a hang."""
    end = time.time() + seconds
    out = bytearray()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="zig-out/bin/zode-debug")
    ap.add_argument("--seconds", type=float, default=180.0)
    ap.add_argument("--provider-port", type=int, default=11434)
    args = ap.parse_args()

    binary = os.path.abspath(args.bin)
    if not os.path.exists(binary):
        print("no such binary:", binary)
        return 2

    os.makedirs(HOME, exist_ok=True)
    env = {
        "HOME": HOME,
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "LANG": "C.UTF-8",
        "ZODE_PROVIDER": "local",
        "ZODE_MODEL": "fake-1",
        "ZODE_BASE_URL": "http://127.0.0.1:%d/v1" % args.provider_port,
        "ZODE_MODELS_URL": "http://127.0.0.1:%d/v1/models" % args.provider_port,
        # The fake provider has no cache stats and no retry semantics worth
        # spending seconds of backoff on: keep the run about the UI.
        "ZODE_AUTO_BG": "0",
    }

    rounds = 0
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        rounds += 1
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(binary, [binary], env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

        boot = drain(fd, 3.0)
        # `/yolo`: the beats are about the LOOP and the drawing, not about the
        # permission dialog. A driver that leaves the dialog unanswered reads as
        # "the agent stopped after the first tool call", which is exactly how
        # this investigation wasted an hour before looking at the screen.
        os.write(fd, b"/yolo\r")
        boot += drain(fd, 1.5)
        crashed = False
        reaped = False
        for prompt, wait, keys in BEATS:
            os.write(fd, prompt.encode() + b"\r")
            alive = drain(fd, wait)
            out = boot + alive
            for k in keys:
                os.write(fd, k.encode() if not k.startswith("\x1b[") else k.encode("latin-1"))
                drain(fd, 0.8)
            # The app is EXPECTED to be alive here: every beat is a turn, and a
            # quit only comes at the end of the round. A child that is gone in
            # the middle is the failure this whole probe exists for, and a
            # SIGNAL is the only witness that has ever been reliable (the
            # shell's own message is the same evidence).
            done, status = os.waitpid(pid, os.WNOHANG)
            if done != 0:
                reaped = True
                print("\n!!! round %d died during beat %r: %s"
                      % (rounds, prompt,
                         "signal %d" % os.WTERMSIG(status) if os.WIFSIGNALED(status)
                         else "exit %d" % os.WEXITSTATUS(status)))
                plain = re.sub(rb"\x1b\[[0-9;:?]*[a-zA-Z]", b"", out)
                print(plain[-1200:].decode("utf-8", "replace"))
                crashed = True
                break
        else:
            # Every beat answered with the app still up. Now quit it and check
            # that the QUIT is clean: a crash on the way out is a whole family
            # this repo has already paid for twice (the warmup defer, the
            # palette's free), and a driver that only watches the turns never
            # sees it.
            os.write(fd, b"\x03")
            drain(fd, 2.0)
            done, status = os.waitpid(pid, os.WNOHANG)
            if done == 0:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            else:
                reaped = True
                if os.WIFSIGNALED(status):
                    print("!!! round %d crashed on QUIT with signal %d" % (rounds, os.WTERMSIG(status)))
                    crashed = True

        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if not reaped:
            os.waitpid(pid, 0)
        if crashed:
            return 1
        print("round %d ok" % rounds, flush=True)

    print("no crash in %d rounds" % rounds)
    return 0


if __name__ == "__main__":
    sys.exit(main())
