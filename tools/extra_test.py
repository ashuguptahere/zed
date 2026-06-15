#!/usr/bin/env python3
"""Verify surround (ys/cs/ds, visual S) and blockwise visual (Ctrl-v)."""
import os, pty, select, sys, time, fcntl, termios, struct

ZED = sys.argv[1]
TARGET = sys.argv[2]
ESC = b"\x1b"
CR = b"\r"
CV = b"\x16"  # Ctrl-v: blockwise visual

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

# --- surround ---
check("ysiw) wraps word",  [b"ysiw)"] + WQ, "foo bar\n", "(foo) bar\n")
check('cs"\' changes',     [b"cs\"'"] + WQ, 'say "hi"\n', "say 'hi'\n")
check("ds( deletes pair",  [b"ds("] + WQ, "(abc)\n", "abc\n")
check("visual S surrounds",[b"v$S]"] + WQ, "foo\n", "[foo]\n")

# --- blockwise visual ---
check("block I inserts left",  [CV, b"jj", b"I", b"X", ESC] + WQ,
      "aaa\nbbb\nccc\n", "Xaaa\nXbbb\nXccc\n")
check("block A appends right",  [CV, b"jj", b"A", b"!", ESC] + WQ,
      "aaa\nbbb\nccc\n", "a!aa\nb!bb\nc!cc\n")
check("block d deletes column", [CV, b"jjl", b"d"] + WQ,
      "aaa\nbbb\nccc\n", "a\nb\nc\n")
check("block c changes column", [CV, b"jj", b"c", b"Z", ESC] + WQ,
      "aaa\nbbb\nccc\n", "Zaa\nZbb\nZcc\n")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
