#!/usr/bin/env python3
# Drive a command on a pseudo-terminal, for tests that need a real tty.
#   printf 'PROMPT\tANSWER\n...' | pty_drive.py CMD [ARGS...]
# Waits for each PROMPT in the output, sends ANSWER and a newline, then prints
# everything the program wrote and exits with its status.
import os, pty, sys, time

steps = [line.rstrip("\n").split("\t", 1) for line in sys.stdin if line.strip()]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])

buf = b""

def fill():
    global buf
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        chunk = b""
    buf += chunk
    if os.environ.get("PTY_TRACE"):
        sys.stderr.write(chunk.decode(errors="replace"))
        sys.stderr.flush()
    return bool(chunk)

for step in steps:
    prompt, answer = step[0], (step[1] if len(step) > 1 else "")
    while prompt.encode() not in buf:
        if not fill():
            break
    # Give the program time to switch the tty to no-echo before answering.
    time.sleep(0.3)
    if os.environ.get("PTY_TRACE"):
        sys.stderr.write("\n<<SEND %r>>\n" % answer)
        sys.stderr.flush()
    os.write(fd, answer.encode() + b"\n")
while fill():
    pass
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
