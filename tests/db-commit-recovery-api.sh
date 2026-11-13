#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# All database writes execute inside a disposable bubblewrap filesystem.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/write.c" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "db.h"

int
main(int argc, char **argv)
{
	(void)argv;
	struct database db = {0};
	struct stat before, backup, current;
	if (db_open(&db, "/tmp/root", true, "db-write") < 0)
		return 1;
	if (argc > 1) {
		if (db_commit(&db) == 0)
			return 1;
		db_free(&db);
		return 0;
	}
	int dir = open("/tmp/root/var/lib/pkg", O_RDONLY | O_DIRECTORY);
	if (dir < 0 || flock(dir, LOCK_SH | LOCK_NB) == 0 ||
	    errno != EWOULDBLOCK)
		return 1;
	if (stat("/tmp/root/var/lib/pkg/db", &before) < 0 ||
	    db_commit(&db) < 0 ||
	    stat("/tmp/root/var/lib/pkg/db.backup", &backup) < 0 ||
	    stat("/tmp/root/var/lib/pkg/db", &current) < 0)
		return 1;
	if (before.st_ino != backup.st_ino || current.st_ino == before.st_ino ||
	    (current.st_mode & 0777) != 0444)
		return 1;
	db_free(&db);
	if (flock(dir, LOCK_EX | LOCK_NB) < 0 || close(dir) < 0)
		return 1;
	if (db_read(&db, "/tmp/root") < 0)
		return 1;
	errno = 0;
	if (db_commit(&db) == 0 || errno != EPERM)
		return 1;
	db_free(&db);
	return 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${DB_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -iquote src "$work/write.c" src/db.c -o "$work/write"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --ro-bind "$work/write" /tmp/write --ro-bind "$PWD/build/reference/pkginfo" /tmp/pkginfo \
    -- /bin/dash -eu -c '
mkdir -p /tmp/root/var/lib/pkg
printf "zeta\n2\nz\na\na\n\nalpha\n1\nb\n\n" >/tmp/root/var/lib/pkg/db
cp /tmp/root/var/lib/pkg/db /tmp/original
/tmp/write
printf "alpha\n1\nb\n\nzeta\n2\na\nz\n\n" >/tmp/expected
cmp /tmp/expected /tmp/root/var/lib/pkg/db
cmp /tmp/original /tmp/root/var/lib/pkg/db.backup
[ ! -e /tmp/root/var/lib/pkg/db.incomplete_transaction ]
/tmp/pkginfo -r /tmp/root -i >/tmp/out
printf "alpha 1\nzeta 2\n" >/tmp/expected
cmp /tmp/expected /tmp/out
cp /tmp/root/var/lib/pkg/db /tmp/before-failure
rm /tmp/root/var/lib/pkg/db.backup
mkdir /tmp/root/var/lib/pkg/db.backup
/tmp/write fail
cmp /tmp/before-failure /tmp/root/var/lib/pkg/db
cmp /tmp/before-failure /tmp/root/var/lib/pkg/db.incomplete_transaction
rmdir /tmp/root/var/lib/pkg/db.backup
rm /tmp/root/var/lib/pkg/db.incomplete_transaction
printf "sentinel\n" >/tmp/sentinel
ln -s /tmp/sentinel /tmp/root/var/lib/pkg/db.incomplete_transaction
/tmp/write
printf "sentinel\n" >/tmp/expected
cmp /tmp/expected /tmp/sentinel
'
printf 'PASS: database commit bytes, backup, locking, upstream interchange\n'
