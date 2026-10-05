#!/usr/bin/env python3
"""Measures RSS and startup time of the TUI in a real pty.

Usage: python3 tools/measure.py [binary] [seconds]

Starts the TUI, reads VmRSS from /proc every 200 ms, and reports:
  - time to the first non-empty output (startup)
  - peak and steady RSS (median of the second half)

What it does NOT answer, and this is the number people quote by mistake: whether
the memory GROWS. A harness that is 6 MB on an empty screen and 200 MB after two
hours is not a 6 MB harness. `ram_probe.py` measures the slope with a real model
answering, and `ram_probe_replay.py` measures it against session length without
one.

It was written in Spanish and the repo's language check missed it, because that
check looks for accented characters and this file had none. A check that only
catches accents is a check that catches one mistake.
"""

import fcntl
import os
import pty
import re
import select
import statistics
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200
BINARY = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zode"
HOLD = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
SANDBOX_HOME = "/tmp/opencode/zode-measure-home"


def main():
    os.makedirs(SANDBOX_HOME, exist_ok=True)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["HOME"] = SANDBOX_HOME
        os.environ["TERM"] = "xterm-256color"
        # No network key: startup must not touch the API.
        os.environ.pop("ZODE_API_KEY", None)
        os.environ.pop("ZODE_OPENCODE_KEY", None)
        os.execv(BINARY, [BINARY])
        os._exit(127)

    # TIOCSWINSZ FIRST, or vaxis does `width_pix / width` and divides by zero.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    rss_samples = []
    t0 = time.time()
    first_output = None

    while time.time() - t0 < HOLD:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            if first_output is None and chunk.strip():
                first_output = time.time() - t0
        try:
            with open("/proc/%d/status" % pid) as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        rss_samples.append(int(line.split()[1]))
                        break
        except OSError:
            break

    try:
        os.write(fd, b"\x03")
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

    steady = statistics.median(rss_samples[len(rss_samples) // 2:]) if rss_samples else 0
    print()
    print("binary:            %s" % BINARY)
    print("first output:      %s s" % ("%.6f" % first_output if first_output else "never"))
    print("peak RSS:          %.2f MB" % ((max(rss_samples) / 1024.0) if rss_samples else 0))
    print("steady RSS:        %.2f MB" % (steady / 1024.0))
    print("min RSS:           %.2f MB" % ((min(rss_samples) / 1024.0) if rss_samples else 0))
    print("samples:           %d" % len(rss_samples))
    print()
    print("This is the startup number. For whether it GROWS, run:")
    print("  python3 tools/ram_probe.py          # slope, with the real model")
    print("  python3 tools/ram_probe_replay.py   # against session length, no model")


if __name__ == "__main__":
    main()
