#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
candidate=${1:-$PWD/build/pkgrm}
reference=${2:-$PWD/build/reference/pkgrm}
# Mutations, including the real host helper, remain inside disposable tmpfs.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --tmpfs /tmp --ro-bind "$candidate" /tmp/bin-new/pkgrm \
    --ro-bind "$reference" /tmp/bin-old/pkgrm -- /bin/dash -eu -c '
for tool in old new; do
    root=/tmp/$tool
    mkdir -p "$root/var/lib/pkg" "$root/etc" "$root/lib" "$root/usr/lib"
    printf "alpha\n1\nvictim\n\n" >"$root/var/lib/pkg/db"
    : >"$root/victim"
    : >"$root/etc/ld.so.conf"
    /tmp/bin-$tool/pkgrm -r "$root" alpha >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -e "$root/victim" ]
    [ ! -s "$root/var/lib/pkg/db" ]
    [ -s "$root/etc/ld.so.cache" ]
    [ ! -s "/tmp/$tool.out" ]
    [ ! -s "/tmp/$tool.err" ]
done
cmp /tmp/old/etc/ld.so.cache /tmp/new/etc/ld.so.cache
cmp /tmp/old/var/lib/pkg/db.backup /tmp/new/var/lib/pkg/db.backup
'
printf 'PASS: real ldconfig cache and database differential integration\n'
