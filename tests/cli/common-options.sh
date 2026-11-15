#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

bindir=${1:-./build}
case $bindir in
/*) ;;
*) bindir=$PWD/$bindir ;;
esac

if [ ! -x "$bindir/pkgadd" ]; then
	printf 'FAIL: missing compiled pkgadd: %s\n' "$bindir/pkgadd" >&2
	exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM

check()
{
	expected_status=$1
	expected_out=$2
	expected_err=$3
	shift 3
	status=0
	"$@" >"$work/out" 2>"$work/err" || status=$?
	printf '%s' "$expected_out" >"$work/expected-out"
	printf '%s' "$expected_err" >"$work/expected-err"
	if [ "$status" -ne "$expected_status" ] ||
	    ! cmp -s "$work/out" "$work/expected-out" ||
	    ! cmp -s "$work/err" "$work/expected-err"; then
		printf 'FAIL: %s (status %s, expected %s)\n' "$*" \
		    "$status" "$expected_status" >&2
		diff -u "$work/expected-out" "$work/out" || :
		diff -u "$work/expected-err" "$work/err" || :
		exit 1
	fi
}

for tool in pkgadd pkgrm pkginfo; do
	check 0 "$tool (imai) 0.1.4
" '' "$bindir/$tool" --version
	check 0 "$tool (imai) 0.1.4
" '' "$bindir/$tool" --bad --version
	check 0 "$tool (imai) 0.1.4
" '' "$bindir/$tool" --root --version
done

check 0 'usage: pkgrm [options] <package>
options:
  -r, --root <path>   specify alternative installation root
  -v, --version       print version and exit
  -h, --help          print help and exit
' '' "$bindir/pkgrm" --bad --help --version

ln -s "$bindir/pkgadd" "$work/unsupported"
check 1 '' 'unsupported: command not supported by pkgutils
' "$work/unsupported" --help

if [ -c /dev/full ]; then
	status=0
	"$bindir/pkgadd" --version >/dev/full 2>"$work/err" || status=$?
	[ "$status" -eq 1 ] || {
		printf 'FAIL: stdout write error reported success\n' >&2
		exit 1
	}
fi
printf 'PASS: CLI common options\n'
