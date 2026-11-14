#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${INSTALL_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src $(pkg-config --cflags libarchive) \
    "$harness/preflight-regressions.c" src/extraction/install.c src/fs/fs.c src/archive/archive.c \
    $(pkg-config --libs libarchive) -lz -lbz2 -Wl,--wrap=fstatfs -o "$work/check"
# The writable root and procfs mount must share the fixture process namespace.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --tmpfs /tmp --proc /proc --dir /tmp/root --proc /tmp/root/proc \
    --ro-bind "$work/check" /tmp/check \
    --ro-bind "$harness/preflight-regressions.py" /tmp/fixtures.py -- /bin/dash -eu -c '
python3 -I /tmp/fixtures.py
printf original >/tmp/root/victim
/tmp/check /tmp/magic#1.pkg.tar reject
/tmp/check /tmp/plannedmagic#1.pkg.tar reject
/tmp/check /tmp/finalmagic#1.pkg.tar reject
/tmp/check /tmp/plannedfinalmagic#1.pkg.tar reject
[ ! -e /tmp/root/magicfinal ]
/tmp/check /tmp/dirparent#1.pkg.tar extract
[ -d /tmp/root/parent/child ]
printf safe >/tmp/expected
cmp /tmp/expected /tmp/root/parent/child/file
rm -rf /tmp/root/parent
printf old >/tmp/root/parent
if /tmp/check /tmp/regularchild#1.pkg.tar extract; then
    exit 1
fi
[ -f /tmp/root/parent ]
[ ! -e /tmp/root/parent/child ]
rm /tmp/root/parent
ln -s missing /tmp/root/parent
if /tmp/check /tmp/danglingdir#1.pkg.tar extract; then
    exit 1
fi
[ -L /tmp/root/parent ]
/tmp/check /tmp/finalcycle#1.pkg.tar extract
[ -d /tmp/root/cycle ]
[ ! -L /tmp/root/cycle ]
printf safe >/tmp/expected
cmp /tmp/expected /tmp/root/cycle/file
for fixture in selfhard aliasselfhard absentsource; do
    /tmp/check /tmp/$fixture#1.pkg.tar partial
done
printf safe >/tmp/expected
cmp /tmp/expected /tmp/root/self/file
cmp /tmp/expected /tmp/root/realself/link/file
cmp /tmp/expected /tmp/root/missinglink/file
[ "$(readlink /tmp/root/selfalias)" = realself ]
/tmp/check /tmp/loop#1.pkg.tar reject
mkdir /tmp/root/real
ln -s real /tmp/root/alias
ln -s /proc /tmp/root/blocked
/tmp/check /tmp/mixed#1.pkg.tar routes
ln -s missing /tmp/root/dangling
/tmp/check /tmp/dangling#1.pkg.tar dangling
/tmp/check /tmp/implicit#1.pkg.tar implicit
mkdir /tmp/root/bad
ln -s /proc /tmp/root/bad/proc
/tmp/check /tmp/failure#1.pkg.tar failure
printf original >/tmp/expected
cmp /tmp/expected /tmp/root/victim
ln -s /proc/self/fd/0 /tmp/root/target
ln -s target /tmp/root/aliaschain
/tmp/check /tmp/livechain#1.pkg.tar reject
cmp /tmp/expected /tmp/root/victim
[ "$(readlink /tmp/root/target)" = /proc/self/fd/0 ]
for fault in error unknown; do
    STATFS_FAULT=$fault /tmp/check /tmp/stalechain#1.pkg.tar reject
    [ "$(readlink /tmp/root/target)" = /proc/self/fd/0 ]
    [ "$(readlink /tmp/root/aliaschain)" = target ]
    cmp /tmp/expected /tmp/root/victim
done
/tmp/check /tmp/stalechain#1.pkg.tar extract
[ -d /tmp/root/target ]
[ "$(readlink /tmp/root/aliaschain)" = target ]
printf safe >/tmp/expected
cmp /tmp/expected /tmp/root/target/file
ln -s relative /tmp/root/relative
ln -s relative /tmp/root/relalias
/tmp/check /tmp/relativechain#1.pkg.tar extract
[ -d /tmp/root/relative ]
cmp /tmp/expected /tmp/root/relative/file
ln -s /proc/self/fd/0 /tmp/root/src
/tmp/check /tmp/stale#1.pkg.tar extract
/tmp/check /tmp/fifo#1.pkg.tar extract
[ -p /tmp/root/pipe ]
/tmp/check /tmp/many#1.pkg.tar extract
/tmp/check /tmp/duplicate#1.pkg.tar extract
python3 -I -c '\''import os; assert os.stat("/tmp/root/d0").st_mtime_ns == 123456789000000000; assert os.stat("/tmp/root/pipe").st_mode & 0o777 == 0o751'\''
'
printf 'PASS: ordered destination preflight, FIFO metadata, and bounded directory descriptors\n'
