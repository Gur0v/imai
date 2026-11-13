/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IMAI_INSTALL_H
#define IMAI_INSTALL_H

#include <stddef.h>

struct package_archive;
struct archive;
struct archive_entry;

/* Check every header before filtering or mutation; preserve original names. */
int install_paths_check(const struct package_archive *package);
int install_metadata_check(const struct package_archive *package);
/* NULL paths selects original destinations; otherwise NULL entries are
 * skipped. Preflight checks the ordered destination namespace without live
 * mutations. Extraction rechecks scoped lookups; concurrent changes can still
 * cause errors. */
int install_preflight(
    int root, const struct package_archive *package, const char *const *paths);
int install_preflight_routes(int root, const struct package_archive *package,
    const char *const *paths, const char *const *alternates);
/* Removal paths are ordered attempts, not guaranteed deletions. */
int install_preflight_routes_after(int root,
    const struct package_archive *package, const char *const *paths,
    const char *const *alternates, const char *const *removals,
    size_t removal_count);
int install_extract(int root, struct package_archive *package,
    const char *const *paths, bool upgrade,
    int (*done)(size_t index, bool success, void *context), void *context);
/* choose must select only destinations already covered by preflight. */
int install_extract_dynamic(int root, struct package_archive *package,
    const char *const *paths, bool upgrade,
    const char *(*choose)(size_t index, void *context),
    int (*done)(size_t index, bool success, void *context), void *context);
/* Caller owns cancellation and failure cleanup. */
int install_stream(int root, struct package_archive *package);
/* Extract the current regular header to a new entry; retain partial on error.
 * Caller must complete preflight and enter the mutation bracket first. */
int install_regular(int root, const char *path, struct archive *reader,
    struct archive_entry *entry);

#endif
