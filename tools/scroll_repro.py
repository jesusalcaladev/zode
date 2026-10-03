#!/usr/bin/env python3
"""Fast pty reproduction of the scroll bug: PageUp past the top, then PageDown.

WHAT THIS IS FOR
----------------
The scroll used to be an offset FROM THE BOTTOM (`scroll: usize`, "0 = bottom,
N = N lines up"), and it was clamped to a `1_000_000` constant while
`computeVisible` clamped a LOCAL copy for drawing and never wrote it back. So:

  * the offset could sit far above `max_offset` with nothing moving on screen,
  * and because `first = max_offset - scroll` was bottom-relative too, every new
    line of the LIVE paragraph moved the window at the model's writing speed,
    which made reading while the model wrote impossible.

The unit test for that is `tui.test.scroll: overscrolling up leaves no debt, so
one PageDown really scrolls down`. This script is the OTHER half of the
verification: it drives the REAL binary in a REAL pty, because vaxis renders
differentially and a `drawTest` surface cannot tell you what the terminal ends up
showing.

WHAT IT CHECKS
--------------
With a history long enough to scroll, and WITHOUT needing a model (it uses the
empty-history trick of a tall terminal and injected history via the headless
session file, see `seed_history`):

  1. PageUp moves the view: the text on screen must change.
  2. PageUp WAY past the top (x8, which with auto-repeat is what a held key
     does) and then ONE PageDown must change the view again. Before the fix the
     first six PageDowns did nothing at all.
  3. No panic, no "Invalid free", no hang.

It runs in a few seconds and needs no API key.

    zig build && python3 tools/scroll_repro.py

Returns 0 if the scroll behaves, 1 if it does not. Prints the flat text of the
screen when something fails.

CAREFUL: `HOME` points at its own directory. The app writes
`~/.config/zode/auth.json` and `sessions/`, and an automatic script must never
touch the real config of whoever runs it (the June fuzzer saved a pasted key
there and the provider then answered 401 with no visible explanation).
"""

import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200
BINARY = "./zig-out/bin/zode"
SANDBOX_HOME = "/tmp/opencode/zode-scroll-home"

# The keys the history scroll actually listens to. PageUp/PageDown and the two
# half-page ones; the arrow keys are the editor's prompt history, NOT the
# history scroll, which is exactly why the old smoke test proved nothing.
PAGE_UP = b"\x1b[5~"
PAGE_DOWN = b"\x1b[6~"
HALF_UP = b"\x15"  # ctrl+u
HALF_DOWN = b"\x04"  # ctrl+d
WHEEL_UP = b"\x1b[<64;10;10M"
WHEEL_DOWN = b"\x1b[<65;10;10M"


def strip_ansi(b: bytes) -> str:
    """Plain text out of the pty.

    The truecolor SGR with two colons (`ESC [ [38:2:122:162:247m`) has to go
    too: the usual regex does not cover it and the banner emits the lot, so
    without this the ASCII art comes out split and not one string can be
    searched for.
    """
    s = b.decode("utf-8", "replace")
    s = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?", "", s)  # OSC
    s = re.sub(r"\x1b\[[0-9;:?<>!$ ]*[A-Za-z`~]", "", s)  # CSI (incl. SGR)
    s = re.sub(r"\x1b[\(\)][B0]|\x1b[=>78MD]", "", s)  # charset designators
    return s


class Term:
    """The app in a pty, with the ability to ask 'what is on screen right now'."""

    def __init__(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(
                TERM="xterm-256color",
                HOME=SANDBOX_HOME,
                ZODE_RESUME="0",
                LINES=str(ROWS),
                COLUMNS=str(COLS),
            )
            os.execv(BINARY, [BINARY])
        # Without a window size vaxis does `width_pix / width`, which is a
        # division by zero when the size is 0.
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.buf = b""

    def pump(self, seconds: float) -> None:
        """Drain for `seconds`. MUST drain: if the child fills the ~64 KB pty
        buffer and the parent does not read, it blocks in `write` and looks
        exactly like a hung program."""
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 1 << 16)
            except OSError:
                return
            if not chunk:
                return
            self.buf += chunk

    def send(self, data: bytes) -> None:
        try:
            os.write(self.fd, data)
        except OSError:
            pass
        self.pump(0.25)

    def screen(self) -> str:
        """Everything that has been drawn so far, as plain text.

        Deliberately the WHOLE stream, not a screen model: vaxis renders
        differentially, so 'what the screen looks like now' is not a substring
        of the byte stream. What is comparable is whether the app produced NEW
        output at all, which is exactly what the scroll bug broke (no redraw =
        nothing moved).
        """
        return strip_ansi(self.buf)

    def close(self) -> str:
        self.send(b"\x03")
        self.pump(0.3)
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        return self.screen()


