/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IMAI_FS_H
#define IMAI_FS_H

#include <sys/types.h>

int fs_root_check(int root);
int fs_directory(int root, const char *path);
/* Pin the final entry itself, including a symlink, without following it. */
int fs_entry(int root, const char *path);
int fs_follow(int root, const char *path);
int fs_path_check(const char *path);
/* Return an owned writable descriptor for a new 0600 regular file only. */
int fs_create(int root, const char *path);
int fs_symlink(int root, const char *target, const char *path);
int fs_node(int root, const char *path, mode_t mode, dev_t device);
int fs_mkdirs(int root, const char *path);
/* Neither replace an existing destination nor follow the final source link. */
int fs_link(int root, const char *source, const char *destination);
/* Own the operation path; retain original names for rules and ownership. */
char *fs_archive_path(const char *path);

/* Root-relative lookup grants authority retained across parent relocation. */
int fs_remove(int root, const char *path);

#endif
