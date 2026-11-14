#include <archive.h>
#include <archive_entry.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "archive/archive.h"

static void entry(struct archive *a, const char *path, int mode,
    const char *link, int size)
{
	struct archive_entry *e = archive_entry_new();
	archive_entry_set_pathname(e, path);
	archive_entry_set_mode(e, mode);
	archive_entry_set_uid(e, 0);
	archive_entry_set_gid(e, 0);
	if (strcmp(path, "unknown-owner") == 0) {
		archive_entry_set_uid(e, 4294967294U);
		archive_entry_set_gid(e, 4294967294U);
	}
	/* Stored names must not override host UID/GID lookup. */
	archive_entry_set_uname(e, "not-the-user");
	archive_entry_set_gname(e, "not-the-group");
	archive_entry_set_size(e, size);
	if (link) {
		if ((mode & AE_IFMT) == AE_IFLNK)
			archive_entry_set_symlink(e, link);
		else
			archive_entry_set_hardlink(e, link);
	}
	archive_entry_set_rdevmajor(e, 1);
	archive_entry_set_rdevminor(e, 3);
	if (archive_write_header(a, e) != ARCHIVE_OK) {
		fprintf(stderr, "%s: %s\n", path, archive_error_string(a));
		exit(2);
	}
	for (int i = 0; i < size; ++i)
		if (archive_write_data(a, "x", 1) != 1)
			exit(2);
	archive_entry_free(e);
}

int main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "fixture") != 0)
		return strcmp(argv[1], "list") == 0 ?
		    package_list(argv[2]) : package_footprint(argv[2]);
	if (argc != 4)
		return 2;
	struct archive *a = archive_write_new();
	if (archive_write_set_format_pax_restricted(a) != ARCHIVE_OK ||
	    (strcmp(argv[3], "none") != 0 &&
	    archive_write_add_filter_by_name(a, argv[3]) != ARCHIVE_OK) ||
	    archive_write_open_filename(a, argv[2]) != ARCHIVE_OK) {
		fprintf(stderr, "fixture: %s\n", archive_error_string(a));
		return 2;
	}
	if (strcmp(argv[1], "empty") != 0) {
		entry(a, "z", AE_IFREG | 04751, NULL, 65536);
		entry(a, "forward", AE_IFREG | 0600, "target", 0);
		entry(a, "dir/", AE_IFDIR | 01770, NULL, 0);
		entry(a, "sym", AE_IFLNK | 0600, "../target", 0);
		entry(a, "target", AE_IFREG | 02640, NULL, 0);
		entry(a, "backward", AE_IFREG | 0600, "z", 0);
		entry(a, "missing", AE_IFREG | 0600, "absent", 0);
		entry(a, "char", AE_IFCHR | 0600, NULL, 0);
		entry(a, "block", AE_IFBLK | 0600, NULL, 0);
		entry(a, "fifo", AE_IFIFO | 0644, NULL, 0);
		entry(a, "target", AE_IFREG | 0644, NULL, 0);
		entry(a, "unknown-owner", AE_IFREG | 0644, NULL, 0);
	}
	int result = archive_write_close(a);
	archive_write_free(a);
	return result != ARCHIVE_OK;
}
