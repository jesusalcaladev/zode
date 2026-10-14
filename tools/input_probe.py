#!/usr/bin/env python3
"""Which inputs reach the TUI when it hangs.

The report is "I move the mouse or press a key and nothing happens" while the
banner is on screen. This sends each kind of event in turn and reports the
bytes the app produced, so the stuck surface is named: no keys at all means the
input loop, keys but no redraw means the draw, and only a resize working
means vaxis's parser thread is fine and the queue is not being drained.

  python3 tools/input_probe.py [--bin PATH] [--wait SECONDS]
"""
import argparse
import fcntl
import os
import pty
import select
import shutil
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200


def drain(fd: int, sec: float) -> bytes:
    out = bytearray()
    t0 = time.time()
    while time.time() - t0 < sec:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            c = os.read(fd, 65536)
        except OSError:
            break
        if not c:
            break
        out += c
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="zig-out/bin/zode")
    ap.add_argument("--wait", type=float, default=14.0)
    args = ap.parse_args()

    sandbox = "/tmp/opencode/zode-input-probe"
    shutil.rmtree(sandbox, ignore_errors=True)
    cfg = os.path.join(sandbox, ".config", "zode")
    os.makedirs(cfg, exist_ok=True)
    real = os.path.expanduser("~/.config/zode/auth.json")
    if os.path.exists(real):
        shutil.copyfile(real, os.path.join(cfg, "auth.json"))
        os.chmod(os.path.join(cfg, "auth.json"), 0o600)

    env = dict(os.environ)
    env["HOME"] = sandbox
    env["TERM"] = "xterm-256color"
    env["ZODE_RESUME"] = "0"

    binary = os.path.abspath(args.bin)
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(binary, [binary], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    boot = drain(fd, args.wait)
    print(f"boot: {len(boot)} bytes")

    cases = [
        ("a printable key", b"h"),
        ("Enter", b"\r"),
        ("ESC", b"\x1b"),
        ("ctrl+c (exits)", b"\x03"),
        ("a mouse motion report", b"\x1b[<35;4;4M"),
    ]
    for label, chunk in cases:
        try:
            os.write(fd, chunk)
        except OSError:
            print(f"{label}: pty closed")
            break
        n = len(drain(fd, 6))
        print(f"{label}: {n} bytes")

    # SIGWINCH goes through a path no input can: the window size.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 180, 0, 0))
    print(f"resize: {len(drain(fd, 6))} bytes")

    try:
        os.kill(pid, 0)
        print("process: still alive")
    except OSError:
        print("process: exited on its own")
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except OSError:
        pass
    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
