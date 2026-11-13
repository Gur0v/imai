#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/path.c" <<'EOF'
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include "fs.h"

int
main(void)
{
	const char *inputs[] = {"./real//./file", "dir///", "./", "a/./b/", "file", "a/."};
	const char *expected[] = {"real/file", "dir/", ".", "a/b/", "file", "a/"};
	for (size_t i = 0; i < sizeof(inputs) / sizeof(*inputs); i++) {
		char *path = fs_archive_path(inputs[i]);
		if (!path || strcmp(path, expected[i]))
			return 1;
		free(path);
	}
	const char *invalid[] = {"", "/etc/file", "../file", "a/../b", "a/.."};
	for (size_t i = 0; i < sizeof(invalid) / sizeof(*invalid); i++) {
		char *path = fs_archive_path(invalid[i]);
		if (path || errno != EINVAL)
			return 1;
	}
	return 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$work/path.c" src/fs.c -o "$work/path"
"$work/path"
printf 'PASS: archive operation-path normalization and traversal rejection\n'
