#!/usr/bin/env python3
"""Verify the fuzzy file picker and global search picker through a pty.

Sets up a temp directory of files, opens zed there, drives the pickers via the
space-leader menu, then edits + saves to confirm the right file/line was opened.
"""
import os, pty, select, sys, time, fcntl, termios, struct, tempfile, shutil

ZED = os.path.abspath(sys.argv[1])
ESC = b"\x1b"
CR = b"\r"

def run(files, open_arg, chunks):
    d = tempfile.mkdtemp(prefix="zedpick")
    for name, content in files.items():
        with open(os.path.join(d, name), "w") as f:
            f.write(content)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(d)
        os.environ["TERM"] = "xterm"
        os.execv(ZED, [ZED, open_arg])
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    deadline = time.time() + 4 + 0.12 * len(chunks)
    for ch in chunks:
        time.sleep(0.12)
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
    # Make sure it exits.
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
    result = {}
    for name in files:
        with open(os.path.join(d, name)) as f:
            result[name] = f.read()
    shutil.rmtree(d, ignore_errors=True)
    return result

fails = 0
def check(name, cond):
    global fails
    print(f"[{'PASS' if cond else 'FAIL'}] {name}")
    if not cond:
        fails += 1

# File picker: open a.txt, picker-open b.txt, delete a char, save.
files = {"a.txt": "aaa\n", "b.txt": "bbb\n"}
res = run(files, "a.txt", [b" f", b"b", CR, b"x", b":wq", CR])
check("file picker opened b.txt and edited it", res["b.txt"] == "bb\n")
check("file picker left a.txt untouched", res["a.txt"] == "aaa\n")

# Grep picker: search 'find', open match in c.txt at line 3, delete a char.
files = {"a.txt": "nothing\n", "c.txt": "one\ntwo\nfind me\n"}
res = run(files, "a.txt", [b" /", b"find", CR, b"x", b":wq", CR])
check("grep picker opened match at correct line", res["c.txt"] == "one\ntwo\nind me\n")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
