#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "db/db.h"

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
