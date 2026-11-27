#!/usr/bin/env python3
"""Gate for PermissionRequest approve/deny in the REAL headless loop (43.7).

In headless there is no dialog, but PermissionRequest hooks are still fired.
This smoke gives the hook a decisive JSON answer and verifies BOTH branches:

  deny   -> the tool must NOT run (no marker file) and the result must say so
  approve-> the tool MUST run (marker file exists)

Usage: python3 tools/permission_smoke.py
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


def run_branch(name: str, decision: str, message: str) -> tuple[bool, str, Path]:
    home = f"/tmp/opencode/zode-perm-{name}-home"
    work = Path(f"/tmp/opencode/zode-perm-{name}-work")
    for path in (home, str(work)):
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path, exist_ok=True)
    meta = work / ".zode"
    meta.mkdir()
    payload = json.dumps({"permissionDecision": decision, "systemMessage": message})
    (meta / "hooks.json").write_text(json.dumps({"hooks": [{
        "event": "PermissionRequest",
        "matcher": "bash",
        "command": f"printf '%s' {json.dumps(payload)}",
        "timeout_ms": 2000,
    }]}))

    provider = subprocess.Popen(
        [sys.executable, str(ROOT / "tools" / "fake_provider.py")],
        cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(1.0)
        env = dict(os.environ)
        env.update({
            "HOME": home,
            "ZODE_PROVIDER": "local",
            "ZODE_MODEL": "fake-1",
            "ZODE_NO_SELF_UPDATE": "1",
            "ZODE_DBG_MODELS": "1",
        })
        try:
            res = subprocess.run(
                [str(BIN), "--chat", "permhook scenario"],
                cwd=str(work), env=env, capture_output=True, text=True, timeout=60,
            )
        except subprocess.TimeoutExpired:
            return False, "TIMEOUT: --chat did not finish", work
    finally:
        provider.terminate()
        try:
            provider.wait(timeout=5)
        except subprocess.TimeoutExpired:
            provider.kill()
    return True, res.stdout + res.stderr, work


def main() -> int:
    if not BIN.exists():
        print(f"FAIL: {BIN} missing; run zig build first")
        return 1

    ok_deny, deny_out, deny_work = run_branch("deny", "deny", "BLOCKED_BY_HOOK")
    ok_approve, approve_out, approve_work = run_branch("approve", "allow", "ALLOWED_BY_HOOK")
    deny_marker = (deny_work / "perm-hook-marker.txt").exists()
    approve_marker = (approve_work / "perm-hook-marker.txt").exists()

    checks = {
        "deny branch finished": ok_deny,
        "deny was reported": "denied by PermissionRequest hook" in deny_out,
        "deny reason reached the model": "BLOCKED_BY_HOOK" in deny_out,
        "denied tool did not run": not deny_marker,
        "approve branch finished": ok_approve,
        "approved tool ran": approve_marker,
        "approve did not report a denial": "denied by PermissionRequest hook" not in approve_out,
        "no panic": "panic" not in (deny_out + approve_out).lower(),
    }
    ok = True
    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed
    if not ok:
        print("--- deny tail ---")
        print(deny_out[-1500:])
        print("--- approve tail ---")
        print(approve_out[-1500:])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
