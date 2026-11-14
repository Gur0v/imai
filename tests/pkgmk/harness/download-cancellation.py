# SPDX-License-Identifier: GPL-3.0-or-later
import http.server
import os
import pathlib
import pty
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time


class Server(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(100 * 1024 * 1024))
        self.end_headers()
        self.wfile.write(b'x' * 65536)
        self.wfile.flush()
        self.server.ready.set()
        self.server.release.wait(30)

    def log_message(self, *_args):
        pass


# Exercise the private runner without the controller or a real downloader.
for case in ('truncated', 'unterminated', 'ignored', 'registration'):
    left, right = socket.socketpair()
    def setup():
        os.dup2(right.fileno(), 63)
        if case == 'ignored':
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGQUIT, signal.SIG_IGN)
    code = ('import signal; assert signal.getsignal(signal.SIGINT) == signal.SIG_IGN; '
            'assert signal.getsignal(signal.SIGQUIT) == signal.SIG_IGN')
    if case in ('truncated', 'unterminated'):
        code = "import pathlib; pathlib.Path('/tmp/unacked-backend').touch()"
    process = subprocess.Popen([sys.argv[1], '--imai-internal', 'download-run',
                                sys.executable, '-I', '-c', code if case != 'registration' else 'pass'],
                               preexec_fn=setup, close_fds=False)
    right.close()
    left.settimeout(4)
    def field():
        value = bytearray()
        while True:
            byte = left.recv(1)
            assert byte, (case, value, process.poll())
            if byte == b'\0':
                return bytes(value)
            value.extend(byte)
    try:
        assert [field() for _ in range(3)] == [b'RUN', b'download-runner', b'1']
        assert int(field()) == process.pid
        if case in ('truncated', 'unterminated'):
            left.sendall(b'R\0' + b'0\0' + (b'partial' if case == 'unterminated' else b''))
            left.shutdown(socket.SHUT_WR)
            assert process.wait(timeout=4) != 0, 'unacked runner succeeded'
            assert not pathlib.Path('/tmp/unacked-backend').exists(), 'unacked backend ran'
            print('private runner truncated reply: PASS', flush=True)
            continue
        left.sendall(b'R\0' + b'0')
        if case == 'registration':
            os.kill(process.pid, signal.SIGTERM)
            time.sleep(0.05)
        left.sendall(b'\0\0')
        assert [field() for _ in range(4)] == [b'RUN', b'download-runner', b'1', b'0']
        left.sendall(b'R\0' + b'0\0\0')
        assert process.wait(timeout=4) == (143 if case == 'registration' else 0), case
        print('private runner ' + case + ': PASS', flush=True)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        left.close()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Server)
server.daemon_threads = True
server.ready = threading.Event()
server.release = threading.Event()
threading.Thread(target=server.serve_forever, daemon=True).start()
for mode in ('parent-term', 'parent-int', 'terminal'):
    server.ready.clear()
    with tempfile.TemporaryDirectory() as work:
        root = pathlib.Path(work)
        (root / 'Pkgfile').write_text(
            f'name=cancel\nversion=1\nrelease=1\nsource=(http://127.0.0.1:{server.server_port}/payload)\nbuild() {{ :; }}\n')
        (root / 'config').write_text('PKGMK_DOWNLOAD_PROG=aria2c\nPKGMK_ARIA2_OPTS="--summary-interval=0 --disk-cache=0"\n')
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(work)
            os.execv(sys.argv[1], [sys.argv[1], '-cf', 'config', '-do'])
        output = bytearray()
        status = None
        try:
            assert server.ready.wait(8), mode + ': no request'
            # Wait until the real backend has persisted partial bytes.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                partial = root / 'payload.partial'
                if partial.exists() and partial.stat().st_size > 0:
                    break
                select.select([], [], [], 0.02)
            before = partial.read_bytes()
            assert before and before == b'x' * len(before), (mode, len(before))
            if mode == 'terminal':
                os.write(fd, b'\x03')
            else:
                os.kill(pid, signal.SIGTERM if mode == 'parent-term' else signal.SIGINT)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        output.extend(os.read(fd, 65536))
                    except OSError:
                        pass
                done, value = os.waitpid(pid, os.WNOHANG)
                if done:
                    status = os.waitstatus_to_exitcode(value)
                    break
            assert status == 1, (mode, status, output.decode(errors='replace'))
            after = partial.read_bytes()
            assert after.startswith(before) and after == b'x' * len(after), mode + ': damaged partial'
            assert not (root / 'payload').exists(), mode + ': published incomplete download'
            if mode != 'parent-term':
                assert b'Emergency shutdown' not in output, output
            survivors = []
            for entry in pathlib.Path('/proc').iterdir():
                if entry.name.isdigit():
                    try:
                        if os.getsid(int(entry.name)) == pid:
                            survivors.append(entry.name)
                    except ProcessLookupError:
                        pass
            assert not survivors, (mode, survivors)
            print(mode + ': PASS', flush=True)
        finally:
            for entry in pathlib.Path('/proc').iterdir():
                if entry.name.isdigit():
                    try:
                        if os.getsid(int(entry.name)) == pid:
                            os.kill(int(entry.name), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if status is None:
                os.waitpid(pid, 0)
            os.close(fd)
server.release.set()
server.shutdown()

# A configured function must retain dynamic scope, stdin and persistent shell state.
with tempfile.TemporaryDirectory() as work:
    root = pathlib.Path(work)
    (root / 'Pkgfile').write_text('name=context\nversion=1\nrelease=1\nsource=(http://unused/payload)\nbuild() { :; }\n')
    (root / 'config').write_text('''PKGMK_DOWNLOAD_PROG=curl
curl() {
    test "$PWD" = "$PKGMK_ROOT" || exit 91
    test "$LOCAL_FILENAME_PARTIAL" = "$PWD/payload.partial" || exit 92
    read -r token
    test "$token" = input-token || exit 93
    CONTEXT=retained
    printf payload > "$LOCAL_FILENAME_PARTIAL"
}
info() { if [[ $1 == *"up to date"* ]]; then test "$CONTEXT" = retained || exit 94; fi; }
''')
    result = subprocess.run([sys.argv[1], '-cf', 'config', '-do'], cwd=work,
                            input=b'input-token\n', capture_output=True, timeout=8)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    assert (root / 'payload').read_bytes() == b'payload'
    print('configured function context: PASS', flush=True)

# An inherited ignored SIGINT must remain ignored across both native execs.
with tempfile.TemporaryDirectory() as work:
    root = pathlib.Path(work)
    (root / 'Pkgfile').write_text('name=ignored\nversion=1\nrelease=1\nsource=(http://unused/payload)\nbuild() { :; }\n')
    (root / 'config').write_text(f'PKGMK_DOWNLOAD_PROG=curl\nPATH="{work}:$PATH"\n')
    backend = root / 'curl'
    backend.write_text(f'''#!{sys.executable}
import pathlib,signal,sys
pathlib.Path('ignored').write_text(str(signal.getsignal(signal.SIGINT) == signal.SIG_IGN))
pathlib.Path(sys.argv[sys.argv.index('-o')+1]).write_bytes(b'payload')
''')
    backend.chmod(0o755)
    result = subprocess.run([sys.argv[1], '-cf', 'config', '-do'], cwd=work,
                            preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_IGN),
                            capture_output=True, timeout=8)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert (root / 'ignored').read_text() == 'True', 'inherited ignored SIGINT reset'
    print('inherited ignored SIGINT: PASS', flush=True)
