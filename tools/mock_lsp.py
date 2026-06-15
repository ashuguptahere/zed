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

def diag(message, line, severity=1):
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
        "uri": "x",
        "diagnostics": [{
            "range": {"start": {"line": line, "character": 0}, "end": {"line": line, "character": 1}},
            "severity": severity,
            "message": message,
        }],
    }})

while True:
    m = read_msg()
    if m is None:
        break
    method = m.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"capabilities": {
            "textDocumentSync": 2,            # 2 = incremental
            "completionProvider": {},
            "signatureHelpProvider": {"triggerCharacters": ["(", ","]},
        }}})
    elif method == "textDocument/didOpen":
        diag("mock error", 1)
    elif method == "textDocument/didChange":
        # Report which sync kind we received, so the test can verify incremental.
        changes = m["params"]["contentChanges"]
        kind = "INCREMENTAL" if (changes and "range" in changes[0]) else "FULL"
        diag(kind, 0, severity=2)
    elif method == "textDocument/completion":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"items": [
            {"label": "mockComplete", "insertText": "mockComplete"},
            {"label": "mockOther", "insertText": "mockOther"},
        ]}})
    elif method == "textDocument/signatureHelp":
        # Two overloads to exercise cycling. Parameter labels are [start, end)
        # UTF-16 offsets into each signature label (exercises offset->byte).
        send({"jsonrpc": "2.0", "id": m["id"], "result": {
            "signatures": [
                {"label": "mockFn(a: int, b: int)",
                 "parameters": [{"label": [7, 13]}, {"label": [15, 21]}]},
                {"label": "mockFn(a: str)",
                 "parameters": [{"label": [7, 13]}]},
            ],
            "activeSignature": 0,
            "activeParameter": 0,
        }})
    elif method == "textDocument/hover":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"contents": "mock hover"}})
    elif method == "textDocument/definition":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {
            "uri": "file:///x",
            "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 0}},
        }})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
