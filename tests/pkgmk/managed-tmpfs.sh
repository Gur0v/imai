#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
command=${1:-$root/build/pkgmk}
case $command in /*) ;; *) command=$PWD/$command ;; esac
disk=$(mktemp -d "$root/build/managed-test.XXXXXXXX")
trap 'rm -rf "$disk"' EXIT HUP INT TERM
mkdir "$disk/tmp"
chmod 1777 "$disk/tmp"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --cap-add CAP_SYS_ADMIN \
    --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$disk" /var \
    --ro-bind "$command" /tmp/pkgmk --chdir /tmp -- /bin/dash -eu -c '
mkdir port; cd port
cat >Pkgfile <<"EOF"
name=managed
version=1
release=1
source=()
build() {
    [ "$SRC" = /var/tmp/pkgmk/managed/src ] || return 81
    [ "$(stat -f -c %T "$SRC")" = tmpfs ] || return 82
    mkdir -p "$PKG/usr"
    printf payload >"$PKG/usr/file"
}
EOF
cat >config <<"EOF"
PKGMK_TMPFS=yes
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
PKGMK_IGNORE_FOOTPRINT=yes
PKGMK_NO_STRIP=yes
EOF
/tmp/pkgmk -cf config -f >out 2>err
[ ! -e /var/tmp/pkgmk/managed ]
/tmp/pkgmk -cf config -f -kw >out 2>err
[ -f /var/tmp/pkgmk/managed/pkg/usr/file ]
rm managed#1-1.pkg.tar.gz
if /tmp/pkgmk -cf config >out 2>err; then exit 83; fi
[ -f /var/tmp/pkgmk/managed/pkg/usr/file ]
printf stale >/var/tmp/pkgmk/managed/stale
/tmp/pkgmk -cf config -f -kw >out 2>err
[ ! -e /var/tmp/pkgmk/managed/stale ]
[ -f /var/tmp/pkgmk/managed/pkg/usr/file ]
/tmp/pkgmk -cf config -f >out 2>err
[ ! -e /var/tmp/pkgmk/managed ]
# Legacy and foreign mounts have no recorded ownership and must not be adopted.
mkdir /var/tmp/pkgmk/managed
mount -t tmpfs -o mode=0700 tmpfs /var/tmp/pkgmk/managed
printf unknown >/var/tmp/pkgmk/managed/sentinel
if /tmp/pkgmk -cf config -f >out 2>err; then exit 93; fi
[ "$(cat /var/tmp/pkgmk/managed/sentinel)" = unknown ]
grep -q "manual recovery" err
umount /var/tmp/pkgmk/managed
rmdir /var/tmp/pkgmk/managed
# An active callback has no cwd/open reference to the mounted work.
cp config active-config
cat >>active-config <<"EOF"
build() {
    cd /tmp
    printf ready > /tmp/active-ready
    while [ ! -e /tmp/active-done ]; do sleep .01; done
    mkdir -p "$PKG/usr"
    printf payload >"$PKG/usr/file"
}
EOF
/tmp/pkgmk -cf active-config -f >active-out 2>active-err &
active=$!
python3 -I -c "import os,time; end=time.monotonic()+5
while not os.path.exists(\"/tmp/active-ready\"):
    assert time.monotonic()<end
    time.sleep(.01)"
if /tmp/pkgmk -cf config -f >out 2>err; then exit 94; fi
grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
printf done >/tmp/active-done
wait "$active"
[ ! -e /var/tmp/pkgmk/managed ]
# Native-parent death must not allow reclaim while its controller is alive.
rm /tmp/active-ready /tmp/active-done
printf "printf '\''%%s\\n'\'' \"\$\$\" > /tmp/orphan-controller\n" >>active-config
/tmp/pkgmk -cf active-config -f >active-out 2>active-err &
active=$!
python3 -I -c "import os,time; end=time.monotonic()+5
while not os.path.exists(\"/tmp/active-ready\"):
    assert time.monotonic()<end
    time.sleep(.01)"
kill -KILL "$active"
wait "$active" || :
if /tmp/pkgmk -cf config -f >out 2>err; then exit 96; fi
grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
kill -KILL "$(cat /tmp/orphan-controller)"
umount /var/tmp/pkgmk/managed
rmdir /var/tmp/pkgmk/managed
cp config base-config
for failure in recipe extraction footprint checksum signature; do
    cp base-config config
    case $failure in
    recipe) printf "build() { printf retained >\"\$SRC/sentinel\"; return 42; }\n" >>config ;;
    extraction) printf "unpack_source() { printf retained >\"\$SRC/sentinel\"; exit 47; }\n" >>config ;;
    footprint) printf "PKGMK_IGNORE_FOOTPRINT=no\ncheck_footprint() { exit 43; }\n" >>config ;;
    checksum) printf "PKGMK_IGNORE_MD5SUM=no\ncheck_md5sum() { exit 44; }\n" >>config ;;
    signature) printf "PKGMK_IGNORE_SIGNATURE=no\ncheck_signature() { exit 45; }\n" >>config ;;
    esac
    status=0
    /tmp/pkgmk -cf config -f >out 2>err || status=$?
    case $failure in
    recipe) [ "$status" -eq 1 ] ;;
    extraction) [ "$status" -eq 47 ] ;;
    footprint) [ "$status" -eq 43 ] ;;
    checksum) [ "$status" -eq 44 ] ;;
    signature) [ "$status" -eq 45 ] ;;
    esac
    if [ "$failure" = recipe ] || [ "$failure" = extraction ]; then
        grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
        grep -q "Retained work directory" err
        umount /var/tmp/pkgmk/managed
        rmdir /var/tmp/pkgmk/managed
    else
        [ ! -e /var/tmp/pkgmk/managed ]
        ! grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
        ! grep -q "Retained work directory" err
        [ "$failure" != footprint ] || [ -f managed#1-1.pkg.tar.gz ]
        if /tmp/pkgmk -cf config -f -kw >out 2>err; then exit 91; fi
        grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
        umount /var/tmp/pkgmk/managed
        rmdir /var/tmp/pkgmk/managed
    fi
done
for signal in KILL TERM; do
    cp base-config config
    cat >>config <<"EOF"
PKGMK_IGNORE_MD5SUM=no
check_md5sum() {
    printf "%s\n" "$$" >controller-pid
    printf retained >"$SRC/sentinel"
    while :; do :; done
}
EOF
    rm -f controller-pid
    /tmp/pkgmk -cf config -f >out 2>err &
    parent=$!
    python3 -I -c "import os,time; end=time.monotonic()+5
while not os.path.exists(\"controller-pid\"):
    assert time.monotonic()<end
    time.sleep(.01)"
    kill -"$signal" "$(cat controller-pid)"
    if wait "$parent"; then exit 92; fi
    grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
    [ "$(cat /var/tmp/pkgmk/managed/src/sentinel)" = retained ]
    grep -q "Retained work directory" err
    if /tmp/pkgmk -cf base-config -f >out 2>err; then exit 97; fi
    grep -q "manual recovery" err
    [ "$(cat /var/tmp/pkgmk/managed/src/sentinel)" = retained ]
    umount /var/tmp/pkgmk/managed
    rmdir /var/tmp/pkgmk/managed
done
cp base-config config
mkdir /tmp/outside
printf sentinel >/tmp/outside/sentinel
printf "build() { PKGMK_WORK_DIR=/tmp/outside; return 46; }\n" >>config
if /tmp/pkgmk -cf config -f >out 2>err; then exit 89; fi
[ "$(cat /tmp/outside/sentinel)" = sentinel ]
grep -q "Retained work directory.*managed" err
umount /var/tmp/pkgmk/managed
rmdir /var/tmp/pkgmk/managed
cp base-config config
/tmp/pkgmk -cf config -eo >out 2>err
grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
umount /var/tmp/pkgmk/managed
rmdir /var/tmp/pkgmk/managed
printf "name=../unsafe\n" >>config
if /tmp/pkgmk -cf config -f >out 2>err; then exit 85; fi
[ ! -e /var/tmp/unsafe ]
cp base-config config
rm -f /var/tmp/pkgmk/.state/managed
rmdir /var/tmp/pkgmk/.state
rmdir /var/tmp/pkgmk
ln -s /tmp /var/tmp/pkgmk
if /tmp/pkgmk -cf config -f >out 2>err; then exit 86; fi
rm /var/tmp/pkgmk
mkdir -m 755 /var/tmp/pkgmk
if /tmp/pkgmk -cf config -f >out 2>err; then exit 87; fi
rmdir /var/tmp/pkgmk
# A live descendant keeps ordinary unmount busy; no lazy detach is allowed.
cp base-config config
cat >>config <<"EOF"
build() {
    mkdir -p "$PKG/usr"
    printf payload >"$PKG/usr/file"
    (cd "$SRC"; exec 61>&- 62>&- 63>&-; exec sleep 60) >/dev/null 2>&1 &
    printf "%s\n" "$!" >"$PKGMK_ROOT/holder"
}
EOF
if /tmp/pkgmk -cf config -f >out 2>err; then exit 88; fi
grep -q "cannot release managed" err
grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
[ -f /var/tmp/pkgmk/managed/pkg/usr/file ]
cp base-config config
if /tmp/pkgmk -cf config -f >out 2>err; then exit 95; fi
[ -f /var/tmp/pkgmk/managed/pkg/usr/file ]
grep -q " /var/tmp/pkgmk/managed " /proc/self/mountinfo
kill "$(cat holder)"
# Wait for the holder to release its cwd before explicit test cleanup.
python3 -I -c "import os,time; p=int(open(\"holder\").read()); end=time.monotonic()+5
while os.path.exists(\"/proc/%d/cwd\"%p):
    assert time.monotonic()<end
    time.sleep(.01)"
umount /var/tmp/pkgmk/managed
rmdir /var/tmp/pkgmk/managed
'
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --cap-drop ALL \
    --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$disk" /var \
    --ro-bind "$command" /tmp/pkgmk --chdir /tmp -- /bin/dash -eu -c '
cat >Pkgfile <<"EOF"
name=denied
version=1
release=1
source=()
build() { :; }
EOF
printf "PKGMK_TMPFS=yes\n" >config
if /tmp/pkgmk -cf config -eo >out 2>err; then exit 90; fi
[ ! -e /var/tmp/pkgmk/denied ]
[ ! -e work ]
grep -q "managed work directory" err
'
