#!/usr/bin/env python3
"""Release-candidate gate for zode v3: run every quality gate IN ORDER.

The build graph can run independent steps in parallel, which is fine for
compilation but wrong for the pty/headless smokes: several of them bind port
11434 or contend for the terminal. This driver serializes them and stops at
the first red gate, so a single `zig build rc-check` is enough to say whether
v3 is RC-clean.

Usage: python3 tools/rc_check.py
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

GATES = [
    ("unit tests", ["zig", "build", "test"]),
    ("release build", ["zig", "build"]),
    ("ui-frame", ["zig", "build", "ui-frame"]),
    ("pty smokes", ["zig", "build", "pty-check"]),
    ("headless smokes (hooks/background/permissions)", ["zig", "build", "hooks-check"]),
    ("remote smoke", ["zig", "build", "remote-check"]),
    ("import seam", ["zig", "build", "cycle-check"]),
    ("memory auditor", ["zig", "build", "memaudit"]),
    ("language rule", ["python3", "tools/lang_check.py"]),
    ("internal ASCII", ["python3", "tools/ascii_check.py"]),
    ("Windows cross-build", ["zig", "build", "-Dtarget=x86_64-windows-gnu"]),
]


def main() -> int:
    for name, cmd in GATES:
        print(f"== {name}", flush=True)
        res = subprocess.run(cmd, cwd=str(ROOT))
        if res.returncode != 0:
            print(f"rc-check: FAIL at {name} (exit {res.returncode})")
            return 1
    print("rc-check: ALL GREEN — v3 is RC-clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
