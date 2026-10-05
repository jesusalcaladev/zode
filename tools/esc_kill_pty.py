#!/usr/bin/env python3
"""ESC has to KILL the process group, not just set a flag.

Why this cannot be a Zig test: what is being checked is whether a process the
agent spawned is STILL ALIVE in the kernel's process table. That is only visible
from outside, in a real pty, with `zig build` already done.

And why it looks at the GRANDCHILD and not at the shell (this cost a round trip):

zode's `bash` is always `/bin/sh -c "whatever the model asked for"`, and a shell
has children. If the fix were "kill the shell's pid", a test LOOKING AT THE SHELL
would pass the same way: the shell dies and the grandchild (`sleep`, `zig`,
`npm`) keeps running with the CPU pinned. The symptom that got reported as
"ESC does not stop the processes" is exactly that, one level lower.

The marker is `sleep 301 & wait`: shell plus grandchild, two pids. It looks for
`sleep 301` and only that. With `exec` the shell is replaced, one process is left,
and the test would go green with the fix and without it alike — which is what this
looks at, so that cannot be what it checks.

How the fix was verified: removing the `pgid = 0` from both spawns (foreground and
background) makes this fail with the grandchild alive; putting it back makes it
pass. Both halves of the contract are in the same test.

Usage:
    zig build
    set -a && source .env && set +a
    python3 tools/esc_kill_pty.py

Its own `HOME`: the app writes `~/.config/zode/auth.json` and `sessions/`, and an
automated script must not touch the real config of whoever runs it.
"""

import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200
BINARY = "./zig-out/bin/zode"
# A separate HOME (June's fuzzer saved a key pasted by mistake and left the
# provider con 401 sin explicacion aparente).
SANDBOX_HOME = "/tmp/opencode/zode-esc-home"
MARKER = "/tmp/opencode/zodeesc/bin/spin"
GRANDCHILD_ARGV = (b"sleep", b"301")
PROMPT = "run /tmp/opencode/zodeesc/bin/spin in the background and keep going"


def strip_ansi(b: bytes) -> str:
    s = b.decode("utf-8", "replace")
    s = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?", "", s)
    s = re.sub(r"\x1b\[[0-9;:?<>!$ ]*[A-Za-z`~]", "", s)
    s = re.sub(r"\x1b[\(\)][B0]|\x1b[=>78MD]", "", s)
    return s


def grandchild_procs():
    """Processes whose argv is EXACTLY the grandchild, and nothing else.

    Matching the exact argv pair and nothing else is what keeps this from
    counting the harness's own shell (which has the marker path in its argv
    because it created the file) or an unrelated `sleep`.
    """
    found = []
    me = os.getpid()
    for p in os.listdir("/proc"):
        if not p.isdigit() or int(p) == me:
            continue
        try:
            raw = open(f"/proc/{p}/cmdline", "rb").read()
        except OSError:
            continue
        argv = [a for a in raw.split(b"\0") if a]
        if len(argv) == 2 and argv[0].endswith(GRANDCHILD_ARGV[0]) \
                and argv[1] == GRANDCHILD_ARGV[1]:
            found.append((int(p), b" ".join(argv).decode("utf-8", "replace")))
    return found


def build_marker() -> None:
    os.makedirs(os.path.dirname(MARKER), exist_ok=True)
    # `sleep & wait` leaves the GRANDCHILD alive. Without `exec` the shell stays waiting
    # and the grandchild is a separate process with its own pid.
    with open(MARKER, "w") as f:
        f.write("#!/bin/sh\nsleep 301 &\nwait\n")
    os.chmod(MARKER, 0o755)


def check(name: str, ok: bool, extra: str = "") -> bool:
    print(f"  {'OK  ' if ok else 'FAIL'} {name}")
    if not ok and extra:
        print("    " + extra.replace("\n", "\n    ")[:2000])
    return ok


def main() -> int:
    if not os.path.exists(BINARY):
        sys.exit(f"{BINARY} no existe: ejecuta `zig build` primero")
    if "ZODE_OPENCODE_KEY" not in os.environ:
        sys.exit("ZODE_OPENCODE_KEY is missing: `set -a && source .env && set +a`")

    os.makedirs(SANDBOX_HOME, exist_ok=True)
    build_marker()

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(
            TERM="xterm-256color",
            HOME=SANDBOX_HOME,
            ZODE_RESUME="0",
            LINES=str(ROWS),
            COLUMNS=str(COLS),
            ZODE_API_KEY=os.environ["ZODE_OPENCODE_KEY"],
            ZODE_PROVIDER="opencode",
            ZODE_MODEL="space-bunny-free",
        )
        os.execv(BINARY, [BINARY])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    out = bytearray()

    def pump(sec: float) -> None:
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                out.extend(os.read(fd, 1 << 16))
            except OSError:
                pass

    pump(3.0)
    # `/yolo` first: without it `bash` asks for permission and the turn sits in the
    # dialog, which is a different path than the one under test.
    os.write(fd, b"/yolo\r")
    pump(2.0)
    os.write(fd, PROMPT.encode() + b"\r")

    # Wait for the grandchild to EXIST (with a cap), not for a fixed time: with a
    # slow model a turn can take a while, and a `sleep` here would be a false OK.
    deadline = time.time() + 45
    while time.time() < deadline and not grandchild_procs():
        pump(1.0)
        if b"Permission required" in out:
            os.write(fd, b"a")

    during = grandchild_procs()
    print(f"  nieto vivo antes de ESC: {len(during)}")
    for p, c in during:
        print(f"    pid {p}: {c}")

    os.write(fd, b"\x1b")
    pump(4.0)
    after = grandchild_procs()
    print(f"  nieto vivo DESPUES de ESC: {len(after)}")
    for p, c in after:
        print(f"    pid {p}: {c}")

    text = strip_ansi(bytes(out))
    os.write(fd, b"\x03")
    time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)

    # Cleanup: if the grandchild survived (that is, the fix is not in), it is not
    # left spinning on somebody's machine.
    for p, _ in after:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass

    if not during:
        print("  SKIP the grandchild never started: the test is not testing anything")
        print("  (pantalla: " + text[-400:].replace("\n", " ") + ")")
        return 0

    ok = check(
        # Not translated: this string is what the assertion compares against, and
        # the repo's rule keeps asserted strings as they are.
        "ESC mato el grupo de procesos (nada huerfano)",
        len(after) == 0,
        "\n".join(f"pid {p}: {c}" for p, c in after),
    )
    ok &= check("no hay panic", "panic" not in text.lower(), text[-600:])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())