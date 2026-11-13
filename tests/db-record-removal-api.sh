#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/remove.c" <<'EOF'
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "db.h"

int
main(void)
{
	struct database db = {0};
	struct package removed = {0};
	if (db_read(&db, "/tmp/root") < 0)
		return 1;
	if (db_remove(&db, "alpha", &removed) == 0 || errno != EPERM ||
	    db.count != 2 || removed.name)
		return 1;
	db_free(&db);
	if (db_open(&db, "/tmp/root", true, "db-remove") < 0)
		return 1;
	if (db_remove(&db, "missing", &removed) == 0 || errno != ENOENT ||
	    db.count != 2 || removed.name)
		return 1;
	if (db_remove(&db, "alpha", &removed) < 0 || db.count != 1 ||
	    strcmp(db.packages[0].name, "zeta") ||
	    strcmp(removed.name, "alpha") || strcmp(removed.version, "1") ||
	    removed.count != 2 || strcmp(removed.files[0], "lib64/a") ||
	    strcmp(removed.files[1], "unique"))
		return 1;
	if (db_commit(&db) < 0)
		return 1;
	package_free(&removed);
	if (db_remove(&db, "zeta", &removed) < 0 || db.count != 0 ||
	    removed.count != 2 || strcmp(removed.files[0], "lib/a") ||
	    strcmp(removed.files[1], "shared/"))
		return 1;
	package_free(&removed);
	db_free(&db);
	if (db_open(&db, "/tmp/shared", true, "db-remove") < 0 ||
	    db_remove(&db, "zeta", &removed) < 0 || db.count != 1 ||
	    strcmp(removed.name, "zeta") || removed.count != 0 ||
	    strcmp(db.packages[0].name, "alpha"))
		return 1;
	package_free(&removed);
	db_free(&db);
	return 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${DB_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$work/remove.c" src/db.c -o "$work/remove"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --ro-bind "$work/remove" /tmp/remove -- /bin/dash -eu -c '
mkdir -p /tmp/root/var/lib/pkg
printf "alpha\n1\nunique\nshared/\nlib64/a\n\nzeta\n2\nshared/\nlib/a\n\n" \
    >/tmp/root/var/lib/pkg/db
mkdir -p /tmp/shared/var/lib/pkg
printf "alpha\n1\nshared/\n\nzeta\n2\nshared/\n\n" \
    >/tmp/shared/var/lib/pkg/db
/tmp/remove
printf "zeta\n2\nlib/a\nshared/\n\n" >/tmp/expected
cmp /tmp/expected /tmp/root/var/lib/pkg/db
'
printf 'PASS: database removal preserves exact shared ownership\n'
