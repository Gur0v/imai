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
	    fs_link(root, "./alias//file", "absolute/link") < 0 ||
	    fs_link(root, "absolute/link", "chain") < 0 ||
	    fs_link(root, "symbol", "symbol-copy") < 0)
		return 1;
	if (fs_link(root, "../outside/sentinel", "bad") == 0 || errno != EINVAL ||
	    fs_link(root, "alias/file", "../outside/bad") == 0 || errno != EINVAL ||
	    fs_link(root, "alias/file", "chain") == 0 || errno != EEXIST ||
	    fs_link(root, "missing", "bad") == 0 || errno != ENOENT)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/sentinel", outside);
	if (fs_link(root, magic, "bad") == 0 || errno != ELOOP ||
	    fs_link(root, "alias/file", magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
