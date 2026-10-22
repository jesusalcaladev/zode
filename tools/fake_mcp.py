#!/usr/bin/env python3
"""A fake MCP server: it speaks just enough JSON-RPC to drive the `mcp` tool.

It exists because the alternative was a test that only runs on a machine with
a real MCP server installed, and a test that only runs on some machines is a
test that stops being run.

What it answers:

- `initialize` -> the protocol version and a name
- `tools/list` -> three tools, with their schemas
- `tools/call` -> a canned answer that carries what was asked for

The wire is MCP's: ONE JSON-RPC message per line, and a message never
contains a raw newline. That is NOT the LSP framing (`Content-Length`
headers), and copying the LSP framer here would be the single most likely way
to get this wrong: a server that gets the wrong framing answers nothing at
all, and the symptom is "the tool does not work" with no message anywhere.

Before the answer to `tools/list` it sends a NOTIFICATION, on purpose: a
server may publish things at any time, and a client that mistakes a
notification for the answer it is waiting for is a client that hangs.
"""

import json
import sys

PROTOCOL_VERSION = "2025-06-18"

TOOLS = [
    {
        "name": "create_issue",
        "description": "Create an issue in the tracker",
        "inputSchema": {
            "type": "object",
            "properties": {"title": {"type": "string"}, "body": {"type": "string"}},
            "required": ["title"],
        },
    },
    {
        "name": "list_issues",
        "description": "List the issues of a repository",
        "inputSchema": {
            "type": "object",
            "properties": {"repo": {"type": "string"}},
        },
    },
    {
        "name": "echo",
        "description": "Return the text it is given, unchanged",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
]


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(msg_id, result):
    send({"jsonrpc": "2.0", "id": msg_id, "result": result})


def fail(msg_id, code, message):
    send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            continue

        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}

        if method == "initialize":
            reply(
                msg_id,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "fake-mcp", "version": "1.0"},
                },
            )
        elif method == "notifications/initialized":
            # A notification gets no answer: that is what makes it one.
            pass
        elif method == "tools/list":
            # A server may publish things at any time, and the client has to
            # step over them to find the answer it is waiting for.
            notify("notifications/message", {"level": "info", "data": "fake-mcp is ready"})
            reply(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            name = params.get("name")
            args = params.get("arguments") or {}
            if name == "create_issue":
                title = args.get("title", "")
                reply(
                    msg_id,
                    {"content": [{"type": "text", "text": "created issue #42: " + title}]},
                )
            elif name == "list_issues":
                repo = args.get("repo", "unknown")
                reply(
                    msg_id,
                    {
                        "content": [
                            {"type": "text", "text": "3 issues in " + repo},
                            {"type": "text", "text": "#1 first"},
                        ]
                    },
                )
            elif name == "echo":
                reply(msg_id, {"content": [{"type": "text", "text": args.get("text", "")}]})
            elif name == "fails":
                # A tool that fails is NOT an exception: the call went through
                # and the tool decided it could not do it.
                reply(
                    msg_id,
                    {"content": [{"type": "text", "text": "the tracker is unreachable"}], "isError": True},
                )
            else:
                fail(msg_id, -32602, "unknown tool: " + str(name))
        elif msg_id is not None:
            # Anything else: an empty answer, so the client is not left waiting.
            reply(msg_id, None)


if __name__ == "__main__":
    main()
