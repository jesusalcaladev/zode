#!/usr/bin/env python3
"""End-to-end smoke for the headless (`--chat`) runner (Phase 43.7).

Uses tools/fake_provider.py on 127.0.0.1:11434 and zode's built-in `local`
provider (no key needed). Checks that a scripted turn reaches the model, that
tool calls execute, and that the final answer reaches stdout — the runner that
every measurement uses, driven for real instead of by unit tests.

Usage: python3 tools/headless_smoke.py
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out" / "bin" / "zode"
HOME = "/tmp/opencode/zode-headless-smoke-home"


def main() -> int:
    if not BIN.exists():
        print(f"FAIL: {BIN} missing; run zig build first")
        return 1

    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(HOME, exist_ok=True)

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
            "ZODE_DBG_MODELS": "1",  # tool-call progress goes through models.dbg
        })
        try:
            res = subprocess.run(
                [str(BIN), "--chat", "headlesssmoke scenario"],
                cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=45,
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
    checks = {
        "the model answered": "headless headlesssmoke scenario finished" in out,
        "a tool call executed": "tool read" in out,
        "no panic": "panic" not in out.lower() and "thread " not in out.lower(),
    }
    # Exit 2 is the exit gate refusing to call an unverified turn "done"; it
    # is a VERDICT, not a crash. 0 or 2 are both acceptable here.
    checks["exited cleanly (0 or gate 2)"] = res.returncode in (0, 2)

    ok = True
    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed
    if not ok:
        print("--- output tail ---")
        print(out[-2000:])
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
