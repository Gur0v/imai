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
def worker_loss(case, worker_signal):
    root = pathlib.Path('/tmp') / case
    rejected = root / 'var/lib/pkg/rejected/etc'
    rejected.mkdir(parents=True)
    (root / 'etc').mkdir()
    (root / 'etc/a').write_text('old\n')
    (rejected / 'a').write_text('new\n')
    (root / 'etc/rejmerge.conf').write_text('''
more() {
    printf '%s\\n' "$TMPFILE" > "$REJMERGE_ROOT/temp-path"
    printf 'CALLBACK-WAIT\\n'
    read -r ignored </dev/tty
}
atexit() {
    printf 'cleanup\\n' > "$REJMERGE_ROOT/cleanup"
    rm -f "$TMPFILE"
    rm -rf "$work"
}
''')
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)

    def terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    child = subprocess.Popen(['/tmp/rejmerge', '-r', str(root)],
                             stdin=slave, stdout=slave, stderr=slave,
                             preexec_fn=terminal)
    output = b''
    try:
        deadline = time.monotonic() + 8
        while b'CALLBACK-WAIT' not in output:
            if time.monotonic() > deadline:
                raise AssertionError((case, 'callback timeout', output))
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 65536)
        children = pathlib.Path(
            f'/proc/{child.pid}/task/{child.pid}/children').read_text().split()
        assert len(children) == 1, (case, children)
        worker = int(children[0])
        os.kill(worker, worker_signal)
        # Reap notification follows worker exit; do not race its last read end.
        while pathlib.Path(f'/proc/{worker}').exists():
            if time.monotonic() > deadline:
                raise AssertionError((case, 'worker did not exit'))
            time.sleep(0.01)
        os.write(master, b'return\n')
        status = child.wait(timeout=5)
        assert status == 1, (case, status)
        assert termios.tcgetattr(slave) == before, (case, 'terminal not restored')
        assert (root / 'cleanup').read_text() == 'cleanup\n'
        temporary = pathlib.Path((root / 'temp-path').read_text().strip())
        assert not temporary.exists(), (case, 'temporary file leaked')
        assert not temporary.parent.exists(), (case, 'work directory leaked')
        assert (root / 'etc/a').read_text() == 'old\n'
        assert (rejected / 'a').read_text() == 'new\n'
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        os.close(master)
        os.close(slave)


worker_loss('worker-term-callback', signal.SIGTERM)
worker_loss('worker-kill-callback', signal.SIGKILL)
print('PASS: rejmerge PTY single-key, EOF, signals, worker loss and cleanup')
