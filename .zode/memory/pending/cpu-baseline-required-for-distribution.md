---
id: cpu-baseline-required-for-distribution
title: "Distributed binaries must use -Dcpu=baseline"
tags: "build, convention, pitfall"
evidence: "end-of-turn extractor; user approval required"
---

The README (build flags table, line 76) states that `-Dcpu=baseline` is required for any binary that is distributed. Without it, Zig targets the local machine's CPU and older hardware gets `Illegal instruction`. Production builds should combine `-Doptimize=ReleaseSmall -Dcpu=baseline`.
