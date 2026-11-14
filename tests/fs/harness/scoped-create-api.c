#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fs/fs.h"

int
main(void)
{
	umask(0);
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	int fd = fs_create(root, "./alias//file");
	struct stat st;
	if (fd < 0 || write(fd, "payload", 7) != 7 || fstat(fd, &st) < 0 ||
	    (st.st_mode & 0777) != 0600 || !(fcntl(fd, F_GETFD) & FD_CLOEXEC) ||
	    close(fd) < 0)
		return 1;
	const char *existing[] = {"symbol", "hard", "dir", "alias/file"};
	for (unsigned i = 0; i < sizeof(existing) / sizeof(*existing); i++)
		if (fs_create(root, existing[i]) >= 0 || errno != EEXIST)
			return 1;
	if (fs_create(root, "../outside/bad") >= 0 || errno != EINVAL ||
	    fs_create(root, "/tmp/outside/bad") >= 0 || errno != EINVAL)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/bad", outside);
	if (fs_create(root, magic) >= 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
