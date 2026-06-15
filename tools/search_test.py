#!/usr/bin/env python3
"""Verify in-buffer search: incremental jump, cancel, n, and match highlight."""
import os, pty, select, sys, time, fcntl, termios, struct

ZED = sys.argv[1]
TARGET = sys.argv[2]
ESC = b"\x1b"
CR = b"\r"

def session(chunks, initial, capture=False):
    with open(TARGET, "w") as f:
        f.write(initial)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(ZED, [ZED, TARGET])
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = bytearray()
    deadline = time.time() + 3 + 0.1 * len(chunks)
    for ch in chunks:
        time.sleep(0.1)
        os.write(fd, ch)
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                data = os.read(fd, 8192)
            except OSError:
                break
            if not data:
                break
            if capture:
                out.extend(data)
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                break
        except ChildProcessError:
            break
    try: os.write(fd, b"\x1b:q!\r")
    except OSError: pass
    end = time.time() + 1.0
    while time.time() < end:
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                break
        except ChildProcessError:
            break
        time.sleep(0.05)
    else:
        try: os.kill(pid, 9)
        except ProcessLookupError: pass
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(fd)
    with open(TARGET) as f:
        return bytes(out), f.read()

fails = 0
def check(name, cond):
    global fails
    print(f"[{'PASS' if cond else 'FAIL'}] {name}")
    if not cond:
        fails += 1

# / finds and edits (cursor lands on the match).
_, c = session([b"/gamma", CR, b"x", b":wq", CR], "alpha\nbeta\ngamma\n")
check("/ jumps to match and edits", c == "alpha\nbeta\namma\n")

# Esc cancels the search and restores the original cursor (still on line 1).
_, c = session([b"/gamma", ESC, b"x", b":wq", CR], "alpha\nbeta\ngamma\n")
check("Esc cancels, cursor restored", c == "lpha\nbeta\ngamma\n")

# n repeats to the next match.
_, c = session([b"/foo", CR, b"n", b"x", b":wq", CR], "foo\nfoo\nfoo\n")
check("n repeats to next match", c == "foo\nfoo\noo\n")

# Live highlight uses the match colour while typing (theme.match = 61;89;161).
out, _ = session([b"/beta"], "alpha\nbeta\ngamma\n", capture=True)
check("matches are highlighted", b"\x1b[48;2;61;89;161m" in out)

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
