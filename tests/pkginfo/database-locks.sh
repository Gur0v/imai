#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires flock (util-linux or BusyBox with the flock applet).
set -eu
candidate=${1:-./build/pkginfo}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/root/var/lib/pkg"
printf 'sample\n1\nusr/file\n\n' >"$work/root/var/lib/pkg/db"
flock -s "$work/root/var/lib/pkg" "$candidate" -r "$work/root" -i \
    >"$work/out" 2>"$work/err"
printf 'sample 1\n' >"$work/expected"
cmp "$work/expected" "$work/out"
[ ! -s "$work/err" ]
status=0
flock -x "$work/root/var/lib/pkg" "$candidate" -r "$work/root" -i \
    >"$work/out" 2>"$work/err" || status=$?
[ "$status" -eq 1 ]
[ ! -s "$work/out" ]
printf 'pkginfo: package database is currently locked by another process\n' \
    >"$work/expected"
cmp "$work/expected" "$work/err"
printf 'PASS: database directory locks\n'
