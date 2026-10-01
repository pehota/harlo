#!/usr/bin/env python3
# Spawns a child attached to a REAL pty as its controlling terminal (not a mock, not a plain pipe), so
# `open("/dev/tty")` inside the child resolves to something real. The child's actual stdin/stdout are separate
# ordinary pipes, carrying the Stdin/Result JSON contract untouched -- only what the child does with /dev/tty
# goes through the pty. Used by src/adapters/principal/tty.test.ts and test/e2e/terminal-principal.test.ts to
# exercise tty.ts's blocking read/write without a real human at a real terminal.
#
# Protocol: a JSON manifest on this script's own stdin:
#   {"argv": [...], "cwd": "...", "env": {...}, "input": "<text for the child's real stdin>",
#    "turns": [{"wait": "<substring that must appear in the pty output so far>", "send": "<text to write to the pty>"}, ...]}
# and a JSON result on this script's own stdout:
#   {"ptyOutput": "<everything the pty produced>", "stdout": "<the child's real stdout>", "exit": <code>}
import fcntl
import json
import os
import select
import struct
import sys
import termios
import time

TIMEOUT = 10.0


def wait_for(master_fd, substring, acc, cursor):
    """Find `substring` at or after `cursor[0]` (not just anywhere in `acc`) -- so a repeated prompt (e.g. the
    same gate header printed for a later Delivery attempt) is matched at its own turn, not an earlier one."""
    deadline = time.monotonic() + TIMEOUT
    while True:
        found = acc[0].find(substring, cursor[0])
        if found != -1:
            cursor[0] = found + len(substring)
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {substring!r}; got so far: {acc[0]!r}")
        ready, _, _ = select.select([master_fd], [], [], remaining)
        if not ready:
            continue
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        acc[0] += chunk.decode("utf8", errors="replace")


def main():
    manifest = json.loads(sys.stdin.read())
    argv = manifest["argv"]
    cwd = manifest.get("cwd") or os.getcwd()
    env = manifest.get("env") or dict(os.environ)
    child_input = manifest.get("input", "")
    turns = manifest.get("turns", [])

    master_fd, slave_fd = os.openpty()
    in_r, in_w = os.pipe()
    out_r, out_w = os.pipe()

    pid = os.fork()
    if pid == 0:
        os.close(master_fd)
        os.close(in_w)
        os.close(out_r)
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        os.dup2(in_r, 0)
        os.dup2(out_w, 1)
        os.dup2(slave_fd, 2)
        os.close(in_r)
        os.close(out_w)
        os.close(slave_fd)
        os.chdir(cwd)
        os.execvpe(argv[0], argv, env)
        os._exit(127)

    os.close(slave_fd)
    os.close(in_r)
    os.close(out_w)

    os.write(in_w, child_input.encode("utf8"))
    os.close(in_w)

    acc = [""]
    cursor = [0]
    for turn in turns:
        if "wait" in turn:
            wait_for(master_fd, turn["wait"], acc, cursor)
        if "send" in turn:
            os.write(master_fd, turn["send"].encode("utf8"))

    out_chunks = []
    while True:
        chunk = os.read(out_r, 4096)
        if not chunk:
            break
        out_chunks.append(chunk)
    os.close(out_r)

    # Drain any trailing pty output (e.g. terminal echo of the last turn) without hanging.
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master_fd], [], [], max(0.0, deadline - time.monotonic()))
        if not ready:
            break
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        acc[0] += chunk.decode("utf8", errors="replace")

    _, status = os.waitpid(pid, 0)
    exit_code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1

    print(json.dumps({"ptyOutput": acc[0], "stdout": b"".join(out_chunks).decode("utf8"), "exit": exit_code}))


if __name__ == "__main__":
    main()
