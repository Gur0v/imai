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
	if (root < 0 ||
	    fs_symlink(root, "/tmp/outside/sentinel", "alias/absolute") < 0 ||
	    fs_symlink(root, "../../outside/sentinel", "alias/relative") < 0 ||
	    fs_symlink(root, "replacement", "alias/absolute") == 0 || errno != EEXIST ||
	    fs_symlink(root, "target", "../outside/bad") == 0 || errno != EINVAL)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/bad", outside);
	if (fs_symlink(root, "target", magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
