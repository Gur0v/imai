#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
candidate=${1:-$PWD/build/pkgrm}
reference=${2:-$PWD/build/reference/pkgrm}
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / --dev /dev \
    --proc /proc \
    --tmpfs /tmp --ro-bind "$candidate" /tmp/bin-new/pkgrm \
    --ro-bind "$reference" /tmp/bin-old/pkgrm -- /bin/dash -eu -c '
for tool in new old; do
    root=/tmp/$tool
    mkdir -p "$root/var/lib/pkg" "$root/usr/dir" "$root/etc"
    printf "alpha\n1\nusr/dir/\nusr/dir/file\nusr/shared\n\nzeta\n2\nusr/shared\n\n" >"$root/var/lib/pkg/db"
    : >"$root/usr/dir/file"
    : >"$root/usr/shared"
    status=0
    /tmp/bin-$tool/pkgrm -r "$root" alpha >"/tmp/$tool.out" 2>"/tmp/$tool.err" || status=$?
    [ "$status" -eq 0 ]
    [ ! -e "$root/usr/dir" ]
    [ -f "$root/usr/shared" ]
    [ ! -s "/tmp/$tool.out" ]
    [ ! -s "/tmp/$tool.err" ]
    printf "zeta\n2\nusr/shared\n\n" >/tmp/expected
    cmp /tmp/expected "$root/var/lib/pkg/db"
    rm "$root/var/lib/pkg/db"
    printf "alpha\n1\nusr/dir/\n\n" >"$root/var/lib/pkg/db"
    mkdir -p "$root/usr/dir"
    : >"$root/usr/dir/unrecorded"
    status=0
    /tmp/bin-$tool/pkgrm -r "$root" alpha >"/tmp/$tool.out" 2>"/tmp/$tool.err" || status=$?
    [ "$status" -eq 0 ]
    [ -f "$root/usr/dir/unrecorded" ]
    [ ! -s "$root/var/lib/pkg/db" ]
    grep "could not remove $root/usr/dir/:" "/tmp/$tool.err" >/dev/null
done
for tool in old new; do
    root=/tmp/spelling-$tool
    mkdir -p "$root/var/lib/pkg" "$root/real/empty"
    printf "alpha\n1\n./real//./file\n./real//empty/\n\nzeta\n2\nreal/file\n\n" >"$root/var/lib/pkg/db"
    : >"$root/real/file"
    /tmp/bin-$tool/pkgrm -r "$root" alpha >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -e "$root/real/file" ]
    [ ! -d "$root/real/empty" ]
    [ ! -s "/tmp/$tool.out" ]
    [ ! -s "/tmp/$tool.err" ]
    printf "zeta\n2\nreal/file\n\n" >/tmp/expected
    cmp /tmp/expected "$root/var/lib/pkg/db"
done
root=/tmp/missing-db
mkdir -p "$root/var/lib/pkg"
for tool in new old; do
    status=0
    /tmp/bin-$tool/pkgrm -r "$root" alpha >"/tmp/$tool.out" 2>"/tmp/$tool.err" || status=$?
    [ "$status" -eq 1 ]
    [ ! -s "/tmp/$tool.out" ]
done
cmp /tmp/new.err /tmp/old.err
rmdir "$root/var/lib/pkg"
for tool in new old; do
    status=0
    /tmp/bin-$tool/pkgrm -r "$root" alpha >"/tmp/$tool.out" 2>"/tmp/$tool.err" || status=$?
    [ "$status" -eq 1 ]
    [ ! -s "/tmp/$tool.out" ]
done
cmp /tmp/new.err /tmp/old.err
root=/tmp/scoped
mkdir -p "$root/inside/lib/pkg" /tmp/inside/lib/pkg
ln -s /tmp/inside "$root/var"
mkdir -p "$root/tmp"
mv "$root/inside" "$root/tmp/inside"
printf "alpha\n1\nvictim\n\n" >"$root/tmp/inside/lib/pkg/db"
printf "outside\n1\nsentinel\n\n" >/tmp/inside/lib/pkg/db
cp /tmp/inside/lib/pkg/db /tmp/outside-db
: >"$root/victim"
/tmp/bin-new/pkgrm -r "$root" alpha >/tmp/scoped.out 2>/tmp/scoped.err
[ ! -e "$root/victim" ]
[ ! -s "$root/tmp/inside/lib/pkg/db" ]
cmp /tmp/outside-db /tmp/inside/lib/pkg/db
[ ! -e /tmp/inside/lib/pkg/db.backup ]
root=/tmp/db-link
mkdir -p "$root/var/lib/pkg"
ln -s /tmp/inside/lib/pkg/db "$root/var/lib/pkg/db"
status=0
/tmp/bin-new/pkgrm -r "$root" outside >/tmp/link.out 2>/tmp/link.err || status=$?
[ "$status" -eq 1 ]
[ -L "$root/var/lib/pkg/db" ]
cmp /tmp/outside-db /tmp/inside/lib/pkg/db
[ ! -e "$root/var/lib/pkg/db.backup" ]
root=/tmp/unsafe
mkdir -p "$root/var/lib/pkg"
printf "alpha\n1\n../outside\nz-victim\n\n" >"$root/var/lib/pkg/db"
cp "$root/var/lib/pkg/db" /tmp/original-db
: >"$root/z-victim"
status=0
/tmp/bin-new/pkgrm -r "$root" alpha >/tmp/unsafe.out 2>/tmp/unsafe.err || status=$?
[ "$status" -eq 1 ]
[ -f "$root/z-victim" ]
cmp /tmp/original-db "$root/var/lib/pkg/db"
grep "unsafe database path" /tmp/unsafe.err >/dev/null
'
printf 'PASS: public removal, shared ownership, and partial-failure status\n'
