#!/usr/bin/env python3
"""Base vs current, side by side, on the one condition that matters.

A pty harness that answers one question: does the app answer a keypress, and
with what configuration. It runs each binary N times with (a) no saved key and
(b) a real saved key on the active provider, and prints the verdict for each
run. A binary that "boots fine and then answers nothing" is the reported bug.

  python3 tools/ab_probe.py [--base PATH] [--current PATH] [--n N]
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


def run(binary: str, sandbox: str, auth: bool, wait: float) -> tuple[int, int, str]:
    shutil.rmtree(sandbox, ignore_errors=True)
    cfg = os.path.join(sandbox, ".config", "zode")
    os.makedirs(cfg, exist_ok=True)
    if auth:
        real = os.path.expanduser("~/.config/zode/auth.json")
        shutil.copyfile(real, os.path.join(cfg, "auth.json"))
        os.chmod(os.path.join(cfg, "auth.json"), 0o600)
    else:
        with open(os.path.join(cfg, "auth.json"), "wb") as f:
            f.write(b"{}")

    env = dict(os.environ)
    env["HOME"] = sandbox
    env["TERM"] = "xterm-256color"
    env["ZODE_RESUME"] = "0"

    pid, fd = pty.fork()
    if pid == 0:
        os.execve(binary, [binary], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def drain(sec):
        n = 0
        t0 = time.time()
        while time.time() - t0 < sec:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                c = os.read(fd, 65536)
            except OSError:
                break
            if not c:
                break
            n += len(c)
        return n

    boot = drain(wait)
    os.write(fd, b"h")
    after = drain(wait)
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except OSError:
        pass
    os.close(fd)
    return boot, after, "DEAD" if after == 0 else "answers"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="/tmp/opencode/z-base2")
    ap.add_argument("--current", default="zig-out/bin/zode")
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--wait", type=float, default=10.0)
    args = ap.parse_args()

    for label, key in (("no saved key", False), ("real saved key", True)):
        for name, binary in (("base", args.base), ("current", args.current)):
            verdicts = []
            for i in range(args.n):
                sb = f"/tmp/opencode/zode-ab-{name}-{i}"
                _, after, verdict = run(binary, sb, key, args.wait)
                verdicts.append(verdict)
            tally = {v: verdicts.count(v) for v in set(verdicts)}
            print(f"  {label:16} {name:8}: {tally}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
