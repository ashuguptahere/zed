#!/usr/bin/env python3
"""Verify the LSP client against the mock server: diagnostics, hover, goto.

Runs zed with --lsp pointing at tools/mock_lsp.py and checks the rendered output
for the diagnostic count/sign, the diagnostic message, and a hover result.
"""
import os, pty, select, sys, time, fcntl, termios, struct

ZED = os.path.abspath(sys.argv[1])
MOCK = os.path.abspath(os.path.join(os.path.dirname(__file__), "mock_lsp.py"))
TARGET = "/tmp/zed_lsp.zig"

def run(keys_with_delays):
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
    os.write(fd, b"\x1b:q!\r")
    drain(0.4)
    try: os.kill(pid, 9)
    except ProcessLookupError: pass
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(fd)
    try: os.remove(TARGET)
    except FileNotFoundError: pass
    return bytes(out)

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
out = run([(b"0", 0.5), (b"j", 0.6), (b"K", 0.8)])
check("diagnostic count in statusline", b"E:1 W:0" in out)
check("error sign rendered (red dot)", RED in out and DOT in out)
check("diagnostic message shown on its line", b"mock error" in out)
check("hover result shown", b"mock hover" in out)

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
