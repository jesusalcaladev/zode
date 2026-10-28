# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Other

-  baseline: state of the project before the free-auto worktree [`26ec9d47`]

## [0.2.0] - 2026-10-28

### Changed

- Consolidated every tool-result cap into a single layer (`src/lib/resultcap.zig`): per-tool cap (`default_max_result_chars`), per-message aggregate budget (`max_results_per_message_chars`), UTF-8-safe cuts, and the cut notice kept inside the budget. Previously this logic lived in three places.
- Removed the duplicated cap code from `src/lib/subagent.zig` (its own `capResult` + `cut_notice` + tests). Subagent results now go through `resultcap.capResult` with the subagent's tighter cap.
- Removed the dead `toolstore.initFromEnv` and its duplicated constants from `src/lib/toolstore.zig`; the store now reads its cap from `resultcap`.
- Dropped the now-stale `subagent.capResult` reference from `src/lib/textcap.zig` docs.

### Fixed

- Subagent tool results now carry a cut notice instead of silent mid-line / mid-UTF-8 fragments, so a fragment can no longer be mistaken for the whole output.
