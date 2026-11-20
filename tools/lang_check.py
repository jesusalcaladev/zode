#!/usr/bin/env python3
"""Fail on user-visible Spanish text in source.

AGENTS.md requires every visible string, comment, test name and assertion to be
in English. An accent-only check is not enough: `no se pudo leer` has no accent
and still shipped in a debug print. This script looks for a small, deliberately
conservative list of Spanish phrases that are almost never part of an English
sentence or an identifier. Lines that are only a comment are skipped, because
the repo explains a few of these phrases in English when documenting the old
bug.

Usage: python3 tools/lang_check.py
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PHRASES = (
    "no se pudo",
    "no se puede",
    "no existe",
    "error al",
    "por favor",
    "favor de",
)
CODE = re.compile(r"\.(zig|py)$")


def main() -> int:
    bad = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or not CODE.search(path.name):
            continue
        if ".zig-cache" in path.parts or "zig-out" in path.parts or "zig-pkg" in path.parts:
            continue
        if path.name == "lang_check.py":  # the phrase list itself
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("#"):
                continue
            low = line.lower()
            if any(p in low for p in PHRASES):
                bad.append(f"{path.relative_to(ROOT)}:{number}: {stripped[:120]}")
    if bad:
        print("lang_check: user-visible Spanish found")
        for item in bad:
            print("  " + item)
        return 1
    print("lang_check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
