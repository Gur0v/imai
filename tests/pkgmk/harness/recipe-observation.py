# SPDX-License-Identifier: GPL-3.0-or-later
import concurrent.futures
import pathlib
import subprocess
import time

root = pathlib.Path('/tmp/observations')
root.mkdir()
base = '''PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
PKGMK_IGNORE_FOOTPRINT=yes
PKGMK_NO_STRIP=yes
'''


def port(label, body, settings=''):
    path = root / label
    path.mkdir()
    (path / 'logs').mkdir()
    (path / 'Pkgfile').write_text('name=observe\nversion=1\nrelease=1\nsource=()\nbuild() {\n' + body + '\n}\n')
    (path / 'config').write_text(base + settings)
    return path


def run(path, args=(), data=b''):
    return subprocess.run(['/tmp/pkgmk', '-cf', 'config', '-f', *args], cwd=path,
                          input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=20)


def logs(path):
    return list((path / 'logs').iterdir())


for log in (False, True):
    for timing in (False, True):
        path = port(f'options-{log}-{timing}', 'printf OUT; printf ERR >&2; mkdir -p "$PKG/usr"; : >"$PKG/usr/file"',
                    f'PKGMK_LOG_DIR={"logs" if log else ""}\nPKGMK_BUILD_TIME={"yes" if timing else "no"}\n')
        result = run(path)
        assert result.returncode == 0, result.stderr
        assert bool(logs(path)) == log
        assert (b'Recipe elapsed:' in result.stderr) == timing
        if log:
            transcript = logs(path)[0].read_bytes()
            assert b'OUT' in transcript and b'ERR' in transcript
            assert logs(path)[0].stat().st_mode & 0o777 == 0o600

path = port('noisy', '''set +x
read -r answer
[[ $answer == supplied ]]
python3 -I -c 'import os; os.write(1,b"A"*262144+b"\\0ENDOUT"); os.write(2,b"B"*262144+b"\\0ENDERR")'
mkdir -p "$PKG/usr"; : >"$PKG/usr/file"''', 'PKGMK_LOG_DIR=logs\nPKGMK_BUILD_TIME=yes\n')
result = run(path, data=b'supplied\n')
assert result.returncode == 0, result.stderr[-2000:]
transcript = logs(path)[0].read_bytes()
for stream, byte, tail in ((result.stdout, b'A', b'\0ENDOUT'), (result.stderr, b'B', b'\0ENDERR')):
    payload = byte * 262144 + tail
    assert payload in stream
    assert transcript.count(tail) == 1
    assert transcript.count(byte) == 262144
assert len(transcript) == 2 * 262144 + len(b'\0ENDOUT\0ENDERR') + len(b'+ build\n+ set +x\n')

for body in ('false\nprintf SENTINEL', 'exit 37'):
    path = port('failure-' + str(len(list(root.iterdir()))), body,
                'PKGMK_LOG_DIR=logs\nPKGMK_BUILD_TIME=yes\n')
    result = run(path)
    assert result.returncode == 1, result.returncode
    assert b'SENTINEL' not in result.stdout
    assert result.stderr.count(b'Recipe elapsed:') == 1
    assert logs(path)

for setting in ('PKGMK_LOG_DIR=missing\n', 'PKGMK_LOG_DIR=/proc\n'):
    path = port('bad-dir-' + str(len(list(root.iterdir()))), 'mkdir -p "$PKG/usr"; : >"$PKG/usr/file"', setting)
    result = run(path)
    assert result.returncode == 0, result.stderr
    assert b'warning: recipe logging unavailable' in result.stderr
    assert not logs(path)

path = port('invalid-time', ':', 'PKGMK_BUILD_TIME=invalid\n')
result = run(path)
assert result.returncode == 1 and b'must be yes or no' in result.stderr

for option in ('-do', '-eo', '-utd'):
    path = port('skip-' + option[1:], 'exit 99', 'PKGMK_LOG_DIR=logs\nPKGMK_BUILD_TIME=yes\n')
    result = run(path, (option,))
    assert result.returncode == 0, result.stderr
    assert not logs(path) and b'Recipe elapsed:' not in result.stderr

path = port('live', '''printf LIVEOUT; printf LIVEERR >&2
while [[ ! -f "$PKGMK_ROOT/release" ]]; do sleep 0.05; done
mkdir -p "$PKG/usr"; : >"$PKG/usr/file"''', 'PKGMK_LOG_DIR=logs\n')
with (path / 'out').open('wb') as out, (path / 'err').open('wb') as err:
    process = subprocess.Popen(['/tmp/pkgmk', '-cf', 'config', '-f'], cwd=path, stdout=out, stderr=err)
    try:
        deadline = time.monotonic() + 10
        while b'LIVEOUT' not in (path / 'out').read_bytes() or b'LIVEERR' not in (path / 'err').read_bytes():
            assert process.poll() is None
            assert time.monotonic() < deadline
            time.sleep(0.02)
        assert process.poll() is None
        (path / 'release').touch()
        assert process.wait(timeout=10) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

path = port('background', '''sleep 10 &
mkdir -p "$PKG/usr"; : >"$PKG/usr/file"''', 'PKGMK_LOG_DIR=logs\n')
started = time.monotonic()
result = run(path)
assert result.returncode == 0
assert time.monotonic() - started < 8

