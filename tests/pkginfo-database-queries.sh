#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
bindir=${1:-./build}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/root/var/lib/pkg"
printf 'zeta\n2-1\nusr/z\nusr/a\nusr/a\n\nalpha\n1-1\netc/a\n\n' \
    >"$work/root/var/lib/pkg/db"
"$bindir/pkginfo" -r "$work/root" -i >"$work/out"
printf 'alpha 1-1\nzeta 2-1\n' >"$work/expected"
cmp "$work/expected" "$work/out"
"$bindir/pkginfo" -l zeta -r "$work/root" >"$work/out"
printf 'usr/a\nusr/z\n' >"$work/expected"
cmp "$work/expected" "$work/out"
"$bindir/pkginfo" -r "$work/root" -o '^/usr/' >"$work/out"
printf 'Package  File\nzeta     usr/a\nzeta     usr/z\n' >"$work/expected"
cmp "$work/expected" "$work/out"
"$bindir/pkginfo" -r "$work/root" -o nomatch >"$work/out"
printf 'pkginfo: no owner(s) found\n' >"$work/expected"
cmp "$work/expected" "$work/out"
status=0
"$bindir/pkginfo" -r "$work/root" -i -i >"$work/out" \
    2>"$work/err" || status=$?
[ "$status" -eq 1 ]
printf 'pkginfo: too many options\n' >"$work/expected"
cmp "$work/expected" "$work/err"
status=0
"$bindir/pkginfo" --root >"$work/out" 2>"$work/err" || status=$?
[ "$status" -eq 1 ]
printf 'pkginfo: option --root requires an argument\n' >"$work/expected"
cmp "$work/expected" "$work/err"
printf 'incomplete\n' >"$work/root/var/lib/pkg/db"
"$bindir/pkginfo" -r "$work/root" -i >"$work/out"
[ ! -s "$work/out" ]
printf 'incomplete\nversion\n' >"$work/root/var/lib/pkg/db"
"$bindir/pkginfo" -r "$work/root" -i >"$work/out"
[ ! -s "$work/out" ]
: >"$work/root/var/lib/pkg/db"
"$bindir/pkginfo" -r "$work/root" -i >"$work/out"
[ ! -s "$work/out" ]
printf 'same\nold\nold-file\n\nsame\nnew\nnew-file\n\n' \
    >"$work/root/var/lib/pkg/db"
"$bindir/pkginfo" -r "$work/root" -i >"$work/out"
printf 'same new\n' >"$work/expected"
cmp "$work/expected" "$work/out"
"$bindir/pkginfo" -r "$work/root" -l same >"$work/out"
printf 'new-file\n' >"$work/expected"
cmp "$work/expected" "$work/out"
printf 'same\nignored\n\n' >>"$work/root/var/lib/pkg/db"
"$bindir/pkginfo" -r "$work/root" -i >"$work/out"
printf 'same new\n' >"$work/expected"
cmp "$work/expected" "$work/out"
printf 'bad\000name\n1\nfile\n\n' >"$work/root/var/lib/pkg/db"
status=0
"$bindir/pkginfo" -r "$work/root" -i >"$work/out" \
    2>"$work/err" || status=$?
[ "$status" -eq 1 ]
[ -s "$work/err" ]
rm "$work/root/var/lib/pkg/db"
mkdir "$work/root/var/lib/pkg/db"
status=0
"$bindir/pkginfo" -r "$work/root" -i >"$work/out" \
    2>"$work/err" || status=$?
[ "$status" -eq 1 ]
[ -s "$work/err" ]
printf 'PASS: database queries\n'
