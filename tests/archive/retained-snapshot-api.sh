#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${ARCHIVE_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$harness/retained-snapshot-api.c" src/archive/archive.c \
    $(pkg-config --cflags --libs libarchive) -lz -lbz2 -o "$work/snapshot"
mkdir "$work/files"
printf 'original\n' >"$work/files/file"
ln -s file "$work/files/alias"
bsdtar -czf "$work/alpha#1.pkg.tar.gz" -C "$work/files" file alias
"$work/snapshot" "$work/alpha#1.pkg.tar.gz"
printf 'PASS: validated archive snapshot survives source replacement\n'
