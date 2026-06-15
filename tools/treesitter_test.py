#!/usr/bin/env python3
"""Verify tree-sitter highlighting is active for .zig files.

Discriminator: a Zig multiline string (\\\\...). The per-line lexer cannot
recognise it, so if its bytes are coloured with the string colour, the colour
must have come from tree-sitter. The file lives outside any git repo and we stay
in normal mode, so the green string colour can't come from a git sign or the
insert-mode block.
"""
import os, pty, select, sys, time, fcntl, termios, struct, tempfile, shutil

ZED = os.path.abspath(sys.argv[1])

ZIG = (
    "pub fn f() void {\n"
    "    const x =\n"
    "        \\\\hi\n"
    "    ;\n"
    "    _ = x;\n"
    "}\n"
)

# A file taller than the screen, with a multiline string near the bottom that
# is off-screen until we scroll down.
TALL = ("pub fn f() void {\n"
        + "".join(f"    const a{i} = {i};\n" for i in range(40))
        + "    const s =\n        \\\\deep\n    ;\n    _ = s;\n}\n")

def capture(keys=(), content=ZIG, name="sample.zig"):
    d = tempfile.mkdtemp(prefix="zedts")  # not a git repo
    path = os.path.join(d, name)
    with open(path, "w") as f:
        f.write(content)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(d)
        os.environ["TERM"] = "xterm-256color"
        os.execv(ZED, [ZED, name])
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = bytearray()
    def drain(dur):
        end = time.time() + dur
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try: data = os.read(fd, 8192)
                except OSError: return
                if not data: return
                out.extend(data)
    drain(1.0)
    for k in keys:
        os.write(fd, k); drain(0.4)
    os.write(fd, b"\x1b:q!\r"); time.sleep(0.3)
    try: os.kill(pid, 9)
    except ProcessLookupError: pass
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(fd)
    shutil.rmtree(d, ignore_errors=True)
    return bytes(out)

fails = 0
def check(name, cond):
    global fails
    print(f"[{'PASS' if cond else 'FAIL'}] {name}")
    if not cond:
        fails += 1

KEYWORD = b"\x1b[38;2;187;154;247m"  # theme.keyword (purple)
STRING = b"\x1b[38;2;158;206;106m"   # theme.string_ (green)
NUMBER = b"\x1b[38;2;255;158;100m"   # theme.number (orange)

# Full parse on load.
out = capture()
check("keywords highlighted", KEYWORD in out)
check("multiline string highlighted (tree-sitter only)", STRING in out)

# Incremental reparse: insert a new line at the top (O + text + Esc). The new
# tokens must be highlighted, and the pre-existing multiline string must stay
# highlighted (proving the reused tree wasn't corrupted by the edit).
out = capture(keys=[b"O", b"const z = 99;", b"\x1b"])
check("incremental: new keyword highlighted", KEYWORD in out)
check("incremental: new number highlighted", NUMBER in out)
check("incremental: existing string still highlighted", STRING in out)

# Visible-range query: a multiline string near the bottom of a tall file is
# off-screen at first; after scrolling to it (G), the re-query must highlight it.
out = capture(keys=[b"G"], content=TALL)
check("scroll re-queries: off-screen string highlighted after G", STRING in out)

# A TypeScript file goes through the new .typescript language variant
# (detect -> startTs -> grammar). A type annotation is highlighted as a type.
TYPE = b"\x1b[38;2;42;195;222m"  # theme.type_ (cyan)
out = capture(content="function f(a: number): string { return \"x\"; }\n", name="sample.ts")
check("typescript file highlights (type + string)", TYPE in out and STRING in out)

# A Rust file goes through the new .rust variant.
out = capture(content="fn main() {\n    let s = \"hi\";\n}\n", name="sample.rs")
check("rust file highlights (keyword + string)", KEYWORD in out and STRING in out)

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
