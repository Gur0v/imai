/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cancel/cancel.h"
#include "commands/ldconfig.h"
#include "db/db.h"
#include "fs/fs.h"

int
pkgrm_run(int argc, char **argv)
{
	const char *root = "/", *name = NULL;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-r") || !strcmp(argv[i], "--root")) {
			if (i + 1 == argc) {
				fprintf(stderr,
				    "pkgrm: option %s requires an argument\n",
				    argv[i]);
				return 1;
			}
			root = argv[++i];
		} else if (argv[i][0] == '-' || (name && *name)) {
			fprintf(stderr, "pkgrm: invalid option %s\n", argv[i]);
			return 1;
		} else {
			name = argv[i];
		}
	}
	if (!name || !*name) {
		fputs("pkgrm: option missing\n", stderr);
		return 1;
	}
	if (getuid()) {
		fputs("pkgrm: only root can remove packages\n", stderr);
		return 1;
	}
	size_t length;
	if (ckd_add(&length, strlen(root), 2)) {
		fputs("pkgrm: root path too long\n", stderr);
		return 1;
	}
	char *normalized = malloc(length);
	if (!normalized) {
		fprintf(stderr, "pkgrm: could not allocate root path: %s\n",
		    strerror(errno));
		return 1;
	}
	char *cursor = normalized;
	for (const char *read = root; *read; read++) {
		if (*read != '/' || cursor == normalized || cursor[-1] != '/')
			*cursor++ = *read;
	}
	if (cursor == normalized || cursor[-1] != '/')
		*cursor++ = '/';
	*cursor = '\0';
	root = normalized;
	struct database db = {0};
	struct package removed = {0};
	int result = 1;
	int fd = open(*root ? root : "/", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr,
		    "pkgrm: could not read directory %svar/lib/pkg: %s\n",
		    root, strerror(errno));
		free(normalized);
		return 1;
	}
	if (fs_root_check(fd) < 0) {
		fprintf(stderr,
		    "pkgrm: required root-scoped lookup unavailable: %s\n",
		    strerror(errno));
		goto out;
	}
	if (db_open_root(&db, fd, root, "pkgrm") < 0)
		goto out;
	bool found = false;
	for (size_t i = 0; i < db.count; i++) {
		if (strcmp(db.packages[i].name, name))
			continue;
		found = true;
		for (size_t j = 0; j < db.packages[i].count; j++) {
			const char *path = db.packages[i].files[j];
			if (fs_path_check(path) < 0) {
				fprintf(stderr,
				    "pkgrm: unsafe database path: %s\n", path);
				goto out;
			}
		}
		break;
	}
	if (!found) {
		fprintf(stderr, "pkgrm: package %s not installed\n", name);
		goto out;
	}
	if (cancel_begin() < 0)
		goto out;
	if (db_remove(&db, name, &removed) < 0)
		goto finish;
	for (size_t i = removed.count; i; i--) {
		if (fs_remove(fd, removed.files[i - 1]) < 0 &&
		    errno != ENOENT && errno != ENOTDIR)
			fprintf(stderr, "pkgrm: could not remove %s%s%s: %s\n",
			    root,
			    *root && root[strlen(root) - 1] == '/' ? "" : "/",
			    removed.files[i - 1], strerror(errno));
	}
	result = 0;
	if (command_ldconfig(fd, "pkgrm") < 0)
		result = 1;
	if (db_commit(&db) < 0) {
		fprintf(stderr, "pkgrm: could not write database: %s\n",
		    strerror(errno));
		result = 1;
	}
finish:
	if (cancel_end("pkgrm") < 0)
		fprintf(stderr,
		    "pkgrm: could not restore signal handlers: %s\n",
		    strerror(errno));
out:
	package_free(&removed);
	db_free(&db);
	close(fd);
	free(normalized);
	return result;
}
