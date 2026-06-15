#!/usr/bin/env python3
"""Verify the LSP client against the mock server.

Runs zed with --lsp pointing at tools/mock_lsp.py and checks the rendered output
for diagnostics (count/sign/message), hover, incremental didChange, completion
(popup + accept) and signature help (popup + active-parameter highlight +
overload cycling).
"""
import os, pty, select, sys, time, fcntl, termios, struct, re

ANSI = re.compile(rb"\x1b\[[0-9;]*[A-Za-z]")  # strip CSI escapes (colour, cursor)

ZED = os.path.abspath(sys.argv[1])
MOCK = os.path.abspath(os.path.join(os.path.dirname(__file__), "mock_lsp.py"))
TARGET = "/tmp/zed_lsp.zig"

def run(keys_with_delays, final=b"\x1b:q!\r"):
    """Drive zed, returning (screen_bytes, saved_file_text). `final` is the quit
    sequence; use ":wq" to save so the caller can inspect the written file."""
    with open(TARGET, "w") as f:
        f.write("const a = 1;\nconst b = 2;\nconst c = 3;\n")
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(ZED, [ZED, "--lsp", "python3 " + MOCK, TARGET])
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = bytearray()
    def drain(dur):
        end = time.time() + dur
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try: data = os.read(fd, 8192)
                except OSError: return
                if not data: return
                out.extend(data)
    drain(1.5)  # startup handshake + didOpen + diagnostics
    for keys, dur in keys_with_delays:
        os.write(fd, keys)
        drain(dur)
    os.write(fd, final)
    drain(0.4)
    try: os.kill(pid, 9)
    except ProcessLookupError: pass
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(fd)
    try:
        with open(TARGET) as f: text = f.read()
    except FileNotFoundError: text = ""
    try: os.remove(TARGET)
    except FileNotFoundError: pass
    return bytes(out), text

fails = 0
def check(name, cond):
    global fails
    print(f"[{'PASS' if cond else 'FAIL'}] {name}")
    if not cond:
        fails += 1

RED = b"\x1b[38;2;247;118;142m"   # error sign colour (theme.git_delete)
DOT = b"\xe2\x97\x8f"             # U+25CF ●

# After startup: diagnostics arrive. "0" clears the startup status (cursor stays
# on line 0, off the diagnostic line) so the count shows; "j" moves onto the
# diagnostic line; "K" requests hover.
out, _ = run([(b"0", 0.5), (b"j", 0.6), (b"K", 0.8)])
check("diagnostic count in statusline", b"E:1 W:0" in out)
check("error sign rendered (red dot)", RED in out and DOT in out)
check("diagnostic message shown on its line", b"mock error" in out)
check("hover result shown", b"mock hover" in out)

# Incremental sync: the server advertises textDocumentSync=2, so an edit sends a
# ranged change. The mock echoes which kind it saw as a line-0 diagnostic; after
# editing on line 0 the cursor sits there, so the message shows in the bar.
out, _ = run([(b"ix", 0.8), (b"\x1b", 0.8)])
check("incremental didChange sent", b"INCREMENTAL" in out)
check("full didChange not sent", b"FULL" not in out)

# Completion: open a fresh line, type a prefix, Ctrl-N to request, Tab to accept.
# The mock returns mockComplete/mockOther; the prefix "mock" matches both and the
# first is accepted, replacing the typed prefix.
out, text = run([(b"omock", 0.4), (b"\x0e", 0.9), (b"\t", 0.4), (b"\x1b", 0.3)],
                final=b"\x1b:wq\r")
check("completion popup shows candidate", b"mockComplete" in out)
check("accepted completion written to file", "mockComplete\n" in text)

# Signature help: typing "(" requests it and a one-line popup shows the
# signature with the active parameter emphasized in theme.builtin. The server
# returns two overloads; Ctrl-p cycles to the previous one (wrapping).
BUILTIN = b"\x1b[38;2;224;175;104m"  # theme.builtin colour (active parameter)
out, _ = run([(b"omockFn(", 0.9), (b"\x10", 0.6)])  # type "(", then Ctrl-p
plain = ANSI.sub(b"", out)  # the active parameter is wrapped in colour escapes
check("signature popup shows label", b"mockFn(a: int, b: int)" in plain)
# The active parameter (offsets [7,13) -> "a: int") is the highlighted run.
check("active parameter highlighted", BUILTIN + b"a: int" in out)
check("overload counter shown", b"(1/2)" in plain)
check("Ctrl-p cycles to other overload", b"mockFn(a: str)" in plain and b"(2/2)" in plain)

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
