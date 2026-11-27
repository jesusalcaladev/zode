#!/usr/bin/env python3
"""Guard for 42.8: no source file may import agent/tui/commands by path.

Those three modules talk through the `@import("app")` self-import registered on
each root module in build.zig. A direct `@import("agent.zig")` (or a relative
`../agent.zig`) would recreate the cycle and the duplicate-module-ownership
error. This gate is cheap, runs no compiler, and fails loudly on regression.

Usage: python3 tools/cycle_check.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(r'@import\("(?:\.\./)*((?:agent|tui|commands))\.zig"\)')


def main() -> int:
    hits = []
    export_line = re.compile(r'^\s*pub const \w+ = @import\("(?:agent|tui|commands)\.zig"\);\s*$')
    for path in sorted((ROOT / "src").rglob("*.zig")):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("//"):
                continue
            # Root modules define the exports that `@import("app")` resolves
            # to; those relative imports are the bridge, not a cycle.
            if export_line.match(line):
                continue
            m = FORBIDDEN.search(line)
            if m:
                hits.append(f"{path.relative_to(ROOT)}:{lineno}: imports {m.group(1)}.zig directly")
    if hits:
        for hit in hits:
            print("FAIL", hit)
        print("cycle_check: direct imports found; use @import(\"app\").<name> instead")
        return 1
    print(f"cycle_check: clean ({len(list((ROOT / 'src').rglob('*.zig')))} source files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