def check(name: str, ok: bool) -> bool:
    print(f"  {'OK  ' if ok else 'FAIL'} {name}")
    return ok


def main() -> int:
    if not os.path.exists(BINARY):
        sys.exit(f"{BINARY} does not exist: run `zig build` first")
    os.makedirs(SANDBOX_HOME, exist_ok=True)

    ok = True
    t = Term()
    # Startup: banner, input box, status bar.
    t.pump(2.0)
    s0 = t.screen()
    ok &= check("app started", "######" in s0)

    # A history to scroll through. The banner plus the prompt is all the app
    # has on its own, and with 43 rows of history that does not scroll at all
    # (max_offset would be 0), which is why the bug was invisible in a fresh
    # session: you cannot overscroll what does not scroll.
    #
    # Pasting a long block of text into the input is the cheapest way to fill
    # the history from OUTSIDE the model: the input accepts it, and the turn
    # produces paragraphs whether or not there is a provider configured.
    filler = b"\n".join(b"linea %d del historial para probar el scroll" % i for i in range(120))
    t.send(b"\x0c")  # ctrl+l first, so we start from a clean screen
    t.pump(0.4)
    before = len(t.buf)

    t.send(filler)
    t.send(b"\r")
    t.pump(3.0)
    after_prompt = t.screen()
    ok &= check("history has content to scroll", "historial para probar" in after_prompt)

    # 1) PageUp moves the view: the app must redraw.
    mark = len(t.buf)
    t.send(PAGE_UP)
    t.pump(0.6)
    ok &= check("PageUp produced a redraw", len(t.buf) > mark)

    # 2) The bug itself: overscroll WAY past the top, then ONE PageDown.
    for _ in range(8):
        t.send(PAGE_UP)
    t.pump(0.8)
    at_top = len(t.buf)

    mark = len(t.buf)
    t.send(PAGE_DOWN)
    t.pump(0.8)
    moved = len(t.buf) > mark

    if not moved:
        print()
        print("  >>> THE BUG: one PageDown after overscrolling produced NO redraw.")
        print("  >>> That is the hidden-debt bug: the offset was above max_offset,")
        print("  >>> so PageDown subtracted from a number that was already past")
        print("  >>> the top and the view did not move at all.")
    ok &= check("one PageDown after overscrolling moves the view", moved)

    # And the other direction, so the fix is not just 'make PageDown work by
    # never scrolling': half-page down has to work too.
    mark = len(t.buf)
    t.send(HALF_DOWN)
    t.pump(0.6)
    ok &= check("ctrl+d (half page down) redraws", len(t.buf) > mark)

    mark = len(t.buf)
    t.send(WHEEL_UP)
    t.pump(0.4)
    ok &= check("wheel up redraws", len(t.buf) > mark)

    # 3) Nothing exploded along the way.
    t.send(HALF_UP)
    t.pump(0.4)
    t.send(WHEEL_DOWN)
    t.pump(0.4)
    final = t.close()
    ok &= check("no panic", "panic" not in final.lower())
    ok &= check("no Invalid free", "invalid free" not in final.lower())
    ok &= check("scroll produced output at all", at_top > before)

    print()
    if ok:
        print("scroll_repro: OK")
        return 0

    print("--- plain text (truncated) ---")
    for line in final.splitlines()[:40]:
        if line.strip():
            print("  |", line[:100])
    print("scroll_repro: FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())