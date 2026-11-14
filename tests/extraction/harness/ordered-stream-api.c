#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "archive/archive.h"
#include "extraction/install.h"

int
main(int argc, char **argv)
{
	if (argc != 2)
		return 1;
	struct package_archive package = {0};
	if (package_archive_open(argv[1], &package) || unlink(argv[1]) < 0)
		return 1;
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	int result = install_stream(root, &package);
	if (result < 0 && !strstr(argv[1], "/unsafe#") &&
	    !strstr(argv[1], "/forward#"))
		perror("install_stream");
	struct stat st;
	bool ordered = strstr(argv[1], "/ordered#") != NULL;
	if (!result && ordered && (fstatat(root, "real", &st, 0) < 0 ||
	    (st.st_mode & 07777) != 0755 || st.st_mtim.tv_sec != 123456789))
		return 1;
	if (!result && ordered && (fstatat(root, "changed", &st, AT_SYMLINK_NOFOLLOW) < 0 ||
	    !S_ISLNK(st.st_mode) || st.st_uid != 0 || st.st_gid != 0 ||
	    st.st_mtim.tv_sec != 123456790))
		return 1;
	if (!result && ordered && (fstatat(root, "real/file", &st, 0) < 0 ||
	    st.st_mtim.tv_sec != 123456789))
		return 1;
	package_archive_free(&package);
	if (close(root) < 0)
		return 1;
	return result < 0;
}
