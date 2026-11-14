#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
command=${1:-$root/build/pkgmk}
case $command in /*) ;; *) command=$PWD/$command ;; esac
# Trusted executable configurations run only in the disposable filesystem.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --cap-add CAP_SYS_ADMIN --ro-bind / / --dev /dev --proc /proc \
    --tmpfs /tmp --tmpfs /var --dir /var/tmp --ro-bind "$command" /tmp/pkgmk --chdir /tmp -- /bin/dash -eu -c '
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
for option in -i -u; do
    cat >config <<"EOF"
set -e
build_needed() { printf "no\n"; }
pkgadd() { printf "pkgadd-before\n"; false; printf "pkgadd-after\n"; return 42; }
EOF
    if /tmp/pkgmk -cf config "$option" >out 2>err; then exit 1; else [ "$?" = 1 ]; fi
    grep -q "^pkgadd-before$" out
    if grep -q "^pkgadd-after$" out; then exit 1; fi
    if grep -q "Installing .* failed" err; then exit 1; fi
    cat >config <<"EOF"
set +e
build_needed() { printf "no\n"; }
pkgadd() { printf "pkgadd-before\n"; false; printf "pkgadd-after\n"; return 42; }
EOF
    if /tmp/pkgmk -cf config "$option" >out 2>err; then exit 1; else [ "$?" = 1 ]; fi
    grep -q "^pkgadd-before$" out
    grep -q "^pkgadd-after$" out
    grep -q "Installing .* failed" err
    cat >config <<"EOF"
set -e
build_needed() { printf "no\n"; }
pkgadd() { printf "pkgadd-success\n"; }
EOF
    /tmp/pkgmk -cf config "$option" >out 2>err
    grep -q "^pkgadd-success$" out
    grep -q "Installing .* succeeded" out
    [ ! -s err ]
done
cat >config <<"EOF"
PKGMK_TMPFS=yes
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
unpack_source() {
    [[ $PKGMK_WORK_DIR == /var/tmp/pkgmk/workflow && $PKGMK_WORK_DIR != "$PKGMK_ROOT/work" ]] || exit 98
    [[ $(stat -c %a "$PKGMK_WORK_DIR") == 700 ]] || exit 99
    printf "%s\n" "$PKGMK_WORK_DIR" >selected
}
EOF
/tmp/pkgmk -cf config -eo >out 2>err
selected=$(cat selected)
[ -d "$selected/src" ]
umount "$selected"
rmdir "$selected"
cat >config <<"EOF"
PKGMK_TMPFS=yes
PKGMK_WORK_DIR="$PKGMK_ROOT/work"
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
PKGMK_IGNORE_FOOTPRINT=yes
PKGMK_NO_STRIP=yes
build() {
    [[ $PKGMK_WORK_DIR == /var/tmp/pkgmk/workflow ]] || exit 98
    [[ $PKGMK_SOURCE_DIR == "$PKGMK_ROOT" && $PKGMK_PACKAGE_DIR == "$PKGMK_ROOT" ]] || exit 99
    printf "%s\n" "$PKGMK_WORK_DIR" >"$PKGMK_ROOT/selected"
    printf "int main(void) { return 0; }\n" >probe.c
    cc probe.c -o probe
    ./probe
    printf payload >"$PKG/payload"
}
EOF
/tmp/pkgmk -cf config -f >out 2>err
selected=$(cat selected)
[ ! -e "$selected" ]
[ -f workflow#1-1.pkg.tar.gz ]
bsdtar -xOf workflow#1-1.pkg.tar.gz payload >payload
[ "$(cat payload)" = payload ]
/tmp/pkgmk -cf config -f -kw >out 2>err
selected=$(cat selected)
[ -d "$selected/src" ]
[ "$(stat -c %a "$selected")" = 700 ]
umount "$selected"
rmdir "$selected"
printf "build() { false; }\n" >>config
if /tmp/pkgmk -cf config -f >out 2>err; then exit 1; fi
umount /var/tmp/pkgmk/workflow
rmdir /var/tmp/pkgmk/workflow
# No allocation in no-work mode, even with an unusable custom location.
printf "PKGMK_WORK_DIR=/sys/absent/work\nbuild_needed() { printf no; }\n" >>config
/tmp/pkgmk -cf config -utd >out 2>err
if grep -q "Using tmpfs" out; then exit 1; fi
cat >config <<"EOF"
set +e
PKGMK_TMPFS=yes
PKGMK_WORK_DIR=/tmp/custom-work
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
unpack_source() { [[ $SRC == /tmp/custom-work/src ]] || exit 98; }
EOF
/tmp/pkgmk -cf config -eo >out 2>err
[ -d /tmp/custom-work/src ]
/tmp/pkgmk -cf config -eo >out 2>err
[ -d /tmp/custom-work/src ]
rm -rf /tmp/custom-work
printf "PKGMK_WORK_DIR=/sys/absent/work\n" >>config
if /tmp/pkgmk -cf config -eo >out 2>err; then exit 1; fi
grep -q "tmpfs directory" err
cat >config <<"EOF"
PKGMK_TMPFS=yes
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
unpack_source() {
    : >"$SRC/stale"
    make_work_dir
    exit 98
}
EOF
if /tmp/pkgmk -cf config -eo >out 2>err; then exit 1; fi
[ -f /var/tmp/pkgmk/workflow/src/stale ]
umount /var/tmp/pkgmk/workflow
rmdir /var/tmp/pkgmk/workflow
printf "PKGMK_TMPFS=invalid\n" >config
if /tmp/pkgmk -cf config -utd >out 2>err; then exit 1; fi
grep -q PKGMK_TMPFS err
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
pathlib.Path("ready").unlink()
pathlib.Path("selected").unlink(missing_ok=True)
config.write_text("PKGMK_TMPFS=yes\nPKGMK_IGNORE_SIGNATURE=yes\nPKGMK_IGNORE_MD5SUM=yes\nbuild() { printf \"%s\\n\" \"$PKGMK_WORK_DIR\" >\"$PKGMK_ROOT/selected\"; : >\"$PKGMK_ROOT/ready\"; while :; do :; done; }\n")
p = subprocess.Popen(["/tmp/pkgmk", "-cf", "config", "-f"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
try:
    deadline = time.monotonic() + 5
    while not pathlib.Path("ready").exists():
        assert time.monotonic() < deadline
        time.sleep(.01)
    import os
    os.killpg(p.pid, signal.SIGTERM)
    out, err = p.communicate(timeout=5)
    assert p.returncode == 1, (p.returncode, out, err)
    assert b"Interrupted." in err, err
    assert pathlib.Path(pathlib.Path("selected").read_text().strip()).is_dir()
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
PY
'
printf 'PASS: native pkgmk workflow callbacks, state, sourcing and reentrancy\n'
