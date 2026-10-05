#!/usr/bin/env python3
"""Measures RSS across a LONG session, with the real model answering.

`measure.py` answers "how much does it use at startup". This one answers the
question that actually matters and that nobody had measured: **does it grow**.

A harness that is 6 MB on an empty screen and 200 MB after two hours is not a
6 MB harness, and the number that gets quoted is the first one.

How it works:
  - a real pty, because the TUI needs a terminal and `script` does not set the
    window size (vaxis does `width_pix / width` and divides by zero)
  - the REAL key, copied into a sandbox HOME, because a session with no model
    answering never allocates a conversation
  - one prompt per turn, waiting for the turn to finish before the next, and a
    VmRSS sample after each one

The growth it reports is the number worth watching: `per turn` is the slope, and
a slope that does not flatten is a leak whatever the total says.

Usage:
    python3 tools/ram_probe.py [binary] [turns]

    ZODE_RAM_PROBE_MODEL / ZODE_RAM_PROBE_PROVIDER override the model.
    ZODE_RAM_PROBE_PROMPT overrides what each turn asks.
"""

import fcntl
import json
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
# Absolute, because the child chdir()s into a sandbox WORKDIR before exec: a
# relative path here fails with FileNotFoundError and the probe reports six
# TIMEOUTs and a dead process instead of a measurement.
BINARY = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zode")
TURNS = int(sys.argv[2]) if len(sys.argv) > 2 else 8
SANDBOX_HOME = "/tmp/opencode/zode-ram-home"
WORKDIR = "/tmp/opencode/zode-ram-work"

PROMPT = os.environ.get(
    "ZODE_RAM_PROBE_PROMPT",
    "List the files in src/tools with glob, then read the first one, then tell "
    "me in one line how many tools there are. Do not edit anything.",
)


def sandbox():
    """A HOME with the working key, and a cwd with something to look at.

    The key is COPIED, not read: the real `~/.config/zode/auth.json` is what makes
    the provider answer, and an automated script must not touch the config of
    whoever runs it. This is the same rule `pty_smoke.py` follows.
    """
    shutil.rmtree(SANDBOX_HOME, ignore_errors=True)
    os.makedirs(SANDBOX_HOME + "/.config/zode", exist_ok=True)
    real = os.path.expanduser("~/.config/zode/auth.json")
    if os.path.exists(real):
        shutil.copy(real, SANDBOX_HOME + "/.config/zode/auth.json")
        os.chmod(SANDBOX_HOME + "/.config/zode/auth.json", 0o600)
    else:
        print("no auth.json to copy: the session would answer nothing", file=sys.stderr)

    shutil.rmtree(WORKDIR, ignore_errors=True)
    os.makedirs(WORKDIR + "/src/tools", exist_ok=True)
    for name in os.listdir("src/tools"):
        if name.endswith(".zig"):
            shutil.copy(os.path.join("src/tools", name), WORKDIR + "/src/tools/" + name)
    return SANDBOX_HOME


def rss_kb(pid):
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        return None
    return None


def drain(fd, seconds):
    """Reads the pty so the child never blocks on a full buffer.

    A pty holds ~64 KB. A child that writes more than that and is not read
    BLOCKS, which looks exactly like a hang and is not one.
    """
    end = time.time() + seconds
    got = b""
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
        got += chunk
    return got


def turn_is_finished(buf):
    """The turn ends when the status bar says `done`.

    Matching on the word rather than on a fixed sleep is what makes the slope
    meaningful: a sleep long enough for a slow turn makes every sample land after
    the turn anyway, and a short one samples mid-turn and reports the streaming
    buffer instead of the settled size.
    """
    text = buf.decode("utf-8", "replace")
    return re.search(r"done · \d+\.\d+s", text) is not None


def main():
    home = sandbox()
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["HOME"] = home
        os.environ["TERM"] = "xterm-256color"
        os.environ["ZODE_MODEL"] = os.environ.get("ZODE_RAM_PROBE_MODEL", "space-bunny-free")
        os.environ["ZODE_PROVIDER"] = os.environ.get("ZODE_RAM_PROBE_PROVIDER", "opencode")
        os.environ["ZODE_RESUME"] = "0"
        os.chdir(WORKDIR)
        os.execv(BINARY, [BINARY])
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    drain(fd, 2.0)

    series = []
    base = rss_kb(pid)
    series.append(("startup", base))

    for i in range(TURNS):
        os.write(fd, PROMPT.encode() + b"\r")
        buf = b""
        deadline = time.time() + 180
        finished = False
        while time.time() < deadline:
            buf += drain(fd, 1.0)
            if turn_is_finished(buf):
                finished = True
                # Let the frame after `done` land before sampling.
                drain(fd, 1.5)
                break
        kb = rss_kb(pid)
        series.append(("turn %d%s" % (i + 1, "" if finished else " TIMEOUT"), kb))
        if not finished:
            print("turn %d did not finish in 180 s: the slope below is not usable"
                  % (i + 1), file=sys.stderr)

    try:
        os.write(fd, b"\x03")  # ctrl+c
        drain(fd, 1.0)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

    print()
    print("RAM across %d turns (%s)" % (TURNS, os.environ.get("ZODE_RAM_PROBE_MODEL", "space-bunny-free")))
    print("-" * 58)
    for label, kb in series:
        if kb is None:
            print("  %-16s  (gone)" % label)
            continue
        delta = kb - series[0][1]
        print("  %-16s  %7.2f MB   %+7.2f MB" % (label, kb / 1024.0, delta / 1024.0))
    print("-" * 58)

    usable = [(l, k) for l, k in series[1:] if k is not None and "TIMEOUT" not in l]
    if len(usable) >= 2:
        per_turn = (usable[-1][1] - usable[0][1]) / float(len(usable) - 1)
        print("  per turn: %+.1f KB" % per_turn)
        if per_turn > 60:
            print("  VERDICT: growing. A slope that does not flatten is a leak "
                  "whatever the total says.")
        elif per_turn > 15:
            print("  VERDICT: small growth; watch it, it may be the segment cache "
                  "filling up (which is capped) or a real leak.")
        else:
            print("  VERDICT: flat. The size does not depend on how long the "
                  "session is.")
    else:
        print("  not enough finished turns to say anything")


if __name__ == "__main__":
    main()
