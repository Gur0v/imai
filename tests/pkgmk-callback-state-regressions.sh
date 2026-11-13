#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
command=${1:-$root/build/pkgmk}
case $command in /*) ;; *) command=$PWD/$command ;; esac
# Trusted executable configurations run only in the disposable filesystem.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --dev /dev --proc /proc \
    --tmpfs /tmp --ro-bind "$command" /tmp/pkgmk --chdir /tmp -- /bin/dash -eu -c '
mkdir port
cd port
cat >Pkgfile <<"EOF"
name=workflow
version=1
release=1
source=()
build() { :; }
printf "recipe output\n"
EOF
cat >config <<"EOF"
printf "config output\n"
[[ $FILE == config && -z $TARGET ]] || exit 90
[[ $PKGMK_NATIVE_WORKFLOW == 1 ]] || exit 91
state=before
check_directory() { [[ $state == before ]] || exit 92; }
download_source() { state=downloaded; printf "download callback\n"; }
make_md5sum() { [[ $state == downloaded ]] || exit 93; printf "%s\n" "$TARGET"; }
EOF
/tmp/pkgmk -cf config -um >out 2>err
[ ! -s err ]
printf "recipe output\nconfig output\ndownload callback\n=======> Md5sum updated.\n" >expected
cmp expected out
printf "/tmp/port/workflow#1-1.pkg.tar.gz\n" >expected
cmp expected .md5sum
cat >config <<"EOF"
[[ $PKGMK_NATIVE_WORKFLOW == 1 ]] || exit 91
check_directory() { :; }
state=before
build_needed() { printf "yes\n"; }
download_source() {
    parse_options -kw
    [[ $PKGMK_KEEP_WORK == yes ]] || exit 94
    state=after
}
build_package() { [[ $state == after ]] || exit 95; printf "built:%s\n" "$TARGET"; }
EOF
/tmp/pkgmk -cf config >out 2>err
grep -q "built:/tmp/port/workflow#1-1.pkg.tar.gz" out
cat >config <<"EOF"
main() { exit 39; }
exit 37
EOF
if /tmp/pkgmk -cf config >out 2>err; then exit 1; else [ "$?" = 37 ]; fi
cat >config <<"EOF"
PKGMK_IGNORE_SIGNATURE=yes
make_md5sum() { printf "md5 precedence\n"; }
make_signature() { exit 96; }
EOF
/tmp/pkgmk -cf config -um -us >out 2>err
grep -q "md5 precedence" .md5sum
cat >config <<"EOF"
set -e
PKGMK_IGNORE_MD5SUM=yes
check_signature() { false; printf "signature-continued\n"; return 0; }
EOF
/tmp/pkgmk -cf config -eo >out 2>err
grep -q signature-continued out
cat >config <<"EOF"
set -e
build_needed() { printf "no\n"; return 7; }
EOF
/tmp/pkgmk -cf config -utd >out 2>err
grep -q "is up to date" out
cat >config <<"EOF"
set -e
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
bsdtar() { return 42; }
EOF
if /tmp/pkgmk -cf config -f >out 2>err; then exit 1; else [ "$?" = 1 ]; fi
[ ! -d work ]
grep -q "Building .* failed" err
cat >config <<"EOF"
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
PKGMK_IGNORE_FOOTPRINT=yes
strip_files() { [[ $build_status == 0 ]] || exit 97; }
unpack_source() { TARGET=/tmp/changed-target; }
build() { printf payload >"$PKG/payload"; }
EOF
/tmp/pkgmk -cf config -f >out 2>err
grep -q "Building .*/tmp/changed-target.* succeeded" out
python3 -I - <<"PY"
import pathlib
import subprocess
import time
import signal
config = pathlib.Path("config")
config.write_text("PKGMK_KEEP_WORK=yes\n: >ready\nwhile :; do :; done\n")
p = subprocess.Popen(["/tmp/pkgmk", "-cf", "config"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    deadline = time.monotonic() + 5
    while not pathlib.Path("ready").exists():
        assert time.monotonic() < deadline
        time.sleep(.01)
    p.send_signal(signal.SIGTERM)
    out, err = p.communicate(timeout=5)
    assert p.returncode == 1, (p.returncode, out, err)
    assert b"Interrupted." in err, err
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
PY
'
printf 'PASS: native pkgmk workflow callbacks, state, sourcing and reentrancy\n'
