#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires bubblewrap, mktemp, OpenSSL (SHA256), and POSIX utilities.
# Input layout: CORPUS/crux/{core,opt,xorg}/*.pkg.tar.*; no extraction.
set -eu
export LC_ALL=C

if [ "$#" -ne 3 ]; then
	printf 'usage: %s corpus-directory candidate-pkginfo reference-pkginfo\n' "$0" >&2
	exit 2
fi
for utility in bwrap mktemp openssl; do
	command -v "$utility" >/dev/null || exit 2
done
corpus=$(CDPATH='' cd "$1" && pwd -P)
candidate=$2
reference=$3
[ -x "$candidate" ] && [ -x "$reference" ]
set -- "$corpus"/crux/core/*.pkg.tar.* \
    "$corpus"/crux/opt/*.pkg.tar.* "$corpus"/crux/xorg/*.pkg.tar.*
packages=0
for package do
	[ -f "$package" ] || continue
	packages=$((packages + 1))
done
if [ "$packages" -eq 0 ]; then
	printf 'no distribution package archives found in %s\n' "$corpus" >&2
	exit 2
fi
work=$(mktemp -d)
printf 'results: %s\n' "$work"
trap 'exit 2' HUP INT TERM
cp "$candidate" "$work/candidate"
cp "$reference" "$work/reference"
# Detect a rebuild during the snapshots; queries use only these copies.
cmp "$candidate" "$work/candidate"
cmp "$reference" "$work/reference"
: >"$work/empty-db"
{
	printf 'corpus: %s\npackages: %s\n' "$corpus" "$packages"
	openssl dgst -sha256 "$work/candidate" "$work/reference"
} >"$work/identity"
cat "$work/identity"

query()
{
	binary=$1
	shift
	bwrap --ro-bind / / --unshare-user --unshare-pid --unshare-net \
	    --die-with-parent --tmpfs /tmp --dir /tmp/root/var/lib/pkg \
	    --ro-bind "$work/empty-db" /tmp/root/var/lib/pkg/db \
	    --ro-bind "$work/$binary" /tmp/pkginfo \
	    --ro-bind "$corpus" /tmp/corpus \
	    /tmp/pkginfo "$@"
}

# Check isolation separately so two identical sandbox failures cannot pass.
bwrap --ro-bind / / --unshare-user --unshare-pid --unshare-net \
    --die-with-parent --tmpfs /tmp /bin/true
failed=0
index=0
for mode in l f; do
	matches=0
	status_mismatches=0
	stdout_mismatches=0
	stderr_mismatches=0
	candidate_failures=0
	reference_failures=0
	for package do
		[ -f "$package" ] || continue
		index=$((index + 1))
		member=${package#"$corpus"/}
		candidate_status=0
		reference_status=0
		if [ "$mode" = l ]; then
			query candidate -r /tmp/root -l "/tmp/corpus/$member" \
			    >"$work/candidate.out" 2>"$work/candidate.err" || candidate_status=$?
			query reference -r /tmp/root -l "/tmp/corpus/$member" \
			    >"$work/reference.out" 2>"$work/reference.err" || reference_status=$?
		else
			query candidate -f "/tmp/corpus/$member" \
			    >"$work/candidate.out" 2>"$work/candidate.err" || candidate_status=$?
			query reference -f "/tmp/corpus/$member" \
			    >"$work/reference.out" 2>"$work/reference.err" || reference_status=$?
		fi
		[ "$candidate_status" -eq 0 ] || candidate_failures=$((candidate_failures + 1))
		[ "$reference_status" -eq 0 ] || reference_failures=$((reference_failures + 1))
		different=0
		if [ "$candidate_status" -ne "$reference_status" ]; then
			status_mismatches=$((status_mismatches + 1))
			different=1
		fi
		if ! cmp -s "$work/candidate.out" "$work/reference.out"; then
			stdout_mismatches=$((stdout_mismatches + 1))
			different=1
		fi
		if ! cmp -s "$work/candidate.err" "$work/reference.err"; then
			stderr_mismatches=$((stderr_mismatches + 1))
			different=1
		fi
		if [ "$different" -eq 0 ]; then
			matches=$((matches + 1))
		else
			failed=1
		fi
		if [ "$different" -ne 0 ] || [ "$candidate_status" -ne 0 ] || \
		    [ "$reference_status" -ne 0 ]; then
			# Retain unexpected failures even when their bytes match.
			failed=1
			mkdir "$work/$index"
			for output in candidate.out reference.out candidate.err reference.err; do
				cp "$work/$output" "$work/$index/$output"
			done
			printf '%s -%s candidate=%s reference=%s\n' "$package" \
			    "$mode" "$candidate_status" "$reference_status" >"$work/$index/repro"
			printf 'query failure or mismatch: %s\n' "$work/$index/repro"
		fi
	done
	printf '%s\n' "-$mode packages=$packages exact=$matches status_mismatches=$status_mismatches stdout_mismatches=$stdout_mismatches stderr_mismatches=$stderr_mismatches candidate_nonzero=$candidate_failures reference_nonzero=$reference_failures" \
	    >>"$work/summary"
done
cat "$work/summary"
exit "$failed"
