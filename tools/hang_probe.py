#!/usr/bin/env python3
"""Does the TUI hang at startup, and does it correlate with auth.json?

Runs the same boot N times with and without a saved key and prints, for each:
the bytes the app produced while booting, and the bytes it produced after an
Enter. `after == 0` is the hang the user reported: the banner is on screen and
then no key does anything.

  python3 tools/hang_probe.py [--n N] [--bin PATH]
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


def run_once(binary: str, sandbox: str, auth: bool, wait: float) -> tuple[int, int]:
    cfg = os.path.join(sandbox, ".config", "zode")
    os.makedirs(cfg, exist_ok=True)
    dst = os.path.join(cfg, "auth.json")
    if os.path.exists(dst):
        os.remove(dst)
    if auth:
        real = os.path.expanduser("~/.config/zode/auth.json")
        if os.path.exists(real):
            shutil.copyfile(real, dst)
            os.chmod(dst, 0o600)

    env = dict(os.environ)
    env["HOME"] = sandbox
    env["TERM"] = "xterm-256color"
    env["ZODE_RESUME"] = "0"

    pid, fd = pty.fork()
    if pid == 0:
        os.execve(binary, [binary], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def drain(sec: float) -> int:
        n = 0
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
            n += len(c)
        return n

    boot = drain(wait)
    os.write(fd, b"hola\r")
    after = drain(wait)
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except OSError:
        pass
    os.close(fd)
    return boot, after


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--bin", default="zig-out/bin/zode-debug")
    ap.add_argument("--wait", type=float, default=14.0)
    ap.add_argument("--no-network", action="store_true",
                    help="point ZODE_MODELS_URL at a closed port so the network cannot be the cause")
    ap.add_argument("--env-key", default="",
                    help="also export ZODE_API_KEY, to separate 'a key exists' from 'auth.json exists'")
    args = ap.parse_args()

    binary = os.path.abspath(args.bin)
    tag = "nonet" if args.no_network else "neta "
    if args.env_key:
        tag += "+key"
    for auth in (False, True):
        for i in range(args.n):
            sandbox = f"/tmp/opencode/zode-hang-{'a' if auth else 'n'}-{i}"
            shutil.rmtree(sandbox, ignore_errors=True)
            boot, after = run_once(binary, sandbox, auth, args.wait)
            verdict = "HUNG" if after == 0 else "alive"
            print(f"{tag} auth={'yes' if auth else 'no '} run {i}: boot={boot:6} after={after:6}  {verdict}")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
