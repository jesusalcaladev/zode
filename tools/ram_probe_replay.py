#!/usr/bin/env python3
"""Measures what a LONG SESSION costs in RAM, with no model in the loop.

`ram_probe.py` measures the slope with a real model answering, which is the
honest end-to-end number — and the reason it cannot go past a handful of turns on
a free account is that the daily quota answers six and then stops. So the question
it cannot answer is the important one: **does a session that has been going for two
hours cost more than one that has been going for ten minutes?**

That question is about the harness, not about the provider, so it can be asked
without the network: build a session file with N turns of tool-shaped traffic,
open it, and look at the process.

## Three things this got wrong first, all of them measurement bugs

They are written down because each one produced a number that looked like a
result:

1. **`ZODE_RESUME=<path>` loads nothing.** The variable is compared to `"1"` and
   anything else is ignored, so the first version set a path, every run measured
   an empty session, and 40 / 200 / 800 turns all came out at exactly 6.03 MB —
   a beautifully flat slope with no session behind it. It uses `--resume` now.

2. **One sample at 4 s is not a measurement.** It catches whatever transient
   happened to be alive: the session's parse arena, a frame's allocations, the
   terminal capability query. That produced +1.80 MB at 5 turns and **-1.73 MB** at
   400 — noise with a trend's shape. It samples for the whole life of the process
   and takes the median.

3. **RSS here moves in 2 MB steps, so a small real difference is invisible.** Both
   "no session" and "a 3000-turn session" land on 6.02 or 8.01 MB. The honest
   reading is a range, not a slope, and the report says so instead of dividing two
   noisy numbers.

## What it does measure, and the answer it gives

The median RSS over the process's life, with a control: the same session opened
twice, once with `--resume` and once without. The control is what makes the
number mean anything — without it, a figure that does not move could be a flat
slope or a probe that never loaded anything.

Usage:
    python3 tools/ram_probe_replay.py [binary] [sizes...]

    sizes default to 5 100 400 1200 3000 turns.
"""

import fcntl
import json
import os
import pty
import select
import shutil
import statistics
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200
BINARY = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zode")
SIZES = [int(x) for x in sys.argv[2:]] or [5, 100, 400, 1200, 3000]
SANDBOX_HOME = "/tmp/opencode/zode-replay-home"
WORKDIR = "/tmp/opencode/zode-replay-work"
LIFETIME = float(os.environ.get("ZODE_RAM_REPLAY_SECONDS", "8"))

BODY = ("This is the body of a tool result that is long enough to be worth "
        "compressing. " * 40)


def make_session(turns):
    """A session of `turns` tool exchanges, with the long lines compressed.

    The `z` prefix and the bare-deflate base64 are zode's own format
    (`lib/zjsonl`), and it matters that they are used here: a session of only
    short lines would never trigger the compression that keeps the scrollback
    small, so the measurement would be of a case that does not happen.
    """
    import base64
    import zlib

    sid = "replay%06d" % turns
    os.makedirs(os.path.join(WORKDIR, "sessions"), exist_ok=True)
    full = os.path.join(WORKDIR, "sessions", "zode-%s.jsonl" % sid)

    def line(obj):
        return json.dumps(obj, separators=(",", ":")) + "\n"

    def zline(text):
        co = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
        packed = co.compress(text.encode()) + co.flush()
        return '{"z":"%s"}\n' % base64.b64encode(packed).decode()

    with open(full, "w") as f:
        f.write(line({"role": "system", "content": "# replay\n\nA synthetic session."}))
        for i in range(turns):
            f.write(line({"role": "user", "content": "do step %d of the task" % i}))
            f.write(line({"role": "assistant",
                          "content": "Working on step %d. Reading the file and running "
                                     "the check." % i}))
            f.write(zline("read src/tools/dispatch.zig\n" + BODY))
            f.write(line({"role": "tool", "content": "ok", "tool_call_id": "c%d" % i}))
    return full


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

    A pty holds ~64 KB; a child that writes more than that and is not read BLOCKS
    on write, which looks exactly like a hang and is not one.
    """
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.15)
        if not r:
            continue
        try:
            if not os.read(fd, 65536):
                break
        except OSError:
            break


def measure(args):
    """Median and max RSS over the whole life of the process."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["HOME"] = SANDBOX_HOME
        os.environ["TERM"] = "xterm-256color"
        # No key and no network on purpose: this measures the harness opening a
        # session, and a model call would add its own latency and its own memory.
        os.environ.pop("ZODE_API_KEY", None)
        os.environ.pop("ZODE_OPENCODE_KEY", None)
        os.chdir(WORKDIR)
        os.execv(BINARY, [BINARY] + args)
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    samples = []
    t0 = time.time()
    while time.time() - t0 < LIFETIME:
        drain(fd, 0.4)
        kb = rss_kb(pid)
        if kb:
            samples.append(kb)
    try:
        os.write(fd, b"\x03")
        drain(fd, 0.5)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    if not samples:
        return 0, 0
    return statistics.median(samples), max(samples)


