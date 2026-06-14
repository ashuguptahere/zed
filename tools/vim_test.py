#!/usr/bin/env python3
"""Drive zed through a pty to verify vim keybindings end-to-end.

Each case sends a sequence of key chunks, ends with :wq (or :q!), then checks
the saved file. Run: python3 tools/vim_test.py <zed-binary> <scratch-file>
"""
import os, pty, select, sys, time, fcntl, termios, struct

ZED = sys.argv[1]
TARGET = sys.argv[2]
ESC = b"\x1b"
CR = b"\r"
CTRL_R = b"\x12"

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
        time.sleep(0.09)
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

# --- operators + motions ---
check("dw deletes word",        [b"dw"] + WQ, "foo bar baz\n", "bar baz\n")
check("dd deletes line",        [b"dd"] + WQ, "a\nb\nc\n", "b\nc\n")
check("2dd deletes two lines",  [b"2dd"] + WQ, "a\nb\nc\nd\n", "c\nd\n")
check("cw changes word",        [b"cw", b"X", ESC] + WQ, "foo bar\n", "X bar\n")
check("3x deletes 3 chars",     [b"3x"] + WQ, "abcdef\n", "def\n")
check("de deletes to word end", [b"de"] + WQ, "foo bar\n", " bar\n")
check("d$ to end of line",      [b"ld$"] + WQ, "abcdef\n", "a\n")

# --- registers + paste ---
check("yy then p duplicates",   [b"yyp"] + WQ, "hello\nworld\n", "hello\nhello\nworld\n")
check("dd then p moves line",   [b"ddp"] + WQ, "a\nb\nc\n", "b\na\nc\n")

# --- visual ---
check("v selects then d",       [b"vlld"] + WQ, "abcdef\n", "def\n")
check("V deletes line",         [b"Vd"] + WQ, "a\nb\nc\n", "b\nc\n")
check("v y then p",             [b"vly", b"$p"] + WQ, "abcd\n", "abcdab\n")

# --- undo / redo ---
check("u undoes",               [b"x", b"u"] + WQ, "abc\n", "abc\n")
check("ctrl-r redoes",          [b"x", b"u", CTRL_R] + WQ, "abc\n", "bc\n")

# --- insert variants ---
check("A appends at end",       [b"A", b"Z", ESC] + WQ, "abc\n", "abcZ\n")
check("I inserts at first nb",  [b"I", b"X", ESC] + WQ, "  abc\n", "  Xabc\n")
check("o opens below",          [b"o", b"b", ESC] + WQ, "a\n", "a\nb\n")
check("O opens above",          [b"O", b"b", ESC] + WQ, "a\n", "b\na\n")

# --- single-key edits ---
check("J joins lines",          [b"J"] + WQ, "a\nb\n", "a b\n")
check("r replaces char",        [b"rX"] + WQ, "abc\n", "Xbc\n")
check("~ toggles case",         [b"~"] + WQ, "abc\n", "Abc\n")

# --- find motions with operators ---
check("dfc deletes incl char",  [b"dfc"] + WQ, "abcde\n", "de\n")
check("dt) deletes till char",  [b"dt)"] + WQ, "foo)bar\n", ")bar\n")

# --- text objects ---
check("diw deletes inner word", [b"diw"] + WQ, "foo bar\n", " bar\n")
check('ci" changes in quotes',  [b'ci"', b"X", ESC] + WQ, 'say "hi" x\n', 'say "X" x\n')
check("da( deletes a parens",   [b"lll", b"da("] + WQ, "x(abc)y\n", "xy\n")

# --- search ---
check("/ search then x",        [b"/foo", CR, b"x"] + WQ, "foo\nbar\nfoo\n", "foo\nbar\noo\n")
check("* searches word",        [b"*x"] + WQ, "foo bar foo\n", "foo bar oo\n")

# --- marks ---
check("ma `a returns",          [b"ma", b"G", b"`a", b"x"] + WQ, "a\nb\nc\n", "\nb\nc\n")

# --- macro ---
check("record qaq then @a",     [b"qa", b"xj", b"q", b"@a"] + WQ, "a\nb\nc\n", "\n\nc\n")

# --- dot repeat ---
check("dot repeats dw",         [b"dw", b"."] + WQ, "aaa bbb ccc\n", "ccc\n")

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
