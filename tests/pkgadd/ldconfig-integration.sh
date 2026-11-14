#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
candidate=${1:-$PWD/build/pkgadd}
reference=${2:-$PWD/build/reference/pkgadd}
# The actual helper runs only against disposable namespace-local destinations.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --tmpfs /tmp --ro-bind "$candidate" /tmp/bin-new/pkgadd \
    --ro-bind "$reference" /tmp/bin-old/pkgadd -- /bin/dash -eu -c '
mkdir -p /tmp/payload/etc /tmp/payload/lib /tmp/payload/usr/lib /tmp/packages
: >/tmp/payload/etc/ld.so.conf
(cd /tmp/payload && bsdtar --uid 0 --gid 0 -cf /tmp/packages/helper#1-1.pkg.tar.gz etc lib usr)
for tool in old new; do
    root=/tmp/$tool
    mkdir -p "$root/var/lib/pkg"
    : >"$root/var/lib/pkg/db"
    /tmp/bin-$tool/pkgadd -r "$root" /tmp/packages/helper#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ -s "$root/var/lib/pkg/db" ]
    [ -f "$root/var/lib/pkg/db.backup" ]
    [ ! -s "$root/var/lib/pkg/db.backup" ]
    [ -s "$root/etc/ld.so.cache" ]
    [ ! -s "/tmp/$tool.out" ]
    [ ! -s "/tmp/$tool.err" ]
done
cmp /tmp/old/etc/ld.so.cache /tmp/new/etc/ld.so.cache
cmp /tmp/old/var/lib/pkg/db /tmp/new/var/lib/pkg/db
cmp /tmp/old/var/lib/pkg/db.backup /tmp/new/var/lib/pkg/db.backup
'
printf 'PASS: pkgadd real ldconfig cache and database integration\n'
