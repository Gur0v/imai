/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IMAI_ARCHIVE_H
#define IMAI_ARCHIVE_H

#include <stddef.h>
#include <stdio.h>

struct archive_entry;

struct package_archive {
	FILE *stream;
	struct archive_entry **entries;
	size_t count;
};

/* Open into an empty, zero-initialized output; it owns the validated tar
 * snapshot and headers in archive order. Both opens return 0 on success,
 * 1 on failure. */
int package_archive_open(
    const char *filename, struct package_archive *package);
int package_archive_open_command(const char *filename,
    struct package_archive *package, const char *command);
void package_archive_free(struct package_archive *package);
int package_list(const char *filename);
int package_footprint(const char *filename);

#endif
