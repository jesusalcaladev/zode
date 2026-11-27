#!/usr/bin/env python3
"""Gate for background command completion in the REAL headless loop (43.7).

The `bg` fake-provider scenario starts a real `bash` with
`run_in_background: true`, then polls `bash_output`. Previously the scenario
called a non-existent `run_in_background` TOOL, so this flow was never
exercised at all. The smoke asserts the job starts, its output is drained once,
and its marker reaches the transcript.

Usage: python3 tools/background_smoke.py
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out" / "bin" / "zode"
HOME = "/tmp/opencode/zode-background-smoke-home"


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
            "ZODE_DBG_MODELS": "1",
            "ZODE_YES": "1",
        })
        try:
            res = subprocess.run(
                [str(BIN), "--chat", "bg scenario"],
                cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=60,
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
        "job started in the background": "started in the background as job" in out,
        "completion was drained once": out.count("finished exit=") == 1,
        "the job output reached the transcript": "bg-done-marker" in out,
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
