#!/usr/bin/env python3
"""Regression guard for the old 'ReleaseSmall + saved key stops answering' bug.

It used to be a real failure (a use-after-free in warmupWorker's defer order),
fixed in agent.zig. The comments in build.zig and copy_smoke.py still treated it
as open, and no smoke set a key, so the regression could come back unnoticed.
This script starts the normal ReleaseSmall binary with a fake key in its own HOME
and asserts the composer starts AND echoes typed text.

Usage: python3 tools/key_smoke.py
"""
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import termios
import time

BINARY = "./zig-out/bin/zode"
HOME = "/tmp/opencode/zode-key-smoke-home"


def main() -> int:
    if not os.path.exists(BINARY):
        print(f"{BINARY} does not exist: run `zig build` first")
        return 1
    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(HOME, exist_ok=True)
    env = dict(os.environ)
    env["HOME"] = HOME
    env["TERM"] = "xterm-kitty"
    env["ZODE_OPENCODE_KEY"] = "sk-fake-for-smoke"

    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(BINARY, [BINARY], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    out = bytearray()
    start = time.time()
    while time.time() - start < 8.0:
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
        # Do NOT require the cursor-show sequence: with NO_COLOR=1 (which the
        # build harness exports) vaxis may skip it because the cursor was never
        # hidden. The composer text is the stable signal.
        if b"Ask" in out:
            break
    # vaxis paints one grapheme at a time with cursor moves between them, so
    # plain text is NOT contiguous in the raw byte stream. Strip CSI before
    # looking for the composer and the echo.
    plain = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", bytes(out))
    ok = True
    if not (b"Ask" in plain and b"anything" in plain):
        print("FAIL: composer never appeared with a key set")
        ok = False
    else:
        os.write(fd, b"hello key test")
        time.sleep(0.5)
        os.write(fd, b"\r")
        time.sleep(1.0)
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                out += os.read(fd, 65536)
            except OSError:
                pass
        # Recompute AFTER the echo arrived: the earlier `plain` was built from
        # startup bytes only.
        plain = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", bytes(out))
        if b"hello key test" not in plain:
            print("FAIL: typed text was not echoed with a key set")
            ok = False
    os.write(fd, b"\x03")
    time.sleep(0.2)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    print("key smoke: OK" if ok else "key smoke: FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
