#!/usr/bin/env python3
"""Reproduce the crash: a real turn that plans and then uses tools.

Runs zode in a real pty (vaxis needs one), types a prompt that makes the
model plan and code, then keeps the session alive long enough to either
crash or finish. Its own HOME, so a test never touches the real config.

  python3 tools/crash_repro.py [--bin PATH] [--seconds N] [--mouse]
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

HOME = "/tmp/opencode/zode-crash-home"
ROWS, COLS = 50, 200

# A prompt that forces a plan and then real edits + a build.
PROMPT = (
    "Add a function `fib(n)` to src/fib.zig with tests, run zig build test, "
    "and fix whatever fails. Make a plan first."
)

# Mouse motion report (SGR, mode 1003 = any motion): ESC [ < b ; col ; row M
def sgr_motion(col, row):
    return f"\x1b[<35;{col};{row}M".encode()


def drain(fd, seconds):
    """Read for `seconds`, keeping the pty buffer empty (a full buffer
    blocks the child and looks like a hang)."""
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
    ap.add_argument("--mouse", action="store_true", help="sprinkle mouse motion")
    args = ap.parse_args()

    os.makedirs(HOME, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = HOME
    env["TERM"] = "xterm-256color"
    env["ZODE_AUTO_CHECK"] = "1"
    env["ULIMIT_CORE"] = "unlimited"

    # Run from a scratch project so the edits do not touch this repo.
    work = "/tmp/opencode/zode-crash-work"
    os.makedirs(work, exist_ok=True)

    # Resolved BEFORE the child `chdir`s: the work directory is a scratch
    # project, and a relative `--bin` would be looked up inside it.
    binary = os.path.abspath(args.bin)

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execve(binary, [binary], env)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    out = bytearray()
    out += drain(fd, 6.0)

    os.write(fd, PROMPT.encode() + b"\r")
    deadline = time.time() + args.seconds
    col = row = 2
    while time.time() < deadline:
        out += drain(fd, 2.0)
        if args.mouse:
            col = col % 180 + 1
            row = row % 45 + 1
            try:
                os.write(fd, sgr_motion(col, row))
            except OSError:
                break
            # Some keypresses interleaved, which is what the report mentions.
            if int(time.time()) % 3 == 0:
                try:
                    os.write(fd, b"\x1b")
                except OSError:
                    break
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid:
            break
    else:
        os.write(fd, b"\x03")  # ctrl+c
        drain(fd, 1.0)

    try:
        wpid, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    out += drain(fd, 1.0)
    os.close(fd)

    sig = os.WTERMSIG(status) if os.WIFSIGNALED(status) else 0
    rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else None
    text = bytes(out).decode("utf-8", "replace")

    panics = re.findall(r"(?s)(panic[^\n]*|thread panic[^\n]*|SIGSEGV[^\n]*)", text)
    print(f"exit: signal={sig} code={rc}")
    for p in panics[:6]:
        print("PANIC:", p.strip()[:400])

    # Is the panic on screen, or only in the log?
    log = "/tmp/opencode/zode-crash.log"
    with open(log, "wb") as f:
        f.write(bytes(out))
    print(f"log: {log} ({len(out)} bytes)")
    if sig:
        print(f"\ncore? coredumpctl info {pid}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())