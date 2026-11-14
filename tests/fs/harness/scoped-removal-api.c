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
	const char *paths[] = {"alias/file", "absolute/file", "final", "dangling",
	    "empty/", "nested/up/file", "escape/sentinel", "repeat//file",
	    "fifo", "hardlink", "./dots//./file"};
	for (unsigned i = 0; i < sizeof(paths) / sizeof(*paths); i++)
		if (fs_remove(root, paths[i]) < 0)
			return 1;
	const char *unsafe[] = {"", ".", "..", "/outside/sentinel",
	    "../outside/sentinel", "dir/../final", "dir/.", "///"};
	for (unsigned i = 0; i < sizeof(unsafe) / sizeof(*unsafe); i++)
		if (fs_remove(root, unsafe[i]) == 0 || errno != EINVAL)
			return 1;
	if (fs_remove(root, "alias/") == 0 ||
	    fs_remove(root, "nonempty/") == 0 ||
	    fs_remove(root, "missing") == 0 || errno != ENOENT)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/sentinel", outside);
	if (fs_remove(root, magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
