#!/usr/bin/env python3
"""ACP stdio smoke probe for zode.

Runs `zode acp` (or a given binary), performs a minimal ACP handshake and
session lifecycle checks that do not require an LLM provider. If ZODE_MODEL
and a provider key are configured in the environment, it can optionally try a
tiny prompt turn.

This probe uses its own HOME under /tmp/opencode to avoid touching user config.
"""
from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (ROOT / "zig-out" / "bin" / "zode").resolve()


class LineReader:
    def __init__(self, stream):
        self.stream = stream
        self.fd = stream.fileno()
        self.buf = b""

    def read_line(self, timeout: float = 10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                return json.loads(line.decode("utf-8", "replace"))
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if not r:
                if self.stream.closed:
                    break
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except Exception:
                break
            if not chunk:
                break
            self.buf += chunk
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            return json.loads(line.decode("utf-8", "replace"))
        return None


def send(p: subprocess.Popen[bytes], msg: dict) -> None:
    assert p.stdin is not None
    p.stdin.write((json.dumps(msg, separators=(",", ":")) + "\n").encode())
    p.stdin.flush()


def read_until(reader: LineReader, pred, timeout: float = 15.0):
    deadline = time.time() + timeout
    msgs = []
    while time.time() < deadline:
        msg = reader.read_line(timeout=0.5)
        if msg is None:
            continue
        msgs.append(msg)
        if pred(msg):
            return msg, msgs
    return None, msgs


def main() -> int:
    if not BIN.exists():
        print(f"FAIL: binary not found: {BIN}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(dir="/tmp", prefix="zode-acp-smoke-") as td:
        home = Path(td) / "home"
        cwd = Path(td) / "proj"
        home.mkdir()
        cwd.mkdir()
        env = os.environ.copy()
        env["HOME"] = str(home)
        env["XDG_CONFIG_HOME"] = str(home / ".config")
        env["XDG_STATE_HOME"] = str(home / ".state")
        env["XDG_CACHE_HOME"] = str(home / ".cache")
        # Keep provider config from user env only if explicitly present; probe is safe either way.
        p = subprocess.Popen(
            [str(BIN), "acp"],
            cwd=str(cwd),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            assert p.stdout is not None
            reader = LineReader(p.stdout)
            send(p, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}})
            msg, _ = read_until(reader, lambda m: m.get("id") == 1)
            if not msg or "result" not in msg:
                print(f"FAIL: initialize: {msg}", file=sys.stderr)
                return 1
            res = msg["result"]
            if res.get("protocolVersion") != 1:
                print(f"FAIL: protocolVersion: {res}", file=sys.stderr)
                return 1
            print("ok: initialize")

            send(p, {"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": str(cwd), "mcpServers": []}})
            msg, _ = read_until(reader, lambda m: m.get("id") == 2, timeout=20)
            if not msg or "result" not in msg:
                print(f"FAIL: session/new: {msg}", file=sys.stderr)
                return 1
            sid = msg["result"].get("sessionId")
            if not sid:
                print(f"FAIL: session/new missing sessionId: {msg}", file=sys.stderr)
                return 1
            print(f"ok: session/new {sid}")

            send(p, {"jsonrpc": "2.0", "id": 3, "method": "session/list", "params": {}})
            msg, _ = read_until(reader, lambda m: m.get("id") == 3)
            if not msg or "result" not in msg:
                print(f"FAIL: session/list: {msg}", file=sys.stderr)
                return 1
            print("ok: session/list")

            # Prompt without a configured model should still complete as a protocol turn
            # (agent returns an end_turn with an explanatory message) rather than deadlocking.
            send(p, {"jsonrpc": "2.0", "id": 4, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "hello"}]}})
            msg, msgs = read_until(
                reader,
                lambda m: m.get("id") == 4 and ("result" in m or "error" in m),
                timeout=30,
            )
            if not msg:
                tail = msgs[-5:] if msgs else []
                print(f"FAIL: session/prompt timeout; tail={tail}", file=sys.stderr)
                return 1
            if "error" in msg:
                print(f"ok: session/prompt returned error (acceptable in unconfigured env): {msg['error'].get('message')}")
            else:
                sr = (msg.get("result") or {}).get("stopReason")
                print(f"ok: session/prompt stopReason={sr}")
                updates = [m for m in msgs if m.get("method") == "session/update"]
                print(f"ok: session/update notifications={len(updates)}")

            send(p, {"jsonrpc": "2.0", "id": 5, "method": "session/close", "params": {"sessionId": sid}})
            msg, _ = read_until(reader, lambda m: m.get("id") == 5)
            if not msg or "result" not in msg:
                print(f"FAIL: session/close: {msg}", file=sys.stderr)
                return 1
            print("ok: session/close")

            print("PASS")
            return 0
        finally:
            try:
                if p.stdin:
                    p.stdin.close()
            except Exception:
                pass
            try:
                p.terminate()
                p.wait(timeout=2)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass
            try:
                err = (p.stderr.read() or b"") if p.stderr else b""
                if err.strip():
                    sys.stderr.write("--- stderr ---\n")
                    sys.stderr.buffer.write(err[:4000])
                    if not err.endswith(b"\n"):
                        sys.stderr.write("\n")
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
