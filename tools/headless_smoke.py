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
import socket
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


def timeout_scenario() -> bool:
    """A dead endpoint must fail near ZODE_HTTP_TIMEOUT_MS, not hang the worker.

    A socket that LISTENS but never ACCEPTs still completes the TCP handshake
    from the backlog, so the client blocks waiting for a response that never
    comes — precisely the failure that made a bad ZODE_BASE_URL hang forever.
    """
    if not BIN.exists():
        return True
    home = "/tmp/opencode/zode-http-timeout-smoke-home"
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home, exist_ok=True)

    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(5)
    port = listener.getsockname()[1]
    env = dict(os.environ)
    env.update({
        "HOME": home,
        "ZODE_PROVIDER": "local",
        "ZODE_MODEL": "m",
        "ZODE_BASE_URL": f"http://127.0.0.1:{port}/v1",
        "ZODE_HTTP_TIMEOUT_MS": "1500",
        "ZODE_NO_SELF_UPDATE": "1",
    })
    t0 = time.time()
    try:
        try:
            res = subprocess.run(
                [str(BIN), "--chat", "timeout scenario"],
                cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=10,
            )
        except subprocess.TimeoutExpired:
            print("FAIL  a dead endpoint is bounded by ZODE_HTTP_TIMEOUT_MS (hung >10s)")
            return False
        elapsed = time.time() - t0
        passed = elapsed < 8.0
        print(f"{'PASS' if passed else 'FAIL'}  a dead endpoint is bounded by ZODE_HTTP_TIMEOUT_MS ({elapsed:.1f}s)")
        return passed
    finally:
        listener.close()


if __name__ == "__main__":
    ok = main()
    if not timeout_scenario():
        ok = 1
    raise SystemExit(ok)
