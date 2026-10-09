#!/usr/bin/env python3
"""Smoke test of the TUI in a REAL pty.

Why a pty and not the `drawTest` tests: vaxis rendering is DIFFERENTIAL and it
 queries the terminal (color, size, capabilities). A homemade emulator loses half
 the redraw, which is exactly what makes a working turn look frozen. And
 `pty.fork` + `TIOCSWINSZ` is the only way to give the app a real window size.

Usage:
    zig build                       # or `zig build -Doptimize=ReleaseSafe`
    python3 tools/pty_smoke.py

Returns 0 if everything checked holds, 1 if something fails. It prints the flat
dump on failure so you can look at what is on screen.

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
import shutil
import subprocess
import termios
import time
import time

ROWS, COLS = 50, 200
BINARY = "./zig-out/bin/zode"
# A separate HOME: `auth.json` and `sessions/` belong to the person, not to the smoke.
SANDBOX_HOME = "/tmp/opencode/zode-smoke-home"


def strip_ansi(b: bytes) -> str:
    """Plain text of what came out of the pty.

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


def drive(keys, budget: float = 8.0):
    """Starts the TUI, sends `keys` spaced out, and returns (bytes, text)."""
    if not os.path.exists(BINARY):
        sys.exit(f"{BINARY} does not exist: run `zig build` first")

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(
            TERM="xterm-256color",
            HOME=SANDBOX_HOME,
            ZODE_RESUME="0",
            LINES=str(ROWS),
            COLUMNS=str(COLS),
        )
        os.execv(BINARY, [BINARY])

    # Without this the child has no window and vaxis does `width_pix / width`,
    # which with size 0 is a division by zero.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    out = b""
    t0 = time.time()
    slots = len(keys) + 1
    for i, key in enumerate([None] + list(keys)):
        due = t0 + (i + 1) * (budget / slots)
        while time.time() < due:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(fd, 1 << 16)
            except OSError:
                chunk = b""
            if not chunk:
                break
            out += chunk
        if key is None:
            continue
        try:
            os.write(fd, key)
        except OSError:
            break

    # The LAST key is always sent at the very end of the budget, so its
    # response lands AFTER the last read: for every "type + Enter" case the
    # window closed before the answer existed. Measured: the response arrives
    # ~10 ms after the Enter, and the /clean checks were passing on the
    # autocomplete hint instead (the desc literally contains "dry run" and
    # "/clean yes"), i.e. they did not need the command to answer at all.
    # This drain is what makes "<cmd> answers" check the ANSWER.
    deadline = time.time() + 1.5
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError:
            chunk = b""
        if not chunk:
            break
        out += chunk

    os.write(fd, b"\x03")  # ctrl+c: the prompt's own exit path
    time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)
    return out, strip_ansi(out)


def check(name: str, ok: bool, text: str) -> bool:
    print(f"  {'OK  ' if ok else 'FAIL'} {name}")
    return ok


def copy_key_into_sandbox() -> str:
    """Puts the saved provider key in the sandbox HOME, if there is one.

    The rule this follows is the one every pty script here follows: an automated
    script must not touch the real config of whoever runs it, so the file is COPIED
    into `/tmp` and never written to. The copy is what makes the model-dependent
    checks able to run at all — without it a `bash` the model was asked to start
    never starts, and the check for "ctrl+c orphans nothing" has nothing to look at
    and skips every time.

    `ram_probe.py` has always done this. `pty_smoke.py` did not, which is why it
    could not test anything that needs the model.
    """
    real = os.path.expanduser("~/.config/zode/auth.json")
    if not os.path.exists(real):
        return ""
    dst_dir = os.path.join(SANDBOX_HOME, ".config", "zode")
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, "auth.json")
    shutil.copyfile(real, dst)
    os.chmod(dst, 0o600)
    return "auth.json copied into the sandbox"


