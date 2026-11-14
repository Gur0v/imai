#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <unistd.h>
#include "db/db.h"

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
