#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires pkg-config, libarchive/zlib development files, mktemp, and Python 3.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p build "$work/fixtures"
cat >"$work/harness.c" <<'EOF'
#include <archive.h>
#include <archive_entry.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "archive.h"

static void entry(struct archive *a, const char *path, int mode,
    const char *link, int size)
{
	struct archive_entry *e = archive_entry_new();
	archive_entry_set_pathname(e, path);
	archive_entry_set_mode(e, mode);
	archive_entry_set_uid(e, 0);
	archive_entry_set_gid(e, 0);
	if (strcmp(path, "unknown-owner") == 0) {
		archive_entry_set_uid(e, 4294967294U);
		archive_entry_set_gid(e, 4294967294U);
	}
	/* Stored names must not override host UID/GID lookup. */
	archive_entry_set_uname(e, "not-the-user");
	archive_entry_set_gname(e, "not-the-group");
	archive_entry_set_size(e, size);
	if (link) {
		if ((mode & AE_IFMT) == AE_IFLNK)
			archive_entry_set_symlink(e, link);
		else
			archive_entry_set_hardlink(e, link);
	}
	archive_entry_set_rdevmajor(e, 1);
	archive_entry_set_rdevminor(e, 3);
	if (archive_write_header(a, e) != ARCHIVE_OK) {
		fprintf(stderr, "%s: %s\n", path, archive_error_string(a));
		exit(2);
	}
	for (int i = 0; i < size; ++i)
		if (archive_write_data(a, "x", 1) != 1)
			exit(2);
	archive_entry_free(e);
}

int main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "fixture") != 0)
		return strcmp(argv[1], "list") == 0 ?
		    package_list(argv[2]) : package_footprint(argv[2]);
	if (argc != 4)
		return 2;
	struct archive *a = archive_write_new();
	if (archive_write_set_format_pax_restricted(a) != ARCHIVE_OK ||
	    (strcmp(argv[3], "none") != 0 &&
	    archive_write_add_filter_by_name(a, argv[3]) != ARCHIVE_OK) ||
	    archive_write_open_filename(a, argv[2]) != ARCHIVE_OK) {
		fprintf(stderr, "fixture: %s\n", archive_error_string(a));
		return 2;
	}
	if (strcmp(argv[1], "empty") != 0) {
		entry(a, "z", AE_IFREG | 04751, NULL, 65536);
		entry(a, "forward", AE_IFREG | 0600, "target", 0);
		entry(a, "dir/", AE_IFDIR | 01770, NULL, 0);
		entry(a, "sym", AE_IFLNK | 0600, "../target", 0);
		entry(a, "target", AE_IFREG | 02640, NULL, 0);
		entry(a, "backward", AE_IFREG | 0600, "z", 0);
		entry(a, "missing", AE_IFREG | 0600, "absent", 0);
		entry(a, "char", AE_IFCHR | 0600, NULL, 0);
		entry(a, "block", AE_IFBLK | 0600, NULL, 0);
		entry(a, "fifo", AE_IFIFO | 0644, NULL, 0);
		entry(a, "target", AE_IFREG | 0644, NULL, 0);
		entry(a, "unknown-owner", AE_IFREG | 0644, NULL, 0);
	}
	int result = archive_write_close(a);
	archive_write_free(a);
	return result != ARCHIVE_OK;
}
EOF
set -f
# shellcheck disable=SC2086,SC2046
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    ${ARCHIVE_TEST_CFLAGS:-} -iquote src "$work/harness.c" src/archive.c \
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
python3 -I - "$work/fixtures" <<'PY'
import bz2
import gzip
import io
import lzma
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as archive:
    entry = tarfile.TarInfo("file")
    entry.size = 1
    archive.addfile(entry, io.BytesIO(b"x"))
plain = buffer.getvalue()
for prefix in ("BZh-file", "LZIP-file"):
    other = io.BytesIO()
    with tarfile.open(fileobj=other, mode="w") as archive:
        entry = tarfile.TarInfo(prefix)
        archive.addfile(entry)
    (root / (prefix + "#1.pkg.tar.none")).write_bytes(other.getvalue())
padded = plain + bytes(4 * 1024 * 1024)
for suffix, encode, decode, data in [
    ("gzip", gzip.compress, gzip.decompress, plain),
    ("bzip2", bz2.compress, bz2.decompress, padded),
    ("xz", lzma.compress, lzma.decompress, padded),
]:
    encoded = encode(data)
    (root / ("valid#1.pkg.tar." + suffix)).write_bytes(encoded)
    damaged = bytearray(encoded)
    damaged[-8] ^= 1
    for kind, stream in [("checksum", damaged),
                         ("truncated", encoded[:-12])]:
        try:
            decode(stream)
        except (OSError, EOFError, ValueError, lzma.LZMAError):
            pass
        else:
            raise AssertionError("independent decoder accepted " + suffix)
        (root / (kind + "#1.pkg.tar." + suffix)).write_bytes(stream)
second = bytearray(gzip.compress(bytes(1024)))
second[-8] ^= 1
(root / "member-checksum#1.pkg.tar.gzip").write_bytes(
    gzip.compress(plain) + second)
(root / "members#1.pkg.tar.gzip").write_bytes(
    gzip.compress(plain[:512]) + gzip.compress(plain[512:]))
(root / "trailing#1.pkg.tar.gzip").write_bytes(gzip.compress(plain) + b"trailing")
(root / "nested#1.pkg.tar.xz").write_bytes(lzma.compress(gzip.compress(plain)))
(root / "nested-checksum#1.pkg.tar.xz").write_bytes(
    lzma.compress((root / "checksum#1.pkg.tar.gzip").read_bytes()))
size_bad = bytearray(gzip.compress(plain))
size_bad[-4] ^= 1
try:
    gzip.decompress(size_bad)
except OSError:
    pass
else:
    raise AssertionError("independent decoder accepted invalid ISIZE")
(root / "size#1.pkg.tar.gzip").write_bytes(size_bad)
PY
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