shared = root / 'shared'
shared.mkdir()
paths = [port('concurrent-' + str(i), 'mkdir -p "$PKG/usr"; : >"$PKG/usr/file"', f'PKGMK_LOG_DIR={shared}\n') for i in range(4)]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    assert all(result.returncode == 0 for result in executor.map(run, paths))
assert len(list(shared.iterdir())) == 4
path = port('later-capture', '''if [[ -f "$PKGMK_ROOT/first" ]]; then printf SECOND; else touch "$PKGMK_ROOT/first"; printf FIRST; fi
mkdir -p "$PKG/usr"; : >"$PKG/usr/file"''',
            'PKGMK_LOG_DIR=logs\nPKGMK_BUILD_TIME=yes\nPKGMK_INSTALL=install\ninstall_package() { build_package; }\n')
result = run(path)
assert result.returncode == 0, result.stderr
assert len(logs(path)) == 1
assert b'SECOND' in result.stdout and b'SECOND' not in logs(path)[0].read_bytes()
assert result.stderr.count(b'Recipe elapsed:') == 2
assert b'skipping separate recipe log' in result.stderr

path = port('nested', '''if [[ ${nested-no} == no ]]; then nested=yes; build_package; else printf NESTED; fi
mkdir -p "$PKG/usr"; : >"$PKG/usr/file"''', 'PKGMK_LOG_DIR=logs\nPKGMK_BUILD_TIME=yes\n')
result = run(path)
assert result.returncode == 0, result.stderr
assert len(logs(path)) == 1 and b'NESTED' in logs(path)[0].read_bytes()
assert result.stderr.count(b'Recipe elapsed:') == 2
assert b'skipping separate recipe log' in result.stderr

path = port('live-failure', '''python3 -I -c 'import os;\nfor _ in range(1000): os.write(1,b"X"*8192)'
printf SENTINEL >"$PKGMK_ROOT/sentinel"''', 'PKGMK_LOG_DIR=logs\n')
with (path / 'err').open('wb') as err:
    process = subprocess.Popen(['/tmp/pkgmk', '-cf', 'config', '-f'], cwd=path,
                               stdout=subprocess.PIPE, stderr=err)
    process.stdout.close()
    assert process.wait(timeout=20) != 0
assert not (path / 'sentinel').exists()

path = port('set-e', 'false\nprintf SENTINEL', 'set -e\nPKGMK_LOG_DIR=logs\nPKGMK_BUILD_TIME=yes\n')
result = run(path)
assert result.returncode != 0
assert result.stderr.count(b'Recipe elapsed:') == 1
assert b'SENTINEL' not in result.stdout

path = port('override', ':', 'PKGMK_LOG_DIR=logs\nPKGMK_BUILD_TIME=yes\nnative_recipe_build() { printf OVERRIDE; mkdir -p "$PKG/usr"; : >"$PKG/usr/file"; }\n')
result = run(path)
assert result.returncode == 0 and b'OVERRIDE' in result.stdout
assert b'OVERRIDE' not in logs(path)[0].read_bytes()
assert result.stderr.count(b'Recipe elapsed:') == 1

path = port('redirect-failure', 'printf RESTORED; mkdir -p "$PKG/usr"; : >"$PKG/usr/file"',
            '''PKGMK_LOG_DIR=logs
function /tmp/pkgmk() { command /tmp/pkgmk "$@"; local status=$?; if [[ ${2-} == check-capture ]]; then touch "$PKGMK_ROOT/validated"; exec 62>&-; fi; return "$status"; }
''')
result = run(path)
assert result.returncode == 0 and b'RESTORED' in result.stdout, result.stderr
assert (path / 'validated').exists()
assert b'RESTORED' not in logs(path)[0].read_bytes(), logs(path)[0].read_bytes()
assert b'capture descriptors unavailable' in result.stderr

path = port('readonly-fd', 'printf READONLY; mkdir -p "$PKG/usr"; : >"$PKG/usr/file"',
            'PKGMK_LOG_DIR=logs\nexec 61</proc/self/fd/61\n')
result = run(path)
assert result.returncode == 0 and b'READONLY' in result.stdout, result.stderr
assert b'READONLY' not in logs(path)[0].read_bytes()
assert b'capture descriptors unavailable' in result.stderr

path = port('replaced-fd', 'printf ORIGINAL; mkdir -p "$PKG/usr"; : >"$PKG/usr/file"',
            'PKGMK_LOG_DIR=logs\nexec 61>replaced\n')
result = run(path)
assert result.returncode == 0 and b'ORIGINAL' in result.stdout
assert (path / 'replaced').read_bytes() == b''
assert b'capture descriptors unavailable' in result.stderr

path = port('caller-fd', 'printf preserved >&61; mkdir -p "$PKG/usr"; : >"$PKG/usr/file"')
with (path / 'inherited').open('wb') as inherited:
    result = subprocess.run(['/bin/bash', '-c', 'exec 61>inherited; exec /tmp/pkgmk -cf config -f'], cwd=path,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
assert result.returncode == 0, result.stderr
assert (path / 'inherited').read_bytes() == b'preserved'
print('PASS: recipe observation option, bytes, live, stdin, status, directory, background, concurrent and caller-fd checks')
