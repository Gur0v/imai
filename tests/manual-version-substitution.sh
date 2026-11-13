#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

srcdir=${1:-.}
case $srcdir in
/*) ;;
*) srcdir=$PWD/$srcdir ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM

for page in pkgadd.8 pkgrm.8 pkginfo.8 pkgmk.8 rejmerge.8 \
    pkgmk.conf.5 pkgfile.5; do
	source=$srcdir/$page.in
	if ! grep -E '^\.TH .*"imai #VERSION#"' "$source" >/dev/null; then
		printf 'FAIL: missing versioned manual header: %s\n' "$source" >&2
		exit 1
	fi
	sed 's/#VERSION#/0.1.0/g' "$source" >"$work/$page"
	if grep -F '#VERSION#' "$work/$page" >/dev/null ||
	    ! grep -F '"imai 0.1.0"' "$work/$page" >/dev/null; then
		printf 'FAIL: version substitution: %s\n' "$source" >&2
		exit 1
	fi
	if command -v groff >/dev/null 2>&1; then
		groff -man -Tascii "$work/$page" >"$work/rendered"
		if [ ! -s "$work/rendered" ]; then
			printf 'FAIL: empty rendered manual: %s\n' "$source" >&2
			exit 1
		fi
	fi
done
printf 'PASS: seven manual sources support version substitution\n'
if command -v groff >/dev/null 2>&1; then
	printf 'PASS: groff rendering for seven manuals\n'
else
	printf 'SKIP: groff rendering (groff unavailable)\n'
fi
