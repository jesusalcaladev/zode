#!/usr/bin/env python3
"""Where is the hung TUI actually blocked?

Two runs, one with a key on the active provider and one without, and for each:
what every thread is doing (`wchan` + state), and how much CPU it used. A
hang with 0 CPU and a thread in `futex` is a lock; one in `poll`/`read` is I/O;
a thread that has not been scheduled at all never got to the interesting part.

  python3 tools/blocked_probe.py [--bin PATH] [--wait SECONDS]
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
SYSCALL_NAMES = {
    "futex_do_wait": "a futex (a lock or a condvar)",
    "anon_pipe_read": "a pipe read",
    "hrtimer_nanosleep": "a timed sleep",
    "do_epoll_wait": "epoll",
    "sk_wait_data": "a socket read (the network)",
    "wait_woken": "a timed wait",
    "poll_schedule_timeout": "poll",
    "read": "read()",
    "sk_stream_wait_connect": "connecting a socket",
    "do_sigsuspend": "sigsuspend",
}


def cpu_of(pid: int) -> float:
    with open(f"/proc/{pid}/stat") as f:
        p = f.read().rsplit(")", 1)[1].split()
    return (int(p[11]) + int(p[12])) / os.sysconf("SC_CLK_TCK")


def threads(pid: int):
    out = []
    tdir = f"/proc/{pid}/task"
    for t in sorted(os.listdir(tdir), key=int):
        try:
            with open(f"{tdir}/{t}/stat") as f:
                st = f.read().rsplit(")", 1)[1].split()
            state = st[0]
            wchan = ""
            try:
                with open(f"{tdir}/{t}/wchan") as f:
                    wchan = f.read().strip()
            except OSError:
                pass
            out.append((t, state, wchan))
        except OSError:
            pass
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="zig-out/bin/zode")
    ap.add_argument("--wait", type=float, default=18.0)
    args = ap.parse_args()

    binary = os.path.abspath(args.bin)
    for label, key in (("no key", None), ("with key", "nope")):
        sandbox = f"/tmp/opencode/zode-blocked-{label.replace(' ', '-')}"
        shutil.rmtree(sandbox, ignore_errors=True)
        cfg = os.path.join(sandbox, ".config", "zode")
        os.makedirs(cfg, exist_ok=True)
        with open(os.path.join(cfg, "auth.json"), "wb") as f:
            f.write(b"{}")

        env = dict(os.environ)
        env["HOME"] = sandbox
        env["TERM"] = "xterm-256color"
        env["ZODE_RESUME"] = "0"
        if key:
            env["ZODE_API_KEY"] = key

        pid, fd = pty.fork()
        if pid == 0:
            os.execve(binary, [binary], env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

        def drain(sec):
            n = 0
            t0 = time.time()
            while time.time() - t0 < sec:
                r, _, _ = select.select([fd], [], [], 0.2)
                if not r:
                    continue
                try:
                    c = os.read(fd, 65536)
                except OSError:
                    return n
                if not c:
                    break
                n += len(c)
            return n

        boot = drain(args.wait)
        os.write(fd, b"hola\r")
        after = drain(args.wait)
        c0 = cpu_of(pid)
        time.sleep(5)
        c1 = cpu_of(pid)
        print(f"\n=== {label} === boot={boot} after={after} cpu={c1 - c0:.2f}s/5s")
        print(f"    {'thread':>8} {'state':>6}  blocked on")
        for t, state, wchan in threads(pid):
            what = SYSCALL_NAMES.get(wchan, wchan or "runnable")
            print(f"    {t:>8} {state:>6}  {what}")
        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except OSError:
            pass
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
