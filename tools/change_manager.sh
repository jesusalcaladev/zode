#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSDIR="$ROOT/.changesets"
CMD="${1:-help}"
case "$CMD" in
  add)
    type="${2:-}"; scope="${3:-}"; desc="${4:-}"
    [ -z "$type" ] || [ -z "$scope" ] || [ -z "$desc" ] && { echo "Usage: $0 add <type> <scope> <description>"; exit 1; }
    id=$(python3 -c "import secrets;print(secrets.token_hex(4))" 2>/dev/null || od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    fp="$CSDIR/${id}.json"
    printf '{\n  "type": "%s",\n  "scope": "%s",\n  "description": "%s",\n  "breaking": false\n}\n' "$type" "$scope" "$desc" > "$fp"
    echo "Changeset: $fp"
    ;;
  version)
    base=$(python3 -c "import json;print(json.load(open('$CSDIR/config.json'))['base_version'])" 2>/dev/null || echo "0.2.0-beta")
    echo "Current: $base"
    n_major=0;n_minor=0;n_patch=0;n_pre=0
    for f in "$CSDIR"/*.json; do [ -f "$f" ] || continue; t=$(python3 -c "import json;print(json.load(open('$f'))['type'])" 2>/dev/null || echo "")
      case "$t" in breaking|next) n_major=$((n_major+1));; feature) n_minor=$((n_minor+1));; fix|perf|refactor|docs|chore) n_patch=$((n_patch+1));; beta) n_pre=$((n_pre+1));; esac; done
    if [ $n_major -gt 0 ]; then bump=major; elif [ $n_minor -gt 0 ]; then bump=minor; elif [ $n_patch -gt 0 ]; then bump=patch; elif [ $n_pre -gt 0 ]; then bump=prerelease; else bump=none; fi
    echo "Bump: $bump"
    if [ "$bump" = "prerelease" ]; then num=$(echo "$base" | grep -oP '\.beta\.\K\d+' || echo "0"); next_num=$((num+1)); next="$(echo "$base" | sed -E 's/\.beta\.\d+//').beta.${next_num}"
    elif [ "$bump" = "major" ]; then maj=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f1); next="${maj}.0.0-beta.1"
    elif [ "$bump" = "minor" ]; then maj=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f1); min=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f2); next="${maj}.$((min+1)).0-beta.1"
    elif [ "$bump" = "patch" ]; then maj=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f1); min=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f2); pat=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f3); next="${maj}.${min}.$((pat+1))-beta.1"
    else next="$base"; fi
    echo "Next: $next"
    ;;
  changelog)
    {
      echo "## [Unreleased]"; echo ""
      any=0
      for f in "$CSDIR"/*.json; do [ -f "$f" ] || continue
        t=$(python3 -c "import json;print(json.load(open('$f'))['type'])" 2>/dev/null || echo "")
        d=$(python3 -c "import json;print(json.load(open('$f'))['description'])" 2>/dev/null || echo "")
        case "$t" in feature|beta|next) [ "$any" != "features" ] && { echo "### Features"; echo ""; any="features"; }; echo "- $d";; fix) [ "$any" != "fixes" ] && { echo "### Fixes"; echo ""; any="fixes"; }; echo "- $d";; *) [ "$any" != "other" ] && { echo "### Other"; echo ""; any="other"; }; echo "- $d";; esac; done
      [ "$any" = "0" ] && echo "No changes."
      echo ""
      [ -f "$ROOT/CHANGELOG.md" ] && tail -n +2 "$ROOT/CHANGELOG.md"
    } > "$ROOT/CHANGELOG.tmp"; mv "$ROOT/CHANGELOG.tmp" "$ROOT/CHANGELOG.md"
    echo "Changelog updated: $ROOT/CHANGELOG.md"
    ;;
  release)
    base=$(python3 -c "import json;print(json.load(open('$CSDIR/config.json'))['base_version'])" 2>/dev/null || echo "0.2.0-beta")
    n_major=0;n_minor=0;n_patch=0;n_pre=0
    for f in "$CSDIR"/*.json; do [ -f "$f" ] || continue; t=$(python3 -c "import json;print(json.load(open('$f'))['type'])" 2>/dev/null || echo "")
      case "$t" in breaking|next) n_major=$((n_major+1));; feature) n_minor=$((n_minor+1));; fix|perf|refactor|docs|chore) n_patch=$((n_patch+1));; beta) n_pre=$((n_pre+1));; esac; done
    if [ $n_major -gt 0 ]; then bump=major; elif [ $n_minor -gt 0 ]; then bump=minor; elif [ $n_patch -gt 0 ]; then bump=patch; elif [ $n_pre -gt 0 ]; then bump=prerelease; else bump=none; fi
    if [ "$bump" = "prerelease" ]; then num=$(echo "$base" | grep -oP '\.beta\.\K\d+' || echo "0"); next_num=$((num+1)); next="$(echo "$base" | sed -E 's/\.beta\.\d+//').beta.${next_num}"
    elif [ "$bump" = "major" ]; then maj=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f1); next="${maj}.0.0-beta.1"
    elif [ "$bump" = "minor" ]; then maj=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f1); min=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f2); next="${maj}.$((min+1)).0-beta.1"
    elif [ "$bump" = "patch" ]; then maj=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f1); min=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f2); pat=$(echo "$base" | sed -E 's/-.*//'|cut -d. -f3); next="${maj}.${min}.$((pat+1))-beta.1"
    else next="$base"; fi
    echo "Release $base -> $next"
    sed -i "s/\.version = \".*\"/.version = \"$next\"/" "$ROOT/build.zig.zon" 2>/dev/null && echo "Updated build.zig.zon -> $next"
    "$0" changelog
    echo "Release $next ready. Tag: git tag v$next"
    ;;
  *) echo "change_manager - Zig changeset tool"; echo "Usage: $0 <add|version|changelog|release> [args...]"; echo "Types: feature, fix, perf, refactor, docs, chore, beta, next, breaking";;
esac