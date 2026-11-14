#include <archive.h>
#include <archive_entry.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "archive/archive.h"

int
main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	struct package_archive package = {0};
	if (package_archive_open(argv[1], &package))
		return 1;
	if (package.count != 2 ||
	    strcmp(archive_entry_pathname(package.entries[0]), "file") ||
	    strcmp(archive_entry_pathname(package.entries[1]), "alias") ||
	    strcmp(archive_entry_symlink(package.entries[1]), "file"))
		return 1;
	if (unlink(argv[1]) < 0)
		return 1;
	FILE *replacement = fopen(argv[1], "w");
	if (!replacement || fputs("replacement", replacement) < 0 ||
	    fclose(replacement))
		return 1;
	struct archive *reader = archive_read_new();
	struct archive_entry *entry;
	if (!reader || archive_read_support_format_tar(reader) != ARCHIVE_OK ||
	    archive_read_open_FILE(reader, package.stream) != ARCHIVE_OK ||
	    archive_read_next_header(reader, &entry) != ARCHIVE_OK)
		return 1;
	char buffer[16] = {0};
	if (archive_read_data(reader, buffer, sizeof(buffer)) != 9 ||
	    strcmp(buffer, "original\n"))
		return 1;
	if (archive_read_next_header(reader, &entry) != ARCHIVE_OK ||
	    strcmp(archive_entry_symlink(entry), "file") ||
	    archive_read_next_header(reader, &entry) != ARCHIVE_EOF ||
	    archive_read_free(reader) != ARCHIVE_OK)
		return 1;
	package_archive_free(&package);
	if (package.stream || package.entries || package.count)
		return 1;
	return 0;
}
