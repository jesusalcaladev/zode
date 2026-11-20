#!/usr/bin/env python3
"""Verify the segfault path end to end: the terminal is restored and the crash
log is written before the process dies.

  python3 tools/segv_probe.py [--bin PATH]
"""
import argparse
import fcntl
from pathlib import Path
import re
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

HOME = "/tmp/opencode/zode-segv-home"
CRASH_LOG = "/tmp/zode-crash.log"
ROOT = Path(__file__).resolve().parents[1]


def restore_sequence() -> bytes:
    """Read the exact bytes from termseq.zig, the single source of truth.

    The probe used to hard-code `RESTORE_ALL`, so a change to the Zig constant
    made the probe fail (or, worse, pass on a stale sequence) without anyone
    noticing the drift.
    """
    src = (ROOT / "src" / "lib" / "termseq.zig").read_text(errors="replace")
    match = re.search(r'pub const restore_all = "((?:\\.|[^"\\])*)";', src)
    if not match:
        raise RuntimeError("could not find restore_all in src/lib/termseq.zig")
    return match.group(1).encode("ascii").decode("unicode_escape").encode("latin1")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="./zig-out/bin/zode")
    args = ap.parse_args()

    os.makedirs(HOME, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = HOME
    env["TERM"] = "xterm-kitty"

    try:
        os.remove(CRASH_LOG)
    except FileNotFoundError:
        pass

    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(args.bin, [args.bin], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    out = bytearray()
    start = time.time()
    while time.time() - start < 6.0:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if b"Ask anything" in out and b"\x1b[?25h" in out:
                break
    if b"Ask anything" not in out:
        print("FAIL: zode never painted its composer")
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        return 1

    os.kill(pid, signal.SIGSEGV)

    deadline = time.time() + 5.0
    status = None
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if chunk:
                out += chunk
            else:
                # EOF: the child is gone (or the slave closed); reap it.
                _, status = os.waitpid(pid, 0)
                break
        w, st = os.waitpid(pid, os.WNOHANG)
        if w:
            status = st
            break
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        print("FAIL: still alive after SIGSEGV")
        return 1

    failed = False
    if not os.WIFSIGNALED(status):
        print("FAIL: expected a signal death, got exit", os.WEXITSTATUS(status))
        failed = True

    # Require the FULL restore sequence, not one byte that could come from a
    # normal redraw. Read it from the Zig source so the two cannot drift.
    RESTORE_ALL = restore_sequence()
    if RESTORE_ALL not in out:
        print("FAIL: the full termseq.restore_all sequence never reached the pty")
        failed = True

    try:
        with open(CRASH_LOG, "r", errors="replace") as f:
            log = f.read()
    except FileNotFoundError:
        print(f"FAIL: {CRASH_LOG} was not written")
        return 1
    if "Segmentation fault" not in log:
        print("FAIL: crash log does not name the signal")
        print(log)
        failed = True
    if "frames:" not in log:
        print("FAIL: crash log has no frames section")
        failed = True
    if "pc:" not in log:
        print("FAIL: crash log has no pc: entry from the segfault handler")
        failed = True

    print("segv: OK" if not failed else "segv: FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
