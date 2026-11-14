#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
candidate=${1:-./build/pkginfo}
reference=${2:-./build/reference/pkginfo}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/root/var/lib/pkg"
printf 'zeta\n2-1\nusr/z\nusr/a\nusr/a\n\nalpha\n1-1\netc/a\n\n' \
    >"$work/root/var/lib/pkg/db"
compare()
{
	old_status=0 new_status=0
	"$reference" "$@" >"$work/old.out" 2>"$work/old.err" || old_status=$?
	"$candidate" "$@" >"$work/new.out" 2>"$work/new.err" || new_status=$?
	[ "$old_status" -eq "$new_status" ]
	cmp "$work/old.out" "$work/new.out"
	cmp "$work/old.err" "$work/new.err"
}
compare --help
compare --bad --help
compare
compare --bad
compare --root
compare -i -i
compare -r "$work/root" -i
compare -r "$work/root" -l zeta
compare -r "$work/root" -o '^/usr/'
compare -r "$work/root" -o nomatch
compare -r "$work/root" -o '['
compare -r "$work/root" -l nonexistent
compare -r "$work/root///missing" -i
rm "$work/root/var/lib/pkg/db"
compare -r "$work/root///" -i
printf 'PASS: differential read-only queries\n'
