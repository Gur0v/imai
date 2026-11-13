#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires libarchive/zlib development files, pkg-config, and Python 3 bz2.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir "$work/fixtures"
cat >"$work/check.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include "archive.h"

int
main(int argc, char **argv)
{
	if (argc != 3)
		return 2;
	if (!strcmp(argv[1], "list"))
		return package_list(argv[2]);
	if (!strcmp(argv[1], "footprint"))
		return package_footprint(argv[2]);
	struct package_archive package = {0};
	int result = package_archive_open_command(argv[2], &package, "pkgadd");
	if (result && (package.stream || package.entries || package.count)) {
		fprintf(stderr, "failed open retained package ownership\n");
		package_archive_free(&package);
		return 2;
	}
	package_archive_free(&package);
	return result;
}
EOF
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${ARCHIVE_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$work/check.c" src/archive.c \
    $(pkg-config --cflags --libs libarchive) -lz -lbz2 \
    ${ARCHIVE_TEST_LDFLAGS:-} -o "$work/check"
python3 -I - "$work/fixtures" <<'PY'
import bz2
import gzip
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode="w") as archive:
    entry = tarfile.TarInfo("file")
    entry.size = 1
    archive.addfile(entry, io.BytesIO(b"x"))
first = bz2.compress(raw.getvalue())
second = bz2.compress(bytes(4096))
valid = first + second
assert bz2.decompress(valid) == raw.getvalue() + bytes(4096)
(root / "valid#1.pkg.tar.bz2").write_bytes(valid)
for length in (3, 4, 12, len(second) - 1):
    broken = first + second[:length]
    try:
        bz2.decompress(broken)
    except (OSError, EOFError, ValueError):
        pass
    else:
        raise AssertionError("independent decoder accepted truncated member")
    (root / ("truncated-" + str(length) + "#1.pkg.tar.bz2")).write_bytes(broken)
    (root / ("nested-" + str(length) + "#1.pkg.tar.gz")).write_bytes(
        gzip.compress(broken))
damaged = bytearray(second)
# The bzip2 block CRC starts immediately after its six-byte block marker.
damaged[10] ^= 1
try:
    bz2.decompress(damaged)
except OSError:
    pass
else:
    raise AssertionError("independent decoder accepted corrupted member CRC")
(root / "checksum-member#1.pkg.tar.bz2").write_bytes(first + damaged)
PY
printf 'file\n' >"$work/expected"
"$work/check" list "$work/fixtures/valid#1.pkg.tar.bz2" >"$work/out"
cmp "$work/expected" "$work/out"
failed=0
set +f
for fixture in "$work/fixtures"/*; do
    name=${fixture##*/}
    [ "$name" != 'valid#1.pkg.tar.bz2' ] || continue
    for mode in list footprint open; do
        status=0
        "$work/check" "$mode" "$work/fixtures/$name" \
            >"$work/out" 2>"$work/err" || status=$?
        command=pkginfo
        [ "$mode" != open ] || command=pkgadd
        if [ "$status" -ne 1 ] || [ -s "$work/out" ] ||
            ! grep "^$command: " "$work/err" >/dev/null; then
            printf 'FAIL: %s %s accepted incomplete bzip2 member (status %s)\n' \
                "$mode" "$name" "$status" >&2
            failed=1
        fi
    done
done
[ "$failed" -eq 0 ]
printf 'PASS: incomplete concatenated bzip2 members rejected\n'
