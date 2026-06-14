#!/usr/bin/env python3
"""Measure zed's CPU time while idle and confirm profiling logs are written."""
import os, pty, select, sys, time, fcntl, termios, struct

ZED = sys.argv[1]
TARGET = sys.argv[2]
LOG = sys.argv[3]

with open(TARGET, "w") as f:
    f.write("line\n" * 50)
try: os.remove(LOG)
except FileNotFoundError: pass

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execv(ZED, [ZED, "--log", LOG, TARGET])
    os._exit(127)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

def cpu_ticks():
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().split()
    return int(parts[13]) + int(parts[14])  # utime + stime (clock ticks)

def drain(dur):
    end = time.time() + dur
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: os.read(fd, 4096)
            except OSError: return

# Let it draw the first frame, then sit idle.
drain(0.5)
# A few keystrokes so there is something to profile.
for k in (b"j", b"j", b"l", b"k"):
    os.write(fd, k); drain(0.1)

t0 = cpu_ticks()
idle_seconds = 3.0
drain(idle_seconds)
t1 = cpu_ticks()

hz = os.sysconf("SC_CLK_TCK")
idle_cpu_ms = (t1 - t0) / hz * 1000.0

os.write(fd, b":q!\r")
drain(0.5)
try: os.waitpid(pid, 0)
except ChildProcessError: pass
os.close(fd)

print(f"CPU time consumed over {idle_seconds:.0f}s idle: {idle_cpu_ms:.1f} ms")
ok_idle = idle_cpu_ms < 50.0
print(f"[{'PASS' if ok_idle else 'FAIL'}] idle CPU is negligible (<50ms over 3s)")

log_ok = False
prof_lines = 0
if os.path.exists(LOG):
    with open(LOG) as f:
        text = f.read()
    prof_lines = sum(1 for ln in text.splitlines() if "profile" in ln)
    log_ok = prof_lines > 0
    print("\n--- log sample (first 8 lines) ---")
    print("\n".join(text.splitlines()[:8]))
print(f"\n[{'PASS' if log_ok else 'FAIL'}] profiling lines written to log: {prof_lines}")

sys.exit(0 if (ok_idle and log_ok) else 1)
