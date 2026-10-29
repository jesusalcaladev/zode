#!/usr/bin/env python3
"""Generate CHANGELOG.md from git history using conventional commits.

Reads `git log`, filters out housekeeping noise (cline checkpoints, "index on"
commits, untracked-file commits), classifies each remaining commit by its
conventional type (feat, fix, refactor, chore, docs, ...), and writes a Keep a
Changelog formatted CHANGELOG.md with everything under a single [Unreleased]
section grouped by type.

Usage:
    python3 tools/generate_changelog.py [output_path]

Defaults to writing CHANGELOG.md in the repo root.
"""

import os
import re
import subprocess
import sys
from collections import OrderedDict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GITHUB_BASE = "https://github.com/jesusalcaladev/zode/commit/"

# Commit subjects (or subjects containing these) that are housekeeping noise and
# must never appear in the changelog.
NOISE_PREFIXES = (
    "cline checkpoint",
    "index on",
    "untracked files",
)

# Conventional commit type -> human-readable Keep a Changelog section label.
TYPE_LABELS = {
    "feat": "Features",
    "fix": "Bug Fixes",
    "chore": "Chores",
    "docs": "Documentation",
    "refactor": "Refactors",
    "perf": "Performance",
    "test": "Tests",
    "build": "Build",
    "ci": "Continuous Integration",
    "style": "Styles",
    "revert": "Reverts",
}

TYPE_ORDER = [
    "feat", "fix", "chore", "docs", "refactor", "perf",
    "test", "build", "ci", "style", "revert",
]

# Types that trigger an automatic changelog regeneration from the post-commit hook.
AUTO_TYPES = {"feat", "fix", "refactor", "docs", "perf", "test", "build", "ci"}

BREAKING_MARKER = "BREAKING CHANGE"


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO_ROOT)
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def is_noise(subject: str) -> bool:
    low = subject.lower()
    return any(low.startswith(p) for p in NOISE_PREFIXES)


def get_git_log() -> list[dict]:
    """Return list of meaningful commits with hash, date, type, scope, description, breaking."""
    # %x1e = record separator (RS), %x1f = field separator (US)
    raw = run(["git", "log", "--reverse",
               "--format=%H%x1f%ad%x1f%s%x1f%b%x1e", "--date=short"])
    if not raw:
        return []

    commits = []
    for block in raw.split("\x1e"):
        block = block.strip()
        if not block:
            continue
        parts = block.split("\x1f")
        if len(parts) < 4:
            continue
        hsh, date, subject = parts[0], parts[1], parts[2]
        body = "\x1f".join(parts[3:]) if len(parts) > 4 else parts[3]

        if is_noise(subject):
            continue

        if is_noise(subject):
            continue

        # Parse conventional commit: type(scope): description
        m = re.match(r"^(\w+)(?:\(([^)]+)\))?:\s*(.+)$", subject, re.DOTALL)
        if m:
            ctype, scope, desc = m.group(1), m.group(2), m.group(3)
        else:
            ctype, scope, desc = "other", None, subject

        is_breaking = "!" in subject or BREAKING_MARKER in body
        commits.append({
            "hash": hsh[:8],
            "date": date,
            "type": ctype,
            "scope": scope,
            "desc": desc,
            "body": body.strip(),
            "breaking": is_breaking,
        })
    return commits


def render_changelog(commits: list[dict]) -> str:
    lines: list[str] = []
    lines.append("# Changelog")
    lines.append("")
    lines.append("All notable changes to this project will be documented in this file.")
    lines.append("")
    lines.append("The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)")
    lines.append("and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).")
    lines.append("")

    lines.append("## [Unreleased]")
    lines.append("")

    # Group by type
    grouped: OrderedDict[str, list[dict]] = OrderedDict()
    for t in TYPE_ORDER:
        grouped[t] = []
    grouped["other"] = []

    for c in commits:
        t = c["type"] if c["type"] in grouped else "other"
        grouped[t].append(c)

    any_section = False
    for t in TYPE_ORDER:
        items = grouped[t]
        if not items:
            continue
        any_section = True
        lines.append(f"### {TYPE_LABELS[t]}")
        lines.append("")
        for c in items:
            prefix = ""
            if c["breaking"]:
                prefix = "**BREAKING CHANGE:** "
            scope_part = f" ({c['scope']})" if c["scope"] else ""
            lines.append(
                f"- {prefix}{c['desc']}{scope_part}"
                f" [`{c['hash']}`]({GITHUB_BASE}{c['hash']})"
            )
        lines.append("")

    if grouped["other"]:
        any_section = True
        lines.append("### Other")
        lines.append("")
        for c in grouped["other"]:
            lines.append(f"- {c['desc']} [`{c['hash']}`]({GITHUB_BASE}{c['hash']})")
        lines.append("")

    if not any_section:
        lines.append("No changes yet.")
        lines.append("")

    return "\n".join(lines)


def write_changelog(output: str) -> int:
    commits = get_git_log()
    content = render_changelog(commits)
    with open(output, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"Wrote {output} ({len(commits)} commits)")
    return 0


def main() -> int:
    output = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO_ROOT, "CHANGELOG.md")
    return write_changelog(output)


if __name__ == "__main__":
    sys.exit(main())
