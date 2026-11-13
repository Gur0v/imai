#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/add.c" <<'EOF'
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include "db.h"

static struct package
record(const char *name, const char *version)
{
	struct package pkg = {.name = strdup(name), .version = strdup(version)};
	if (!pkg.name || !pkg.version)
		exit(2);
	return pkg;
}

int
main(void)
{
	struct database db = {0};
	struct package pkg = record("alpha", "1");
	if (db_read(&db, "/tmp/root") < 0)
		return 1;
	if (db_add(&db, &pkg) == 0 || errno != EPERM || !pkg.name)
		return 1;
	db_free(&db);
	if (db_open(&db, "/tmp/root", true, "db-add") < 0 ||
	    db_add(&db, &pkg) < 0 || pkg.name || pkg.version || pkg.files ||
	    pkg.count || db.count != 2 || strcmp(db.packages[0].name, "alpha"))
		return 1;
	for (int field = 0; field < 4; field++) {
		pkg = record(field == 0 ? "bad\nname" : "valid",
		    field == 1 ? "bad\nversion" : "1");
		pkg.files = malloc(sizeof(*pkg.files));
		if (!pkg.files)
			return 2;
		pkg.files[0] = strdup(field == 2 ? "bad\npath" :
		    field == 3 ? "" : "valid");
		if (!pkg.files[0])
			return 2;
		pkg.count = 1;
		char *name = pkg.name, *version = pkg.version;
		char **files = pkg.files;
		if (db_add(&db, &pkg) == 0 || errno != EINVAL ||
		    db.count != 2 || pkg.name != name || pkg.version != version ||
		    pkg.files != files || pkg.count != 1)
			return 1;
		package_free(&pkg);
	}
	pkg = record("zeta", "3");
	pkg.files = malloc(3 * sizeof(*pkg.files));
	if (!pkg.files)
		return 2;
	pkg.files[0] = strdup("z");
	pkg.files[1] = strdup("a");
	pkg.files[2] = strdup("a");
	pkg.count = 3;
	if (!pkg.files[0] || !pkg.files[1] || !pkg.files[2])
		return 2;
	if (db_add(&db, &pkg) < 0 || pkg.name || db.count != 2 ||
	    strcmp(db.packages[1].version, "3") ||
	    db.packages[1].count != 2 || strcmp(db.packages[1].files[0], "a") ||
	    strcmp(db.packages[1].files[1], "z") || db_commit(&db) < 0)
		return 1;
	db_free(&db);
	return 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${DB_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$work/add.c" src/db.c -o "$work/add"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --proc /proc --tmpfs /tmp \
    --ro-bind "$work/add" /tmp/add -- /bin/dash -eu -c '
mkdir -p /tmp/root/var/lib/pkg
printf "zeta\n2\nold\n\n" >/tmp/root/var/lib/pkg/db
/tmp/add
printf "zeta\n3\na\nz\n\n" >/tmp/expected
cmp /tmp/expected /tmp/root/var/lib/pkg/db
'
printf 'PASS: exclusive database insertion, replacement, and ownership transfer\n'
