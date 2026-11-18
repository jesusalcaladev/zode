# Releasing zode

This is the runbook for cutting a zode release. The whole flow is one tool —
`churn` — plus the GitHub release workflow. There is no manual `sed` of the
version and no hand-written `git tag` step.

## The two channels

A version is a SemVer triple with an optional prerelease suffix:

- **beta** — `v0.3.0-beta.1`. A prerelease sorts *below* its release, and GitHub
  keeps `/releases/latest` pointing at the last **stable** release. Betas are
  therefore invisible to stable users unless they opt in.
- **stable** — `v0.3.0`. The normal release.

The release workflow (`.github/workflows/release.yml`) already marks any tag
containing `-` as a GitHub prerelease. The same tag builds and publishes four
platform binaries (`linux-x86_64`, `linux-aarch64`, `macos-x86_64`,
`macos-aarch64`) with `-Dcpu=baseline` so the asset runs on older CPUs.

## Prerequisites

- On `main`, with a clean working tree (`git status --porcelain` is empty).
- `zig` 0.17.0, `python3`, `git`, `curl` available.
- Push rights to `origin`.

## The tool

```
zig build churn -Drun-args="version"          # dry run: what would be cut
zig build churn -Drun-args="version --beta"   # force a beta increment
zig build churn -Drun-args="version --stable" # promote to a stable release
zig build churn -Drun-args="add feat ui 'new picker'"
zig build churn -Drun-args="changelog"
zig build churn -Drun-args="release --beta"          # cut locally (no push)
zig build churn -Drun-args="release --beta --push"   # cut + push
```

After `zig build churn` you can also call `./zig-out/bin/churn version` etc.
directly — the binary is installed there.

### Commands

- `add <type> <scope> <description>` records a changeset in `.churn/`.
  Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `chore`, `breaking`,
  `next`, `beta`. `breaking`/`next` ⇒ major, `feat` ⇒ minor,
  `fix`/`perf`/`refactor`/`docs`/`chore` ⇒ patch, `beta` ⇒ prerelease bump.
- `version` prints `current`, the number of changesets, the derived `bump` and
  the `next` version. **Read-only** — it never writes files.
- `changelog` regenerates the `[Unreleased]` section of `CHANGELOG.md` from git
  history (delegates to `tools/generate_changelog.py`).
- `release` cuts the release: refuses a dirty tree, runs `zig build test`,
  writes the new version into `build.zig.zon`, regenerates the changelog, then
  commits and tags. **It never pushes without `--push`.**

## Cutting a beta

1. Record changesets for the work since the last release:

   ```
   zig build churn -Drun-args="add feat agent 'background tasks'"
   zig build churn -Drun-args="add fix crash 'loader buffer alias'"
   ```

2. Preview the bump:

   ```
   zig build churn -Drun-args="version --beta"
   ```

   Expect `current: 0.3.0-beta.1` → `next: 0.3.0-beta.2` (or the next minor
   core when you are promoting a stable line).

3. Cut and push:

   ```
   zig build churn -Drun-args="release --beta --push"
   ```

   This creates a local commit `chore(release): v0.2.1-beta.1` and tag
   `v0.2.1-beta.1`, then pushes `main` and the tag. The workflow builds and
   publishes all four assets as a prerelease.

4. Verify: the release appears under
   `https://github.com/jesusalcaladev/zode/releases` with the `Pre-release`
   badge. `/releases/latest` still points at the last **stable** release.

## Cutting a stable release

Same flow, but promote (drop the prerelease suffix):

```
zig build churn -Drun-args="version --stable"
zig build churn -Drun-args="release --stable --push"
```

`release --stable` writes a plain `0.3.0` into `build.zig.zon` and tags
`v0.3.0`. GitHub moves `/releases/latest` to it automatically.

## Opting into betas (users)

Self-update follows stable by default. A user who wants betas sets:

```
export ZODE_UPDATE_CHANNEL=beta
```

Then `/update` consults the beta channel: it lists the ten most recent GitHub
releases and picks the newest prerelease. A stable channel **never** installs a
beta — `release.allowed(.stable, …)` rejects prereleases, so there is no way to
be silently demoted.

A pinned beta can also be installed directly with the installer, without
changing the channel:

```
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/zode/main/install.sh \
  | bash -s -- --version v0.2.1-beta.1
```

## Manual fallback (if `churn release` is unavailable)

1. `zig build test` — must be green.
2. Edit `build.zig.zon`: `.version = "0.2.1-beta.1"`.
3. `python3 tools/generate_changelog.py` — regenerate the changelog.
4. Rename `## [Unreleased]` → `## [0.2.1-beta.1] - YYYY-MM-DD` and add a fresh
   `## [Unreleased]` above it.
5. Delete the consumed `.churn/*.json` changesets (keep `config.json`).
6. `git add -A && git commit -m "chore(release): v0.2.1-beta.1"`.
7. `git tag v0.2.1-beta.1`.
8. `git push origin main && git push origin v0.2.1-beta.1`.

## Safety invariants

- `release` refuses on a dirty tree — never cut from a working directory with
  uncommitted changes.
- `release` runs `zig build test` and aborts on failure.
- Pushing is **opt-in** via `--push`. Without it the tag is local only; review
  before pushing.
- `-Dcpu=baseline` is mandatory in the workflow for any distributed binary;
  failing to use it ships a SIGILL on older CPUs (documented inline in
  `release.yml`).
- Tags are lightweight and `v`-prefixed, matching `git describe --tags`.
