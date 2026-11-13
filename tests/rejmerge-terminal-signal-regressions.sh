#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
binary=${1:-$root/build/rejmerge}
# Python supplies a real controlling terminal; all file changes stay in tmpfs.
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --chdir /tmp \
    --ro-bind "$binary" /tmp/rejmerge \
    -- python3 -I - <<'PY'
import fcntl
import os
import pathlib
import pty
import select
import signal
import subprocess
import termios
import time


def run(case, action):
    root = pathlib.Path('/tmp') / case
    rejected = root / 'var/lib/pkg/rejected/etc'
    rejected.mkdir(parents=True)
    (root / 'etc').mkdir()
    (root / 'etc/a').write_text('old\n')
    (rejected / 'a').write_text('new\n')
    # Avoid a pager taking ownership of the input terminal.
    (root / 'etc/rejmerge.conf').write_text('more() { cat; }\n')
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)

    def terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    child = subprocess.Popen(['/tmp/rejmerge', '-r', str(root)],
                             stdin=slave, stdout=slave, stderr=slave,
                             preexec_fn=terminal)
    output = b''
    deadline = time.monotonic() + 8
    try:
        while b'[S]kip? ' not in output:
            if time.monotonic() > deadline:
                raise AssertionError((case, 'prompt timeout', output))
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 65536)
        # Prompt output precedes the stty call; wait for the actual mode.
        while termios.tcgetattr(slave)[3] & termios.ICANON:
            if time.monotonic() > deadline:
                raise AssertionError((case, 'terminal never entered key mode'))
            time.sleep(0.01)
        action(master, child)
        status = child.wait(timeout=5)
        assert status == (0 if case == 'single-key' else 1), (case, status)
        assert termios.tcgetattr(slave) == before, (case, 'terminal not restored')
        assert (root / 'etc/a').read_text() == 'old\n'
        assert (rejected / 'a').read_text() == 'new\n'
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        os.close(master)
        os.close(slave)


run('single-key', lambda master, child: os.write(master, b's'))
run('eof', lambda master, child: os.write(master, b'\x04'))
run('interrupt', lambda master, child: os.write(master, b'\x03'))
run('terminate', lambda master, child: os.killpg(child.pid, signal.SIGTERM))
run('terminate-parent', lambda master, child: child.send_signal(signal.SIGTERM))
print('PASS: rejmerge PTY single-key, EOF, signals and terminal restoration')
PY
