---
id: no-painted-backgrounds-terminal-shows-through
title: "Surfaces and diffs inherit the terminal background; no painted row backgrounds"
tags: "theme, layout, diff, ui-convention"
evidence: "end-of-turn extractor; user approval required"
---

All surface styles (`panel_bg`, `well_bg`, `sel_bg`, `diff_add_bg`, `diff_del_bg`) are `.{}` (default), meaning the terminal background always shows through. Diffs rely on foreground color, bold markers, and gutters rather than painted row backgrounds — only `diff_add_line_bg`/`diff_del_line_bg` use soft tints (0x162516 / 0x251616) for whole rows. This is a deliberate convention so retheming is one file rather than a grep across the codebase.
