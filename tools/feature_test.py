#!/usr/bin/env python3
"""Verify the visual rendering (true-color, powerline, syntax) and the new
editing built-ins (auto-pairs, comment toggle) through a pty."""
import os, pty, select, sys, time, fcntl, termios, struct

ZED = sys.argv[1]
TARGET = sys.argv[2]
ESC = b"\x1b"
CR = b"\r"
BS = b"\x7f"

def session(chunks, initial, capture=False, target=TARGET):
    with open(target, "w") as f:
        f.write(initial)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(ZED, [ZED, target])
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
    # Ensure the editor exits even if the case sent no quit command.
    try: os.write(fd, b"\x1b:q!\r")
    except OSError: pass
    end = time.time() + 1.0
    alive = True
    while time.time() < end:
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                alive = False
                break
        except ChildProcessError:
            alive = False
            break
        time.sleep(0.05)
    if alive:
        try: os.kill(pid, 9)
        except ProcessLookupError: pass
        try: os.waitpid(pid, 0)
        except ChildProcessError: pass
    os.close(fd)
    with open(target) as f:
        content = f.read()
    return bytes(out), content

fails = 0
def check(name, cond):
    global fails
    print(f"[{'PASS' if cond else 'FAIL'}] {name}")
    if not cond:
        fails += 1

# ---- visual rendering (needs a .zig file for language detection) ----
ZIGTARGET = TARGET + ".zig"
ZIG = ("const std = @import(\"std\");\n"
       "pub fn main() void {\n"
       "        const x = 42; // hi\n"  # 8-space indent -> indent guide at col 4
       "}\n")
out, _ = session([], ZIG, capture=True, target=ZIGTARGET)
try: os.remove(ZIGTARGET)
except FileNotFoundError: pass
check("true-color foreground escapes", b"\x1b[38;2;" in out)
check("true-color background escapes", b"\x1b[48;2;" in out)
check("powerline separator glyph",     b"\xee\x82\xb0" in out)   # U+E0B0
check("keyword color (const/pub/fn)",   b"\x1b[38;2;187;154;247m" in out)  # theme.keyword
check("string color",                   b"\x1b[38;2;158;206;106m" in out)  # theme.string_
check("number color",                   b"\x1b[38;2;255;158;100m" in out)  # theme.number
check("indent guide glyph",             b"\xe2\x94\x82" in out)            # U+2502
check("mode label NORMAL shown",        b"NORMAL" in out)

# ---- auto-pairs ----
_, c = session([b"i", b"(", b"x", ESC] + [b":wq", CR], "")
check("autopair inserts closer",        c == "(x)\n")
_, c = session([b"i", b"(", b")", ESC] + [b":wq", CR], "")
check("autopair steps over closer",     c == "()\n")
_, c = session([b"i", b"(", BS, ESC] + [b":wq", CR], "")
check("backspace deletes empty pair",   c == "")
_, c = session([b'i', b'"', b'hi', ESC] + [b":wq", CR], "")
check("autopair quotes",                c == '"hi"\n')

# ---- comment toggle ----
_, c = session([b"gcc"] + [b":wq", CR], "abc\n")
check("gcc comments line",              c == "// abc\n")
_, c = session([b"gcc", b"gcc"] + [b":wq", CR], "abc\n")
check("gcc twice toggles back",         c == "abc\n")
_, c = session([b"gcj"] + [b":wq", CR], "a\nb\nc\n")
check("gcj comments two lines",         c == "// a\n// b\nc\n")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
