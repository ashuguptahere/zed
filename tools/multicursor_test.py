#!/usr/bin/env python3
"""Verify multiple cursors (Ctrl-n/Ctrl-p add carets; edits apply to all)."""
import os, pty, select, sys, time, fcntl, termios, struct

ZED = sys.argv[1]
TARGET = sys.argv[2]
ESC = b"\x1b"
CR = b"\r"
CN = b"\x0e"  # Ctrl-n: add cursor below
CP = b"\x10"  # Ctrl-p: add cursor above

def run(chunks, initial):
    with open(TARGET, "w") as f:
        f.write(initial)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm"
        os.execv(ZED, [ZED, TARGET])
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    deadline = time.time() + 3 + 0.1 * len(chunks)
    for ch in chunks:
        time.sleep(0.1)
        os.write(fd, ch)
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                if not os.read(fd, 8192):
                    break
            except OSError:
                break
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                break
        except ChildProcessError:
            break
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(fd)
    with open(TARGET) as f:
        return f.read()

fails = 0
def check(name, chunks, initial, want):
    global fails
    got = run(chunks, initial)
    ok = got == want
    print(f"[{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        fails += 1
        print(f"     got  {got!r}")
        print(f"     want {want!r}")

WQ = [b":wq", CR]

check("I inserts at all carets", [CN, CN, b"I", b"X", ESC] + WQ,
      "aaa\nbbb\nccc\n", "Xaaa\nXbbb\nXccc\n")
check("A appends at all carets", [CN, CN, b"A", b"!", ESC] + WQ,
      "aaa\nbbb\nccc\n", "aaa!\nbbb!\nccc!\n")
check("x deletes at all carets", [CN, CN, b"x"] + WQ,
      "aaa\nbbb\nccc\n", "aa\nbb\ncc\n")
check("Esc collapses to one cursor", [CN, CN, ESC, b"x"] + WQ,
      "aaa\nbbb\nccc\n", "aa\nbbb\nccc\n")
check("Ctrl-p adds above", [b"G", CP, CP, b"I", b">", ESC] + WQ,
      "aaa\nbbb\nccc\n", ">aaa\n>bbb\n>ccc\n")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
