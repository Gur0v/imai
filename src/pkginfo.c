/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <regex.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "archive.h"
#include "db.h"

static int
owners(const struct database *db, const char *pattern)
{
	regex_t regex;
	if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB)) {
		fprintf(stderr,
		    "pkginfo: error compiling regular expression '%s', "
		    "aborting\n",
		    pattern);
		return 1;
	}
	size_t width = strlen("Package"), matches = 0;
	for (int pass = 0; pass < 2; pass++) {
		if (pass && matches) {
			fputs("Package", stdout);
			for (size_t k = strlen("Package"); k < width; k++)
				putchar(' ');
			fputs("  File\n", stdout);
		}
		for (size_t i = 0; i < db->count; i++) {
			const struct package *pkg = &db->packages[i];
			for (size_t j = 0; j < pkg->count; j++) {
				size_t length;
				if (ckd_add(
				        &length, strlen(pkg->files[j]), 2UL)) {
					regfree(&regex);
					return 1;
				}
				char *path = malloc(length);
				if (!path) {
					regfree(&regex);
					return 1;
				}
				snprintf(path, length, "/%s", pkg->files[j]);
				int matched =
				    !regexec(&regex, path, 0, NULL, 0);
				free(path);
				if (!matched)
					continue;
				if (!pass) {
					matches++;
					if (strlen(pkg->name) > width)
						width = strlen(pkg->name);
				} else {
					fputs(pkg->name, stdout);
					for (size_t k = strlen(pkg->name);
					    k < width + 2; k++)
						putchar(' ');
					puts(pkg->files[j]);
				}
			}
		}
	}
	regfree(&regex);
	if (!matches)
		puts("pkginfo: no owner(s) found");
	return 0;
}

int
pkginfo_run(int argc, char **argv)
{
	const char *root = "", *arg = NULL;
	int modes = 0;
	char mode = 0;
	for (int i = 1; i < argc; i++) {
		const char *option = argv[i];
		if (!strcmp(option, "-i") || !strcmp(option, "--installed")) {
			mode = 'i';
			modes++;
			continue;
		}
		char next = 0;
		if (!strcmp(option, "-r") || !strcmp(option, "--root"))
			next = 'r';
		else if (!strcmp(option, "-l") || !strcmp(option, "--list"))
			next = 'l';
		else if (!strcmp(option, "-o") || !strcmp(option, "--owner"))
			next = 'o';
		else if (!strcmp(option, "-f") ||
		         !strcmp(option, "--footprint"))
			next = 'f';
		if (!next) {
			fprintf(
			    stderr, "pkginfo: invalid option %s\n", option);
			return 1;
		}
		if (++i == argc) {
			fprintf(stderr,
			    "pkginfo: option %s requires an argument\n",
			    option);
			return 1;
		}
		if (next == 'r') {
			root = argv[i];
		} else {
			mode = next;
			modes++;
			arg = argv[i];
		}
	}
	if (modes != 1) {
		fprintf(stderr, "pkginfo: %s\n",
		    modes ? "too many options" : "option missing");
		return 1;
	}
	if (mode == 'f')
		return package_footprint(arg);
	struct database db = {0};
	if (db_read(&db, root) < 0)
		return 1;
	int result = 0;
	if (mode == 'i') {
		for (size_t i = 0; i < db.count; i++)
			printf("%s %s\n", db.packages[i].name,
			    db.packages[i].version);
	} else if (mode == 'o') {
		result = owners(&db, arg);
	} else {
		bool found = false;
		for (size_t i = 0; i < db.count; i++) {
			if (strcmp(db.packages[i].name, arg))
				continue;
			found = true;
			for (size_t j = 0; j < db.packages[i].count; j++)
				puts(db.packages[i].files[j]);
			break;
		}
		if (!found) {
			struct stat st;
			if (lstat(arg, &st) == 0) {
				result = package_list(arg);
			} else {
				fprintf(stderr,
				    "pkginfo: %s is neither an installed "
				    "package nor a package file\n",
				    arg);
				result = 1;
			}
		}
	}
	db_free(&db);
	if (fflush(stdout) || ferror(stdout))
		result = 1;
	return result;
}
