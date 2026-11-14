#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "db/db.h"

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