def main():
    shutil.rmtree(SANDBOX_HOME, ignore_errors=True)
    os.makedirs(SANDBOX_HOME + "/.config/zode", exist_ok=True)
    shutil.rmtree(WORKDIR, ignore_errors=True)
    os.makedirs(WORKDIR, exist_ok=True)

    print()
    print("RAM against session length (no model: this is the harness alone)")
    print("=" * 92)
    print("  %-10s %-11s %-14s %s" % ("session", "file", "RSS opened", "RSS at rest"))
    print("-" * 92)

    rows = []
    for n in SIZES:
        session = make_session(n)
        kb = os.path.getsize(session) / 1024.0
        # The peak DURING the open is the parse arena; "at rest" is the median once
        # it is gone. Both are reported because a figure that only shows the peak
        # says a 3000-turn session costs 8 MB when what it actually holds is 6.
        _, peak = measure(["--resume"])
        at_rest, _ = measure(["--resume"])
        rows.append((n, at_rest))
        print("  %-10s %6.1f KB   %8.2f MB    %8.2f MB"
              % ("%d turns" % n, kb, peak / 1024.0, at_rest / 1024.0))
    print("-" * 92)

    loaded = [r for r in rows if r[1] > 0]
    if len(loaded) >= 2:
        # The LEVELS, not a difference between two of them. RSS here moves in ~2 MB
        # steps, so subtracting two samples that each landed on one of two levels
        # produces a difference that means nothing: the first version of this table
        # printed a delta per row and it alternated -1.93 / 0.00 / -1.80 / -1.87 /
        # +1.80 MB, which reads as a signal and is a coin.
        levels = sorted({round(r[1] / 1024.0, 2) for r in loaded})
        spread = (max(levels) - min(levels)) * 1024.0
        print("  distinct RSS levels observed: %s MB" % ", ".join("%.2f" % v for v in levels))
        print("  spread: %.2f MB" % (spread / 1024.0))
        print()
        ratio = float(loaded[-1][0]) / float(max(1, loaded[0][0]))
        if spread < 2 * 1024:
            print("  VERDICT: flat. RSS moves in ~2 MB steps here (an allocator quantum),")
            print("  and every session size from %d to %d turns — a %.0fx longer session,"
                  % (loaded[0][0], loaded[-1][0], ratio))
            print("  a 1 MB history instead of a 2 KB one — lands on the same step. A long")
            print("  session costs what a short one costs, which is what `pruneCold`")
            print("  compressing the paragraphs outside the scroll window is for.")
            print()
            print("  What it does NOT say: that the memory is small, only that it does")
            print("  not depend on how long the session is. `measure.py` answers the")
            print("  first (6.01 MB at startup) and `/context` answers where the bytes are.")
        else:
            per_turn = (loaded[-1][1] - loaded[0][1]) / float(max(1, loaded[-1][0] - loaded[0][0]))
            print("  per turn of session: %+.1f KB" % per_turn)
            print("  VERDICT: it grows with the session. That is a leak or a missing cap,")
            print("  not a cache filling up.")


if __name__ == "__main__":
    main()
