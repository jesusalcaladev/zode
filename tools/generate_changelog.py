#!/usr/bin/env python3
"""Generate CHANGELOG.md from git history using conventional commits.

Reads `git log`, classifies each commit by type (feat, fix, chore, docs, etc.),
and writes a Keep a Changelog formatted CHANGELOG.md.

Usage:
    python3 tools/generate_changelog.py [output_path]

Defaults to writing CHANGELOG.md in the repo root.
"""

import os
import re
import subprocess
import sys
from collections import OrderedDict
from datetime import datetime

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Conventional commit type -> human-readable label
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

TYPE_ORDER = ["feat", "fix", "chore", "docs", "refactor", "perf", "test", "build", "ci", "style", "revert"]

BREAKING_MARKER = "BREAKING CHANGE"


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO_ROOT)
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def get_git_log() -> list[dict]:
    """Return list of commits with hash, date, type, scope, description, body, breaking."""
    raw = run(["git", "log", "--reverse", "--format=%H%x01%ad%x01%s%x01%b", "--date=short"])
    if not raw:
        return []

    commits = []
    for block in raw.split("\n\x01\n"):
        parts = block.split("\x01")
        if len(parts) < 3:
            continue
        hsh, date, subject = parts[0], parts[1], parts[2]
        body = parts[3] if len(parts) > 3 else ""

        # Parse conventional commit: type(scope): description
        m = re.match(r"^(\w+)(?:\(([^)]+)\))!?:\s*(.+)$", subject, re.DOTALL)
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


def render_changelog(commits: list[dict], unreleased: bool = True) -> str:
    lines: list[str] = []
    lines.append("# Changelog")
    lines.append("")
    lines.append("All notable changes to this project will be documented in this file.")
    lines.append("")
    lines.append("The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),")
    lines.append("and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).")
    lines.append("")

    # Group by type
    grouped: OrderedDict[str, list[dict]] = OrderedDict()
    for t in TYPE_ORDER:
        grouped[t] = []
    grouped["other"] = []

    for c in commits:
        t = c["type"] if c["type"] in grouped else "other"
        grouped[t].append(c)

    header = "## [Unreleased]" if unreleased else f"## [{datetime.now().strftime('%Y-%m-%d')}]"
    lines.append(header)
    lines.append("")

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
            scope_part = f"({c['scope']}) " if c["scope"] else ""
            lines.append(f"- {prefix}{c['desc']}{scope_part} [`{c['hash']}`](https://github.com/jesusalcaladev/zode/commit/{c['hash']})")
        lines.append("")

    if grouped["other"]:
        any_section = True
        lines.append("### Other")
        lines.append("")
        for c in grouped["other"]:
            lines.append(f"- {c['desc']} [`{c['hash']}`]")
        lines.append("")

    if not any_section:
        lines.append("No changes yet.")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    output = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO_ROOT, "CHANGELOG.md")
    commits = get_git_log()
    content = render_changelog(commits)
    with open(output, "w") as f:
        f.write(content)
    print(f"Wrote {output} ({len(commits)} commits)")
    return 0


if __name__ == "__main__":
    sys.exit(main())