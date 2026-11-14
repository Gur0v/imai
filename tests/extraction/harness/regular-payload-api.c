#define _GNU_SOURCE
#include <archive.h>
#include <archive_entry.h>
#include <fcntl.h>
#include <stdio.h>
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
	if (package_archive_open(argv[1], &package) ||
	    install_paths_check(&package) < 0 || unlink(argv[1]) < 0)
		return 1;
	struct archive *reader = archive_read_new();
	struct archive_entry *entry;
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (!reader || root < 0 ||
	    archive_read_support_format_tar(reader) != ARCHIVE_OK ||
	    archive_read_open_FILE(reader, package.stream) != ARCHIVE_OK ||
	    archive_read_next_header(reader, &entry) != ARCHIVE_OK ||
	    install_regular(root, "alias/file", reader, entry) < 0)
		return 1;
	struct stat st;
	if (fstatat(root, "real/file", &st, 0) < 0 ||
	    st.st_size != 8 || (st.st_mode & 07777) != 04751 ||
	    st.st_uid != 0 || st.st_gid != 0 || st.st_mtim.tv_sec != 123456789 ||
	    archive_read_next_header(reader, &entry) != ARCHIVE_EOF)
		return 1;
	archive_read_free(reader);
	package_archive_free(&package);
	return close(root) < 0;
}
