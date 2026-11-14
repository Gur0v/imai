#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires pkg-config, libarchive/zlib development files, mktemp, and Python 3.
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p build "$work/fixtures"
set -f
# shellcheck disable=SC2086,SC2046
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    ${ARCHIVE_TEST_CFLAGS:-} -iquote src "$harness/query-regressions.c" src/archive/archive.c \
    $(pkg-config --cflags --libs libarchive) -lz -lbz2 \
    ${ARCHIVE_TEST_LDFLAGS:-} \
    -o build/archive-test
reference=${REFERENCE_PKGINFO:-build/reference/pkginfo}
[ -x "$reference" ]
printf 'backward\nblock\nchar\ndir/\nfifo\nforward\nmissing\nsym\ntarget\nunknown-owner\nz\n' \
    >"$work/list.expected"
fail_query()
{
    status=0
    build/archive-test "$1" "$2" >"$work/out" 2>"$work/err" || status=$?
    [ "$status" -eq 1 ]
    [ ! -s "$work/out" ]
    grep '^pkginfo: ' "$work/err" >/dev/null
}
# Independent decoders verify that corruption fixtures are actually invalid.
python3 -I "$harness/query-regressions-fixtures.py" "$work/fixtures"
for prefix in BZh-file LZIP-file; do
    file="$work/fixtures/$prefix#1.pkg.tar.none"
    printf '%s\n' "$prefix" >"$work/prefix.expected"
    build/archive-test list "$file" >"$work/out"
    cmp "$work/prefix.expected" "$work/out"
done
printf 'file\n' >"$work/single.expected"
for filter in gzip bzip2 xz; do
    file="$work/fixtures/valid#1.pkg.tar.$filter"
    build/archive-test list "$file" >"$work/out"
    cmp "$work/single.expected" "$work/out"
    for kind in checksum truncated; do
        fail_query list "$work/fixtures/$kind#1.pkg.tar.$filter"
        fail_query footprint "$work/fixtures/$kind#1.pkg.tar.$filter"
    done
done
fail_query list "$work/fixtures/member-checksum#1.pkg.tar.gzip"
fail_query footprint "$work/fixtures/member-checksum#1.pkg.tar.gzip"
for name in size#1.pkg.tar.gzip nested-checksum#1.pkg.tar.xz; do
    fail_query list "$work/fixtures/$name"
    fail_query footprint "$work/fixtures/$name"
done
for kind in members trailing; do
    file="$work/fixtures/$kind#1.pkg.tar.gzip"
    "$reference" -f "$file" >"$work/reference"
    build/archive-test footprint "$file" >"$work/out"
    cmp "$work/reference" "$work/out"
done
file="$work/fixtures/nested#1.pkg.tar.xz"
"$reference" -f "$file" >"$work/reference"
build/archive-test footprint "$file" >"$work/out"
cmp "$work/reference" "$work/out"
for filter in none gzip bzip2 xz lzip zstd; do
    file="$work/fixtures/sample#1-1.pkg.tar.$filter"
    build/archive-test fixture "$file" "$filter"
    "$reference" -f "$file" >"$work/reference"
    build/archive-test footprint "$file" >"$work/out"
    cmp "$work/reference" "$work/out"
    build/archive-test list "$file" >"$work/out"
    cmp "$work/list.expected" "$work/out"
    dd if="$file" of="$work/fixtures/broken#1.pkg.tar.$filter" \
        bs=1 count=80 2>/dev/null
    fail_query list "$work/fixtures/broken#1.pkg.tar.$filter"
    fail_query footprint "$work/fixtures/broken#1.pkg.tar.$filter"
    if [ "$filter" != none ]; then
        bytes=$(wc -c <"$file")
        dd if="$file" of="$work/fixtures/tail#1.pkg.tar.$filter" \
            bs=1 count=$((bytes - 12)) 2>/dev/null
        fail_query list "$work/fixtures/tail#1.pkg.tar.$filter"
        fail_query footprint "$work/fixtures/tail#1.pkg.tar.$filter"
    fi
done
file="$work/fixtures/sample#1-1.pkg.tar.none"
dd if="$file" of="$work/fixtures/late#1.pkg.tar.none" \
    bs=512 count=132 2>/dev/null
printf 'broken header' >>"$work/fixtures/late#1.pkg.tar.none"
fail_query list "$work/fixtures/late#1.pkg.tar.none"
fail_query footprint "$work/fixtures/late#1.pkg.tar.none"
for name in no-delimiter '#1.pkg.tar.gz' 'name#.pkg.tar.gz'; do
    cp "$file" "$work/fixtures/$name"
    fail_query list "$work/fixtures/$name"
done
cp "$file" "$work/fixtures/name#1"
build/archive-test list "$work/fixtures/name#1" >"$work/out"
cmp "$work/list.expected" "$work/out"
cp "$file" "$work/fixtures/no-delimiter"
build/archive-test footprint "$work/fixtures/no-delimiter" >"$work/out"
"$reference" -f "$file" >"$work/reference"
cmp "$work/reference" "$work/out"
build/archive-test empty "$work/fixtures/empty#1.pkg.tar.none" none
fail_query list "$work/fixtures/empty#1.pkg.tar.none"
fail_query footprint "$work/fixtures/empty#1.pkg.tar.none"
fail_query list "$work/fixtures/nonexistent#1"
fail_query footprint "$work/fixtures/nonexistent#1"
candidate=${CANDIDATE_PKGINFO:-./build/pkginfo}
mkdir -p "$work/root/var/lib/pkg"
: >"$work/root/var/lib/pkg/db"
"$candidate" -r "$work/no-database" -f "$file" >"$work/out"
cmp "$work/reference" "$work/out"
"$candidate" -r "$work/root" -l "$file" >"$work/out"
cmp "$work/list.expected" "$work/out"
printf 'PASS: archive queries (six filters, metadata, links, errors)\n'
