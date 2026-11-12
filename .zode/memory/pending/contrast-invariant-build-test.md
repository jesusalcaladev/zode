---
id: contrast-invariant-build-test
title: "Contrast is enforced as a build invariant, not a guideline"
tags: "theme, contrast, accessibility, testing"
evidence: "end-of-turn extractor; user approval required"
---

theme.zig keeps a `text_pairs` list (lines 316-340) that is "the rule": every text/background combination used in the TUI. A test at the bottom of the file fails the build when any pair falls below `min_text_contrast = 4.5` (or `min_mark_contrast = 1.25` for marks like rails/bullets). The file notes the contrast check compares the lighter value in the denominator; an earlier version compared the wrong way and "passed" a 1.6:1 pair. Ink3 and code_comment were both revised upward after this test rejected earlier drafts (ink3 was 4.44:1 on well_bg, code_comment's #6b7280 was 3.9:1).
