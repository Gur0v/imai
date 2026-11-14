#include <stdio.h>
#include <string.h>
#include "archive/archive.h"

int
main(int argc, char **argv)
{
	if (argc != 3)
		return 2;
	if (!strcmp(argv[1], "list"))
		return package_list(argv[2]);
	if (!strcmp(argv[1], "footprint"))
		return package_footprint(argv[2]);
	struct package_archive package = {0};
	int result = package_archive_open_command(argv[2], &package, "pkgadd");
	if (result && (package.stream || package.entries || package.count)) {
		fprintf(stderr, "failed open retained package ownership\n");
		package_archive_free(&package);
		return 2;
	}
	package_archive_free(&package);
	return result;
}
