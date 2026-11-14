#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fs/fs.h"

static int outside;
static unsigned injections;
int __real_mkdirat(int dir, const char *path, mode_t mode);

int
__wrap_mkdirat(int dir, const char *path, mode_t mode)
{
	if (!strcmp(path, "race-dir")) {
		if (__real_mkdirat(dir, path, mode) < 0)
			return -1;
	} else if (!strcmp(path, "race-file")) {
		int fd = openat(dir, path, O_WRONLY | O_CREAT | O_EXCL, 0600);
		if (fd < 0 || close(fd) < 0)
			return -1;
	} else if (!strcmp(path, "race-magic")) {
		char target[80];
		snprintf(target, sizeof(target), "/proc/self/fd/%d", outside);
		if (symlinkat(target, dir, path) < 0)
			return -1;
	} else {
		return __real_mkdirat(dir, path, mode);
	}
	injections++;
	return __real_mkdirat(dir, path, mode);
}

int
main(void)
{
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0 || outside < 0 ||
	    fs_mkdirs(root, "race-dir/child") < 0 ||
	    fs_mkdirs(root, "race-file/child") == 0 || errno != ENOTDIR ||
	    fs_mkdirs(root, "race-magic/child") == 0 || errno != ELOOP ||
	    injections != 3)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
