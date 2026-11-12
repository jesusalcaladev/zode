---
id: zig-0-17-0-pinned-dependency
title: "Project is pinned to Zig 0.17.0"
tags: "build, dependency, convention"
evidence: "end-of-turn extractor; user approval required"
---

The README (Build from source section, line 56) requires Zig 0.17.0 as the only toolchain dependency besides libvaxis (fetched by build.zig.zon). Future builds and CI must use this exact Zig version.