def main() -> int:
    os.makedirs(SANDBOX_HOME, exist_ok=True)
    note = copy_key_into_sandbox()
    if note:
        print(f"smoke: {note}")

    # 1) Startup: banner, input box, status bar, and nothing falls over.
    out, t = drive([b"hola mundo", b"\r"])
    ok = True
    print(f"smoke: {len(out)} bytes through the pty")
    ok &= check("banner: first row of the wordmark", "######  ####  ####   ######" in t, t)
    ok &= check("banner: third row", "   ##  ##  ## ##   # ###" in t, t)
    ok &= check("input box (╭ ╰ borders)", "╭" in t and "╰" in t, t)
    ok &= check("status bar", "esc interrupts" in t, t)
    ok &= check("the user prompt echoes", "hola mundo" in t, t)
    ok &= check("no panic", "panic" not in t.lower(), t)
    ok &= check("no 'Invalid free'", "invalid free" not in t.lower(), t)

    # 2) Ctrl+P: the modal palette has to open AND close. This is the path that
    #    broke most often (dangling items, double free of the allocator).
    out2, t2 = drive([b"\x10", b"esc"])
    ok &= check("ctrl+p opens the palette", "Switch model" in t2 or "Connect" in t2, t2)
    ok &= check("esc closes the palette", "Switch model" not in t2, t2)

    # 3) Ctrl+L (clear) and the REAL scroll keys: they must not take the app
    #    down.
    #
    #    This used to send `\x1b[B` twice and call it "scroll". That is the DOWN
    #    ARROW, which the input editor consumes as "walk the prompt history" —
    #    it never reaches the history scroll at all. So the whole scroll path was
    #    untested here, which is how the scroll bug (page up past the top, then
    #    nothing moved on page down) shipped with a green smoke test.
    #
    #    The keys that scroll the history: Up/Down when the input is empty,
    #    Home/End for oldest/latest, PageUp `\x1b[5~`, PageDown `\x1b[6~`,
    #    Ctrl+U `\x15` (half a page up), Ctrl+D `\x04` (half a page down) and
    #    the wheel (`\x1b[<64;…M` / `\x1b[<65;…M`).
    out3, t3 = drive(
        [
            b"hola",
            b"\r",
            b"\x0c",
            b"\x1b[A",
            b"\x1b[B",
            b"\x1b[H",
            b"\x1b[F",
            b"\x1b[5~",
            b"\x1b[5~",
            b"\x1b[6~",
            b"\x15",
            b"\x04",
        ]
    )
    ok &= check("arrows, Home/End and page keys scroll without breaking", "panic" not in t3.lower(), t3)
    ok &= check("no 'Invalid free' after scrolling", "invalid free" not in t3.lower(), t3)

    # 4) `/clean`: a cleanup command that runs in the TUI without asking anything
    #    has to work ALWAYS, and without `yes` it must not delete. What is checked
    #    is the dry-run TEXT, not that something got deleted: the smoke HOME may
    #    hold no empty session at all, and a test that depends on there being junk
    #    to delete only ever verifies the happy path.
    out4, t4 = drive([b"/clean", b"\r"])
    # Both needles are RESPONSE-only: "dry run" and "/clean yes" also live in
    # the command's desc, which the autocomplete popup shows while the text is
    # being typed — the first version of these checks passed on the popup and
    # would have kept passing if /clean never answered. "…: dry run" is the
    # header only cmdClean prints, and the tail has one of three endings
    # (the junk may or may not exist in the sandbox).
    ok &= check("/clean answers (dry run)", "/clean: dry run" in t4, t4)
    ok &= check(
        "/clean offers the 'yes' (or says there is nothing)",
        "run /clean yes to delete" in t4 or "nothing to delete" in t4 or "nothing to clean" in t4,
        t4,
    )
    ok &= check("/clean does not break anything", "panic" not in t4.lower(), t4)

    # 5) `/context` says WHERE the work is happening. It is the line that answers
    #    "is it really reading the files from here?", and it appears nowhere else
    #    on screen.
    # TWO enters: the first is taken by the autocompletion (which is open because
    #    `/context` is a command prefix) and the second sends it. With only one the
    #    command stays in the input, and the test would then be passing or failing
    #    on the popup rather than on `/context`.
    out5, t5 = drive([b"/context", b"\r", b"\r"], budget=9.0)
    ok &= check("/context says the cwd", "cwd" in t5, t5)
    ok &= check("/context does not break anything", "panic" not in t5.lower(), t5)

    # 6) `/free-auto` has to be FINDABLE. It was the last item of the "Session"
    #    group among twenty others, with no alias and no state in its hint, and
    #    the report was "there is no command to rotate the free models". A
    #    feature that exists and cannot be found does not exist.
    out6, t6 = drive([b"\x10", b"free"])
    ok &= check("ctrl+p finds /free-auto by typing 'free'", "/free-auto" in t6, t6)
    out6b, t6b = drive([b"\x1b"])

    # 7) A prompt LONGER THAN THE BOX has to survive: wrapped, not truncated.
    #    The bug was that the box grew to eight rows while the text stayed in one
    #    and everything past the border was dropped without a word.
    #
    #    What the pty can check, and what it CANNOT, is worth writing down: the
    #    typed text itself is NOT assertable here. vaxis redraws DIFFERENTLY (it
    #    moves the cursor and patches cells), and this emulator concatenates the
    #    byte stream, so the last redraw wins only by luck: typing "a" then "b"
    #    three seconds apart comes out as "a" followed by a gap where "b" should
    #    be. Measured, not assumed. So this check is the app SURVIVING a long
    #    prompt and the START of it echoing back after Enter, and the wrap itself
    #    is pinned by the `drawTest` unit tests, which read the surface cell by
    #    cell.
    out7, t7 = drive(
        [
            b"esta es una pregunta muy larga para comprobar que el input "
            b"envuelve la linea y no se sale de la caja",
            b"\r",
        ],
        budget=14.0,
    )
    ok &= check("a long prompt is accepted and echoed", "pregunta muy larga" in t7, t7)
    ok &= check("a long prompt does not break anything", "panic" not in t7.lower(), t7)

    # 8) `!` shell mode: a command the user typed runs and its output lands in the
    #    context. It runs on its OWN thread, because `submitInput` is the event
    #    handler and a foreground command there freezes the app.
    out8, t8 = drive([b"!echo zode-shell-ok", b"\r"], budget=8.0)
    ok &= check("`!cmd` runs the command", "zode-shell-ok" in t8, t8)
    ok &= check("`!cmd` does not break anything", "panic" not in t8.lower(), t8)
    # And the input is free again afterwards: a `!` that leaves the text in the box
    # would make the next Enter re-run it.
    out8b, t8b = drive([b"hola", b"\x15"], budget=8.0)
    ok &= check("the input is usable after `!`", "panic" not in t8b.lower(), t8b)

    # 9) The user-command commands, TYPED. Both live in `submit`'s big if/else
    #    chain: the unit tests check the branches, and this checks that they
    #    are reachable from a keystroke and that their answer reaches the
    #    screen (the `/free-auto` lesson: a command can be perfectly
    #    unit-tested and still do nothing when typed).
    out9, t9 = drive(
        [b"/reload-cmds", b"\r", b"/which-cmd help", b"\r", b"/which-cmd zode-no-such", b"\r"],
        budget=15.0,
    )
    ok &= check("/reload-cmds answers with the count", "reloaded user commands:" in t9, t9)
    ok &= check("/which-cmd names a builtin as a builtin", "/help is a builtin" in t9, t9)
    ok &= check("/which-cmd says not found for a file that is not there", "not found: /zode-no-such" in t9, t9)
    ok &= check("the new commands do not break anything", "panic" not in t9.lower(), t9)

    if not ok:
        print("\n--- plain text (truncated) ---")
        for line in t.splitlines()[:40]:
            if line.strip():
                print("  |", line[:100])
    else:
        print("\nsmoke: OK")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())