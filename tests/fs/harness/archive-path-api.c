#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include "fs/fs.h"

int
main(void)
{
	const char *inputs[] = {"./real//./file", "dir///", "./", "a/./b/", "file", "a/."};
	const char *expected[] = {"real/file", "dir/", ".", "a/b/", "file", "a/"};
	for (size_t i = 0; i < sizeof(inputs) / sizeof(*inputs); i++) {
		char *path = fs_archive_path(inputs[i]);
		if (!path || strcmp(path, expected[i]))
			return 1;
		free(path);
	}
	const char *invalid[] = {"", "/etc/file", "../file", "a/../b", "a/.."};
	for (size_t i = 0; i < sizeof(invalid) / sizeof(*invalid); i++) {
		char *path = fs_archive_path(invalid[i]);
		if (path || errno != EINVAL)
			return 1;
	}
	return 0;
}
