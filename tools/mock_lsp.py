#!/usr/bin/env python3
"""A tiny mock language server for testing zed's LSP client.

Speaks JSON-RPC over stdio with Content-Length framing. Answers `initialize`,
publishes one error diagnostic on didOpen/didChange, and replies to hover and
definition requests with fixed results.
"""
import sys, json

def read_msg():
    buf = b""
    while b"\r\n\r\n" not in buf:
        ch = sys.stdin.buffer.read(1)
        if not ch:
            return None
        buf += ch
    header, rest = buf.split(b"\r\n\r\n", 1)
    length = 0
    for h in header.split(b"\r\n"):
        if h.lower().startswith(b"content-length:"):
            length = int(h.split(b":", 1)[1].strip())
    body = rest
    while len(body) < length:
        chunk = sys.stdin.buffer.read(length - len(body))
        if not chunk:
            break
        body += chunk
    try:
        return json.loads(body[:length])
    except Exception:
        return {}

def send(obj):
    data = json.dumps(obj).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(data))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()

def diagnostics():
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
        "uri": "x",
        "diagnostics": [{
            "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 3}},
            "severity": 1,
            "message": "mock error",
        }],
    }})

while True:
    m = read_msg()
    if m is None:
        break
    method = m.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"capabilities": {}}})
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        diagnostics()
    elif method == "textDocument/hover":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"contents": "mock hover"}})
    elif method == "textDocument/definition":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {
            "uri": "file:///x",
            "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 0}},
        }})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
