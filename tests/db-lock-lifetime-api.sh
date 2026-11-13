#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/root/var/lib/pkg"
printf 'sample\n1\nusr/file\n\n' >"$work/root/var/lib/pkg/db"
cat >"$work/lock.c" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <unistd.h>
#include "db.h"

int
main(int argc, char **argv)
{
	struct database db = {0};
	if (argc != 3 || db_read(&db, argv[1]) < 0)
		return 1;
	int fd = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0)
		return 1;
	if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
		fputs("FAIL: database released its lock before db_free\n", stderr);
		return 1;
	}
	if (errno != EWOULDBLOCK)
		return 1;
	db_free(&db);
	if (flock(fd, LOCK_EX | LOCK_NB) < 0)
		return 1;
	if (close(fd) < 0)
		return 1;
	puts("PASS: database lock lifetime");
	return 0;
}
EOF
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -iquote src "$work/lock.c" src/db.c -o "$work/lock"
"$work/lock" "$work/root" "$work/root/var/lib/pkg"
