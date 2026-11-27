#!/usr/bin/env python3
"""Guard the startup banner's internal ASCII (AGENTS.md invariant).

The banner is a DRAWING, not prose: five rows of printable ASCII, no box
drawing, no control bytes, no language text. Verify the four glyph tables and
the assembled dimensions so a stray Unicode character or a stripped row is
caught by CI, not by a terminal full of replacement characters.

Usage: python3 tools/ascii_check.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "tui.zig"


def main() -> int:
    text = SRC.read_text()
    bad = []
    for name in ("glyph_z", "glyph_o", "glyph_d", "glyph_e"):
        m = re.search(rf"(?:pub )?const {name} = \[_\]\[\]const u8\{{(.*?)\n\}};", text, re.S)
        if not m:
            bad.append(f"{name} not found")
            continue
        rows = re.findall(r'"([^"\\]*)"', m.group(1))
        if len(rows) != 5:
            bad.append(f"{name} has {len(rows)} rows, expected 5")
        for i, row in enumerate(rows):
            for ch in row:
                if not 0x20 <= ord(ch) <= 0x7e:
                    bad.append(f"{name} row {i}: U+{ord(ch):04X}")
    if "pub const banner_art_height = 5;" not in text:
        bad.append("banner height is not 5")
    if "pub const banner_art_width = 4 * 6 + 3;" not in text:
        bad.append("banner width is not 27")
    if bad:
        for item in bad:
            print("FAIL", item)
        return 1
    print("ascii_check: clean (4 glyphs x 5 rows, 27x5 ASCII banner)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
