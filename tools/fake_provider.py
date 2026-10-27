#!/usr/bin/env python3
"""A fake OpenAI-compatible server, so the TUI's agent loop can be exercised
without a key, a quota or the internet.

zode's `local` provider points at `http://localhost:11434/v1` and needs no key,
so this server needs no configuration at all:

    python3 tools/fake_provider.py &      # listens on 127.0.0.1:11434
    ZODE_PROVIDER=local ZODE_MODEL=fake-1 zode

The scenario is picked by the FIRST user message, and the step by the number of
assistant messages already in the request. That makes the server stateless: it
cannot disagree with itself about where a turn is, and two runs of the same
prompt produce the same transcript — which is the whole point of a fixture.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 11434

# ── the scenarios ────────────────────────────────────────────────────────────
# Each step is either {"text": "..."} or {"tools": [call, ...]}.
# A `call` is {"name": "...", "args": {...}} and becomes a tool_call.

SCENARIOS = {
    "bg": [
        {"tools": [{"name": "run_in_background", "args": {"command": "echo start; sleep 3; echo done"}}]},
        {"tools": [{"name": "bash_output", "args": {"id": 1}}]},
        {"text": "bg scenario finished"},
    ],
    "edit": [
        {"tools": [{"name": "write", "args": {"path": "stress_file.txt", "content": "line one\nline two\n"}}]},
        {"tools": [{"name": "edit", "args": {"path": "stress_file.txt", "old_string": "two", "new_string": "TWO"}}]},
        {"text": "edit scenario finished"},
    ],
    "plan": [
        {"tools": [{"name": "todo", "args": {"todos": [
            {"task": "first step", "status": "pending"},
            {"task": "second step", "status": "in_progress"},
        ]}}]},
        {"tools": [{"name": "read", "args": {"path": "AGENTS.md"}}]},
        {"tools": [{"name": "todo", "args": {"todos": [
            {"task": "first step", "status": "done"},
            {"task": "second step", "status": "done"},
        ]}}]},
        {"text": "plan scenario finished"},
    ],
    "ask": [
        {"tools": [{"name": "ask", "args": {
            "question": "Which database should this project use?",
            "options": [
                {"label": "postgres", "description": "batteries included", "recommendation": True},
                {"label": "sqlite", "description": "no server"},
            ],
        }}]},
        {"text": "ask scenario finished"},
    ],
    "parallel": [
        {"tools": [
            {"name": "read", "args": {"path": "AGENTS.md"}},
            {"name": "read", "args": {"path": "README.md"}},
            {"name": "read", "args": {"path": "build.zig"}},
        ]},
        {"text": "parallel scenario finished"},
    ],
    "bigdiff": [
        {"tools": [{"name": "write", "args": {
            "path": "stress_big.txt",
            "content": "\n".join("row %03d of the big file" % i for i in range(400)) + "\n",
        }}]},
        {"tools": [{"name": "edit", "args": {
            "path": "stress_big.txt",
            "old_string": "row 200 of the big file",
            "new_string": "row 200 EDITED by the stress driver",
        }}]},
        {"text": "bigdiff scenario finished"},
    ],
    # The same call, over and over: the repetition guard has to speak.
    "repeat": [
        {"tools": [{"name": "read", "args": {"path": "AGENTS.md"}}]},
        {"tools": [{"name": "read", "args": {"path": "AGENTS.md"}}]},
        {"tools": [{"name": "read", "args": {"path": "AGENTS.md"}}]},
        {"tools": [{"name": "read", "args": {"path": "AGENTS.md"}}]},
        {"text": "repeat scenario finished"},
    ],
}


def scenario_for(messages):
    """The scenario of this conversation, from its first user message."""
    for m in messages:
        if m.get("role") != "user":
            continue
        text = m.get("content")
        if not isinstance(text, str):
            continue
        for name in SCENARIOS:
            if name in text.lower():
                return name
        return "default"
    return "default"


def assistant_count(messages):
    return sum(1 for m in messages if m.get("role") == "assistant")


def steps(name):
    """The steps of a scenario, ending with a final text."""
    return SCENARIOS.get(name, [{"text": "fake reply"}])


def chunk(delta, finish=None, usage=None):
    body = {
        "id": "chatcmpl-fake",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": "fake-1",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    if usage is not None:
        body["usage"] = usage
    return "data: %s\n\n" % json.dumps(body)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the driver's output readable
        pass

    def _send_json(self, obj, status=200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.endswith("/models"):
            self._send_json({"object": "list", "data": [
                {"id": "fake-1", "object": "model", "owned_by": "fake"},
                {"id": "fake-2", "object": "model", "owned_by": "fake"},
            ]})
            return
        if self.path.endswith("/selftest"):
            self._send_json({"ok": True})
            return
        self._send_json({"error": {"message": "unknown path %s" % self.path}}, 404)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw or b"{}")
        except Exception:
            req = {}
        messages = req.get("messages", [])
        name = scenario_for(messages)
        step = assistant_count(messages)
        wanted = steps(name)
        action = wanted[min(step, len(wanted) - 1)]

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        # No content-length AND no keep-alive: the stream is what the client
        # reads until [DONE], and with HTTP/1.1 the only way to say "that is all"
        # is to close. Without this the client waits for a length that never
        # arrives and every request hangs (measured: curl waited for ever).
        self.send_header("connection", "close")
        self.close_connection = True
        self.end_headers()

        out = []
        if "tools" in action:
            for i, call in enumerate(action["tools"]):
                args = json.dumps(call["args"])
                # Arguments in TWO chunks: a fragmented tool call is the shape
                # that broke the parser once, so the fixture keeps producing it.
                half = max(1, len(args) // 2)
                for j, piece in enumerate((args[:half], args[half:])):
                    out.append(chunk({
                        "role": "assistant" if (i == 0 and j == 0) else None,
                        "tool_calls": [{
                            "index": i,
                            "id": "call_%d" % (i + 1),
                            "type": "function",
                            "function": {"name": call["name"], "arguments": piece},
                        }],
                    }))
            out.append(chunk({}, "tool_calls", {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}))
        else:
            text = action["text"]
            out.append(chunk({"role": "assistant", "content": text[:20]})
                       if len(text) > 20 else chunk({"role": "assistant", "content": text}))
            if len(text) > 20:
                out.append(chunk({"content": text[20:]}))
            out.append(chunk({}, "stop", {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}))
        out.append("data: [DONE]\n\n")

        try:
            self.wfile.write("".join(out).encode())
            self.wfile.flush()
        except BrokenPipeError:
            pass  # the user pressed ESC: that is a supported outcome


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("fake provider listening on http://127.0.0.1:%d/v1" % PORT, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
