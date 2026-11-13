/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "db.h"
#include "pkgadd.h"

#ifndef VERSION
#define VERSION "0.1.0"
#endif

static void
help(const char *name)
{
	if (!strcmp(name, "pkgadd")) {
		printf(
		    "usage: pkgadd [options] <file>\n"
		    "options:\n"
		    "  -u, --upgrade        upgrade package with the same "
		    "name\n"
		    "  -f, --force          force install, overwrite "
		    "conflicting files\n"
		    "  -r, --root <path>    specify alternative installation "
		    "root\n"
		    "  -c, --config <file>  use alternate configuration file\n"
		    "  -v, --version        print version and exit\n"
		    "  -h, --help           print help and exit\n");
	} else if (!strcmp(name, "pkgrm")) {
		printf("usage: pkgrm [options] <package>\n"
		       "options:\n"
		       "  -r, --root <path>   specify alternative "
		       "installation root\n"
		       "  -v, --version       print version and exit\n"
		       "  -h, --help          print help and exit\n");
	} else {
		printf(
		    "usage: pkginfo [options]\n"
		    "options:\n"
		    "  -i, --installed             list installed packages\n"
		    "  -l, --list <package|file>   list files in <package> or "
		    "<file>\n"
		    "  -o, --owner <pattern>       list owner(s) of file(s) "
		    "matching <pattern>\n"
		    "  -f, --footprint <file>      print footprint for "
		    "<file>\n"
		    "  -r, --root <path>           specify alternative "
		    "installation root\n"
		    "  -v, --version               print version and exit\n"
		    "  -h, --help                  print help and exit\n");
	}
}

int
main(int argc, char **argv)
{
	const char *name = basename(argv[0]);
	if (strcmp(name, "pkgadd") && strcmp(name, "pkgrm") &&
	    strcmp(name, "pkginfo")) {
		fprintf(
		    stderr, "%s: command not supported by pkgutils\n", name);
		return EXIT_FAILURE;
	}
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v") || !strcmp(argv[i], "--version")) {
			printf("%s (imai) %s\n", name, VERSION);
			return fflush(stdout) || ferror(stdout) ? EXIT_FAILURE
			                                        : EXIT_SUCCESS;
		}
		if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			help(name);
			return fflush(stdout) || ferror(stdout) ? EXIT_FAILURE
			                                        : EXIT_SUCCESS;
		}
	}
	if (!strcmp(name, "pkginfo"))
		return pkginfo_run(argc, argv);
	if (!strcmp(name, "pkgrm"))
		return pkgrm_run(argc, argv);
	return pkgadd_run(argc, argv);
}
