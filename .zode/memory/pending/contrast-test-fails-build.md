---
id: contrast-test-fails-build
title: "Theme contrast test fails the build below 3:1"
tags: "theme, accessibility, build-test"
evidence: "end-of-turn extractor; user approval required"
---

theme.zig contains a `contrastOk` test at the bottom that fails the build when any text/background pair is below 3:1 contrast. The ink3 and code_comment colors were raised from first-draft values (#7a7a7a and #6b7280) because the test rejected them at 4.44:1 and 3.9:1 respectively. Anyone editing colors must run this test.
