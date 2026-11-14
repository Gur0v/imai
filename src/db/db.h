/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IMAI_DB_H
#define IMAI_DB_H
#include <stddef.h>

struct package {
	char *name;
	char *version;
	char **files;
	size_t count;
};

struct database {
	struct package *packages;
	size_t count;
	int directory;
	bool locked;
	bool exclusive;
};

int db_open(struct database *db, const char *root, bool exclusive,
    const char *command);
int db_open_root(
    struct database *db, int rootfd, const char *root, const char *command);
int db_commit(struct database *db);
int package_record_check(const struct package *pkg);
/* Consume the record on success; retain caller ownership on failure. */
int db_add(struct database *db, struct package *pkg);
/* Transfer the removed record and its unshared paths to an empty output. */
int db_remove(struct database *db, const char *name, struct package *removed);
void package_free(struct package *pkg);
int db_read(struct database *db, const char *root);
void db_free(struct database *db);
int pkginfo_run(int argc, char **argv);
int pkgrm_run(int argc, char **argv);
#endif
