#!/usr/bin/env python3
"""A fake language server: it speaks just enough LSP to drive the `lsp` tool.

It exists because the alternative was a test that only runs on a machine with
`zls` (or `clangd`, or `rust-analyzer`) installed, and a test that only runs on
some machines is a test that stops being run.

What it answers:

- `initialize` -> a capability set, and then it is a server
- `textDocument/didOpen` -> it PUBLISHES one diagnostic for the file, which is
  how a real server reports problems (nobody asks for them)
- every other request -> a canned answer that carries the file's URI, so the
  formatter has something real to render

The wire is the LSP one: `Content-Length: N\r\n\r\n` + the JSON body.
"""

import json
import sys

WORKSPACE_URI = "file:///fake/workspace.fakezig"


def read_message():
    """One framed JSON message from stdin, or None at end of stream."""
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        if b":" in line:
            key, value = line.split(b":", 1)
            headers[key.strip().lower()] = value.strip()
    try:
        length = int(headers.get(b"content-length", b"0"))
    except ValueError:
        return None
    body = sys.stdin.buffer.read(length)
    if not body:
        return None
    try:
        return json.loads(body)
    except ValueError:
        return None


def send(obj):
    data = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(data))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def reply(msg_id, result):
    send({"jsonrpc": "2.0", "id": msg_id, "result": result})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def a_range(line, character):
    return {
        "start": {"line": line, "character": character},
        "end": {"line": line, "character": character + 1},
    }


def main():
    while True:
        msg = read_message()
        if msg is None:
            break
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}

        if method == "initialize":
            reply(msg_id, {"capabilities": {}})
        elif method == "initialized":
            pass
        elif method == "textDocument/didOpen":
            uri = params.get("textDocument", {}).get("uri", "")
            # A server PUBLISHES its diagnostics. Nobody asks for them.
            notify(
                "textDocument/publishDiagnostics",
                {
                    "uri": uri,
                    "diagnostics": [
                        {
                            "range": a_range(1, 4),
                            "severity": 1,
                            "source": "fake",
                            "code": "E42",
                            "message": "expected ';'",
                        }
                    ],
                },
            )
        elif method == "textDocument/didChange":
            pass
        elif method == "textDocument/definition":
            uri = params.get("textDocument", {}).get("uri", "")
            reply(msg_id, [{"uri": uri, "range": a_range(0, 0)}])
        elif method == "textDocument/implementation":
            reply(msg_id, [])
        elif method == "textDocument/references":
            uri = params.get("textDocument", {}).get("uri", "")
            reply(
                msg_id,
                [
                    {"uri": uri, "range": a_range(0, 0)},
                    {"uri": uri, "range": a_range(2, 7)},
                ],
            )
        elif method == "textDocument/hover":
            reply(
                msg_id,
                {
                    "contents": {
                        "kind": "markdown",
                        "value": "```fakezig\npub fn main() void\n```",
                    }
                },
            )
        elif method == "textDocument/documentSymbol":
            reply(
                msg_id,
                [
                    {
                        "name": "main",
                        "kind": 12,
                        "range": a_range(0, 0),
                        "selectionRange": a_range(0, 4),
                    }
                ],
            )
        elif method == "workspace/symbol":
            reply(
                msg_id,
                [
                    {
                        "name": "Server",
                        "kind": 5,
                        "location": {"uri": WORKSPACE_URI, "range": a_range(6, 0)},
                    }
                ],
            )
        elif method == "textDocument/prepareCallHierarchy":
            uri = params.get("textDocument", {}).get("uri", "")
            reply(
                msg_id,
                [
                    {
                        "name": "main",
                        "kind": 12,
                        "uri": uri,
                        "range": a_range(0, 0),
                        "selectionRange": a_range(0, 4),
                    }
                ],
            )
        elif method == "callHierarchy/incomingCalls":
            uri = params.get("item", {}).get("uri", "")
            reply(
                msg_id,
                [
                    {
                        "from": {
                            "name": "caller",
                            "kind": 12,
                            "uri": uri,
                            "range": a_range(4, 0),
                            "selectionRange": a_range(4, 5),
                        },
                        "fromRanges": [a_range(3, 2)],
                    }
                ],
            )
        elif method == "callHierarchy/outgoingCalls":
            uri = params.get("item", {}).get("uri", "")
            reply(
                msg_id,
                [
                    {
                        "to": {
                            "name": "callee",
                            "kind": 12,
                            "uri": uri,
                            "range": a_range(8, 0),
                            "selectionRange": a_range(8, 5),
                        }
                    }
                ],
            )
        elif msg_id is not None:
            # Anything else: an empty answer, so the client is not left waiting.
            reply(msg_id, None)


if __name__ == "__main__":
    main()
