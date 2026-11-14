#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include "fs/fs.h"

int
main(void)
{
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	const char *paths[] = {"./new//deep", "alias/child", "absolute/child",
	    "up/child", "alias/link/new", "alias/relative/next", "."};
	for (unsigned i = 0; i < sizeof(paths) / sizeof(*paths); i++)
		if (fs_mkdirs(root, paths[i]) < 0)
			return 1;
	if (fs_mkdirs(root, "../outside/bad") == 0 || errno != EINVAL ||
	    fs_mkdirs(root, "/tmp/outside/bad") == 0 || errno != EINVAL ||
	    fs_mkdirs(root, "file/child") == 0 || errno != ENOTDIR ||
	    fs_mkdirs(root, "dangling/child") == 0)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/bad", outside);
	if (fs_mkdirs(root, magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
