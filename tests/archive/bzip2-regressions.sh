#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires libarchive/zlib development files, pkg-config, and Python 3 bz2.
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir "$work/fixtures"
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${ARCHIVE_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$harness/bzip2-regressions.c" src/archive/archive.c \
    $(pkg-config --cflags --libs libarchive) -lz -lbz2 \
    ${ARCHIVE_TEST_LDFLAGS:-} -o "$work/check"
python3 -I "$harness/bzip2-regressions-fixtures.py" "$work/fixtures"
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
