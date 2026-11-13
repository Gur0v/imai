#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/command.c" <<'EOF'
#include <string.h>
#include "archive.h"

int
main(int argc, char **argv)
{
	if (argc != 3)
		return 2;
	if (!strcmp(argv[1], "list"))
		return package_list(argv[2]);
	struct package_archive package = {0};
	int result = !strcmp(argv[1], "default")
	                 ? package_archive_open(argv[2], &package)
	                 : package_archive_open_command(argv[2], &package,
	                       argv[1]);
	package_archive_free(&package);
	return result;
}
EOF
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${ARCHIVE_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$work/command.c" src/archive.c \
    $(pkg-config --cflags --libs libarchive) -lz -lbz2 -o "$work/command"
mkdir "$work/fixtures" "$work/files"
printf 'payload\n' >"$work/files/file"
bsdtar -cf "$work/fixtures/invalid-name" -C "$work/files" file
printf '' >"$work/empty-list"
bsdtar -cf "$work/fixtures/empty" -T "$work/empty-list"
printf 'not an archive\n' >"$work/fixtures/invalid"
bsdtar -czf "$work/fixtures/valid.gz" -C "$work/files" file
# Retain a gzip header while cutting off its compressed payload/trailer.
dd if="$work/fixtures/valid.gz" of="$work/fixtures/truncated.gz" \
    bs=1 count=12 2>/dev/null
check_failure()
{
    status=0
    "$work/command" default "$1" >"$work/out" 2>"$work/default" || status=$?
    [ "$status" -eq 1 ]
    [ ! -s "$work/out" ]
    message=$(cat "$work/default")
    case "$message" in
        'pkginfo: '*) ;;
        *) exit 1 ;;
    esac
    for command in pkgadd custom-command pkginfo; do
        status=0
        "$work/command" "$command" "$1" >"$work/out" \
            2>"$work/actual" || status=$?
        [ "$status" -eq 1 ]
        [ ! -s "$work/out" ]
        printf '%s: %s\n' "$command" "${message#pkginfo: }" \
            >"$work/expected"
        cmp "$work/expected" "$work/actual"
    done
}
for fixture in missing invalid empty truncated.gz .; do
    check_failure "$work/fixtures/$fixture"
done
check_failure ''
"$work/command" pkgadd "$work/fixtures/invalid-name" \
    >"$work/out" 2>"$work/err"
[ ! -s "$work/out" ]
[ ! -s "$work/err" ]
status=0
"$work/command" list "$work/fixtures/invalid-name" \
    >"$work/out" 2>"$work/err" || status=$?
[ "$status" -eq 1 ]
[ ! -s "$work/out" ]
printf '%s\n' 'pkginfo: could not determine name and/or version of invalid-name: Invalid package name' \
    >"$work/expected"
cmp "$work/expected" "$work/err"
printf 'PASS: archive-open diagnostics use the explicit command\n'
