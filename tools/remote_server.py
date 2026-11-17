#!/usr/bin/env python3
"""Reference remote-session server for zode's /remote command (Phase 13.2).

A tiny stdlib HTTP server over a directory of zjsonl session files. It is NOT
started by zode — run it yourself on the machine that holds the sessions:

    python3 tools/remote_server.py --dir /path/to/sessions --token secret --port 8080

Then point zode at it:

    export ZODE_REMOTE_URL=http://127.0.0.1:8080
    export ZODE_REMOTE_TOKEN=secret
    /remote list
    /remote pull <id>
    /remote push <id>

Contract (kept deliberately minimal):
    GET  /sessions            -> [{"id": "...", "size": N, "updated": "..."}]
    GET  /sessions/<id>       -> raw .jsonl bytes
    PUT  /sessions/<id>       -> raw .jsonl bytes (body written atomically)

The token is optional but recommended; when set, every request must carry
`Authorization: Bearer <token>`. IDs are validated with the same rule as zode:
alphanumeric, '-' and '_' only, so no path traversal is possible.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
PREFIX = "zode-"
SUFFIX = ".jsonl"


class Sessions:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def path(self, sid: str) -> Path:
        if not ID_RE.match(sid):
            raise ValueError("bad session id")
        return self.root / f"{PREFIX}{sid}{SUFFIX}"

    def index(self) -> list[dict]:
        out: list[dict] = []
        for p in sorted(self.root.glob(PREFIX + "*" + SUFFIX)):
            sid = p.name[len(PREFIX) : -len(SUFFIX)]
            if not ID_RE.match(sid):
                continue
            stat = p.stat()
            out.append(
                {
                    "id": sid,
                    "size": stat.st_size,
                    "updated": str(int(stat.st_mtime)),
                }
            )
        return out


def make_handler(store: Sessions, token: str | None):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _authorized(self) -> bool:
            if token is None:
                return True
            return self.headers.get("Authorization") == f"Bearer {token}"

        def _deny(self, status: int, message: str) -> None:
            body = json.dumps({"error": message}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if not self._authorized():
                self._deny(401, "unauthorized")
                return
            if self.path == "/sessions":
                body = json.dumps(store.index()).encode()
                self._send(200, body, "application/json")
                return
            if self.path.startswith("/sessions/"):
                sid = self.path[len("/sessions/") :]
                try:
                    data = store.path(sid).read_bytes()
                except (ValueError, FileNotFoundError):
                    self._deny(404, "unknown session")
                    return
                self._send(200, data, "application/octet-stream")
                return
            self._deny(404, "unknown path")

        def do_PUT(self) -> None:  # noqa: N802
            if not self._authorized():
                self._deny(401, "unauthorized")
                return
            if not self.path.startswith("/sessions/"):
                self._deny(404, "unknown path")
                return
            sid = self.path[len("/sessions/") :]
            try:
                target = store.path(sid)
            except ValueError:
                self._deny(400, "bad session id")
                return
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > 64 * 1024 * 1024:
                self._deny(413, "too large")
                return
            body = self.rfile.read(length)
            # Atomic replace: a truncated upload must not corrupt a session.
            fd, tmp = tempfile.mkstemp(dir=str(store.root), prefix=".upload-")
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(body)
                os.replace(tmp, target)
            except OSError:
                if os.path.exists(tmp):
                    os.unlink(tmp)
                self._deny(500, "write failed")
                return
            self._send(200, b'{"ok":true}', "application/json")

        def log_message(self, fmt: str, *args) -> None:
            # Keep the terminal quiet; the index is the interface.
            pass

    return Handler


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", required=True, help="directory holding zode-*.jsonl files")
    ap.add_argument("--token", default=None, help="optional bearer token")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1")
    ns = ap.parse_args()

    store = Sessions(Path(ns.dir))
    server = ThreadingHTTPServer((ns.host, ns.port), make_handler(store, ns.token))
    print(f"serving {store.root} on http://{ns.host}:{ns.port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
