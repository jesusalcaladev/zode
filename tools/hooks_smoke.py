#!/usr/bin/env python3
"""End-to-end smoke for hooks in the REAL headless tool loop (Phase 43.7).

Unit tests prove `hooks.fire` works; this proves the wiring: a project
PostToolUse hook must run when `--chat` executes a tool, not merely parse.

Usage: python3 tools/hooks_smoke.py
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out" / "bin" / "zode"
HOME = "/tmp/opencode/zode-hooks-smoke-home"
WORK = "/tmp/opencode/zode-hooks-smoke-work"


def main() -> int:
    if not BIN.exists():
        print(f"FAIL: {BIN} missing; run zig build first")
        return 1

    for path in (HOME, WORK):
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path, exist_ok=True)
    meta = Path(WORK) / ".zode"
    meta.mkdir()
    hooks = {"hooks": [{
        "event": "PostToolUse",
        "matcher": "bash",
        "command": "printf fired >> hook-marker.txt",
        "timeout_ms": 2000,
    }]}
    (meta / "hooks.json").write_text(json.dumps(hooks))

    provider = subprocess.Popen(
        [sys.executable, str(ROOT / "tools" / "fake_provider.py")],
        cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(1.0)
        env = dict(os.environ)
        env.update({
            "HOME": HOME,
            "ZODE_PROVIDER": "local",
            "ZODE_MODEL": "fake-1",
            "ZODE_NO_SELF_UPDATE": "1",
            "ZODE_YES": "1",  # a scripted `echo` must not wait on a dialog
        })
        try:
            res = subprocess.run(
                [str(BIN), "--chat", "hooksmoke scenario"],
                cwd=WORK, env=env, capture_output=True, text=True, timeout=45,
            )
        except subprocess.TimeoutExpired:
            print("FAIL: --chat timed out")
            return 1
    finally:
        provider.terminate()
        try:
            provider.wait(timeout=5)
        except subprocess.TimeoutExpired:
            provider.kill()

    out = res.stdout + res.stderr
    marker = Path(WORK) / "hook-marker.txt"
    checks = {
        # The marker on disk is a stronger proof than a tool name in the log:
        # it can only exist if the real tool loop fired the hook.
        "the answer reached stdout": "hooksmoke scenario finished" in out,
        "PostToolUse hook fired on disk": marker.exists() and "fired" in marker.read_text(),
        "no panic": "panic" not in out.lower(),
        "exited cleanly (0 or gate 2)": res.returncode in (0, 2),
    }

    ok = True
    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed
    if not ok:
        print("--- output tail ---")
        print(out[-2000:])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
