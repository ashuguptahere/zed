#!/usr/bin/env python3
"""Drive zed through a real pseudo-terminal to verify the interactive path.

Spawns the editor on a scratch file, sends keystrokes, then checks the saved
result. This exercises raw mode, rendering, modal editing, save and quit.
"""
import os, pty, select, sys, time

ZED = sys.argv[1]
TARGET = sys.argv[2]

def run(keys, initial=None, timeout=4.0):
    if initial is None:
        try: os.remove(TARGET)
        except FileNotFoundError: pass
    else:
        with open(TARGET, "w") as f: f.write(initial)

    pid, fd = pty.fork()
    if pid == 0:  # child
        os.environ["TERM"] = "xterm"
        os.execv(ZED, [ZED, TARGET])
        os._exit(127)

    # Resize the pty so the editor sees a real window size.
    import fcntl, termios, struct
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    deadline = time.time() + timeout
    for chunk in keys:
        time.sleep(0.15)
        os.write(fd, chunk)
    # Drain output until the child exits or we time out.
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                if not os.read(fd, 4096):
                    break
            except OSError:
                break
        try:
            wpid, status = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                break
        except ChildProcessError:
            break
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(fd)

def read_target():
    with open(TARGET) as f: return f.read()

failures = 0
def check(name, got, want):
    global failures
    ok = got == want
    print(f"[{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        failures += 1
        print(f"       got:  {got!r}")
        print(f"       want: {want!r}")

# 1. Insert text into a fresh buffer and save with :wq
run([b"i", b"hello world", b"\x1b", b":wq\r"])
check("insert + :wq writes file", read_target(), "hello world\n")

# 2. Open existing file, append a line with 'o', save
run([b"o", b"line two", b"\x1b", b":wq\r"], initial="line one\n")
check("'o' opens line below", read_target(), "line one\nline two\n")

# 3. Delete a character with 'x' at start of line
run([b"x", b":wq\r"], initial="Xabc\n")
check("'x' deletes char", read_target(), "abc\n")

# 4. Unicode: insert multibyte text round-trips
run([b"i", "héllo 世界".encode("utf-8"), b"\x1b", b":wq\r"])
check("unicode insert round-trips", read_target(), "héllo 世界\n")

# 5. :q! discards changes
run([b"iJUNK", b"\x1b", b":q!\r"], initial="keep\n")
check(":q! discards edits", read_target(), "keep\n")

print()
print("ALL PASS" if failures == 0 else f"{failures} FAILURE(S)")
sys.exit(1 if failures else 0)
