#!/usr/bin/env python3
"""Verify the git change gutter: add/change/delete signs render in their colours.

Sets up a real git repo in a temp dir, commits a file, modifies it, opens zed,
and checks the rendered output for the sign colours. Uses .txt files so the only
colours present come from the git gutter (no syntax highlighting).
"""
import os, pty, select, sys, time, fcntl, termios, struct, tempfile, shutil, subprocess

ZED = os.path.abspath(sys.argv[1])

ENV = dict(os.environ)
ENV.update({
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
})

def git(d, *args):
    subprocess.run(["git", *args], cwd=d, env=ENV, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def capture(committed, modified, name="f.txt"):
    d = tempfile.mkdtemp(prefix="zedgit")
    git(d, "init")
    with open(os.path.join(d, name), "w") as f: f.write(committed)
    git(d, "add", name)
    git(d, "commit", "-m", "init")
    with open(os.path.join(d, name), "w") as f: f.write(modified)  # working-tree change
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(d)
        os.environ["TERM"] = "xterm-256color"
        os.execv(ZED, [ZED, name])
        os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = bytearray()
    end = time.time() + 1.5
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: data = os.read(fd, 8192)
            except OSError: break
            if not data: break
            out.extend(data)
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

ADD = b"\x1b[38;2;158;206;106m"     # theme.git_add
CHANGE = b"\x1b[38;2;224;175;104m"  # theme.git_change
DELETE = b"\x1b[38;2;247;118;142m"  # theme.git_delete
BAR = b"\xe2\x94\x82"               # U+2502
LOWBLOCK = b"\xe2\x96\x81"          # U+2581

out = capture("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\nadded\n")
check("changed line shows change sign", CHANGE in out and BAR in out)
check("added line shows add sign", ADD in out)

out = capture("one\ntwo\nthree\n", "one\nthree\n")
check("deleted line shows delete sign", DELETE in out and LOWBLOCK in out)

out = capture("same\nlines\n", "same\nlines\n")
check("unchanged file shows no sign colours", CHANGE not in out and ADD not in out and DELETE not in out)

print()
print("ALL PASS" if fails == 0 else f"{fails} FAILURE(S)")
sys.exit(1 if fails else 0)
