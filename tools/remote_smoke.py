#!/usr/bin/env python3
"""Gate for `/remote` in a REAL pty (Phase 43.7).

Starts tools/remote_server.py with one fake session, opens the TUI with
ZODE_REMOTE_URL/TOKEN set, runs `/remote list`, and asserts the session id is
listed while the bearer token is never echoed to the screen (40.13).

The headless runner cannot drive slash commands, so this has to be a pty smoke.

Usage: python3 tools/remote_smoke.py
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import pty_smoke  # noqa: E402  (drive + strip_ansi, same pty rules)

STORE = "/tmp/opencode/zode-remote-smoke-store"
PORT = 8099
TOKEN = "secret-remote-smoke"


def main() -> int:
    binary = ROOT / "zig-out" / "bin" / "zode"
    if not binary.exists():
        print(f"FAIL: {binary} missing; run zig build first")
        return 1

    shutil.rmtree(STORE, ignore_errors=True)
    os.makedirs(STORE, exist_ok=True)
    Path(STORE, "zode-demo-session.jsonl").write_text('{"v":1,"messages":[]}\n')

    server = subprocess.Popen(
        [sys.executable, str(ROOT / "tools" / "remote_server.py"),
         "--dir", STORE, "--token", TOKEN, "--port", str(PORT)],
        cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(1.0)
        os.environ.update({
            "ZODE_REMOTE_URL": f"http://127.0.0.1:{PORT}",
            "ZODE_REMOTE_TOKEN": TOKEN,
        })
        try:
            out, text = pty_smoke.drive(
                [b"/remote list", b"\r"], budget=14, expect="demo-session",
            )
        except Exception as exc:
            print(f"FAIL: pty drive: {exc}")
            return 1
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()

    checks = {
        "the remote session was listed": "demo-session" in text,
        "the bearer token was not echoed": TOKEN not in text,
        "no panic": "panic" not in text.lower(),
    }
    ok = True
    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed
    if not ok:
        print("--- screen tail ---")
        print(text[-2000:])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
