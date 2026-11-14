/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <stdckdint.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "db.h"

static void *
grow(void *ptr, size_t count, size_t size)
{
	size_t bytes;
	if (ckd_mul(&bytes, count, size)) {
		errno = ENOMEM;
		return NULL;
	}
	return realloc(ptr, bytes);
}

static int
strings_compare(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static int
packages_compare(const void *a, const void *b)
{
	return strcmp(((const struct package *)a)->name,
	    ((const struct package *)b)->name);
}

void
package_free(struct package *pkg)
{
	free(pkg->name);
	free(pkg->version);
	for (size_t i = 0; i < pkg->count; i++)
		free(pkg->files[i]);
	free(pkg->files);
	*pkg = (struct package){0};
}

void
db_free(struct database *db)
{
	for (size_t i = 0; i < db->count; i++)
		package_free(&db->packages[i]);
	free(db->packages);
	if (db->locked)
		close(db->directory);
	*db = (struct database){0};
}

static int
line_read(FILE *file, char **line, size_t *capacity)
{
	if (feof(file))
		return 0;
	ssize_t length = getline(line, capacity, file);
	if (length < 0)
		return ferror(file) ? -1 : 0;
	if (memchr(*line, '\0', (size_t)length)) {
		errno = EINVAL;
		return -1;
	}
	if (length && (*line)[length - 1] == '\n')
		(*line)[length - 1] = '\0';
	return 1;
}

static int
record_add(struct database *db, struct package *pkg, bool keep_empty)
{
	if (!pkg->count && !keep_empty) {
		package_free(pkg);
		return 0;
	}
	if (pkg->count > 1)
		qsort(pkg->files, pkg->count, sizeof(*pkg->files),
		    strings_compare);
	size_t count = 0;
	for (size_t i = 0; i < pkg->count; i++) {
		if (count && !strcmp(pkg->files[count - 1], pkg->files[i]))
			free(pkg->files[i]);
		else
			pkg->files[count++] = pkg->files[i];
	}
	pkg->count = count;
	for (size_t i = 0; i < db->count; i++) {
		if (!strcmp(db->packages[i].name, pkg->name)) {
			package_free(&db->packages[i]);
			db->packages[i] = *pkg;
			*pkg = (struct package){0};
			return 0;
		}
	}
	if (db->count == SIZE_MAX) {
		errno = ENOMEM;
		return -1;
	}
	void *p = grow(db->packages, db->count + 1, sizeof(*db->packages));
	if (!p)
		return -1;
	db->packages = p;
	db->packages[db->count++] = *pkg;
	*pkg = (struct package){0};
	return 0;
}

static int
database_open(struct database *db, int rootfd, const char *root,
    bool exclusive, const char *command)
{
	size_t length;
	if (ckd_add(&length, strlen(root), sizeof("/var/lib/pkg"))) {
		errno = ENOMEM;
		return -1;
	}
	char *directory = malloc(length);
	if (!directory)
		return -1;
	snprintf(directory, length, "%s/var/lib/pkg", root);
	char *write = directory;
	for (const char *read = directory; *read; read++) {
		if (*read == '/' && write > directory && write[-1] == '/')
			continue;
		*write++ = *read;
	}
	*write = '\0';
	struct open_how how = {
	    .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	int dir;
	if (rootfd >= 0)
		dir = syscall(
		    SYS_openat2, rootfd, "var/lib/pkg", &how, sizeof(how));
	else
		dir = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (dir < 0) {
		fprintf(stderr, "%s: could not read directory %s: %s\n",
		    command, directory, strerror(errno));
		free(directory);
		return -1;
	}
	if (flock(dir, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) < 0) {
		fprintf(stderr, "%s: %s\n", command,
		    errno == EWOULDBLOCK ? "package database is currently "
		                           "locked by another process"
		                         : strerror(errno));
		close(dir);
		free(directory);
		return -1;
	}
	int fd = openat(
	    dir, "db", O_RDONLY | O_CLOEXEC | (rootfd >= 0 ? O_NOFOLLOW : 0));
	if (fd < 0) {
		fprintf(stderr, "%s: could not open %s/db: %s\n", command,
		    directory, strerror(errno));
		close(dir);
		free(directory);
		return -1;
	}
	free(directory);
	FILE *file = fdopen(fd, "r");
	if (!file) {
		int saved = errno;
		close(fd);
		close(dir);
		fprintf(stderr, "%s: could not read database: %s\n", command,
		    strerror(saved));
		return -1;
	}
	char *line = NULL;
	size_t capacity = 0;
	struct package pkg = {0};
	int result = -1, status;
	while ((status = line_read(file, &line, &capacity)) > 0) {
		if (!(pkg.name = strdup(line)))
			goto done;
		status = line_read(file, &line, &capacity);
		if (status < 0)
			goto done;
		if (!(pkg.version = strdup(status ? line : "")))
			goto done;
		while ((status = line_read(file, &line, &capacity)) > 0 &&
		       *line) {
			if (pkg.count == SIZE_MAX) {
				errno = ENOMEM;
				goto done;
			}
			void *p =
			    grow(pkg.files, pkg.count + 1, sizeof(*pkg.files));
			if (!p)
				goto done;
			pkg.files = p;
			if (!(pkg.files[pkg.count] = strdup(line)))
				goto done;
			pkg.count++;
		}
		if (status < 0 || record_add(db, &pkg, false) < 0)
			goto done;
	}
	if (status < 0)
		goto done;
	if (db->count > 1)
		qsort(db->packages, db->count, sizeof(*db->packages),
		    packages_compare);
	result = 0;
done:;
	int saved = errno;
	package_free(&pkg);
	free(line);
	if (fclose(file) && result == 0) {
		saved = errno;
		result = -1;
	}
	if (result == 0) {
		db->directory = dir;
		db->locked = true;
		db->exclusive = exclusive;
	} else {
		close(dir);
	}
	if (result < 0) {
		fprintf(stderr, "%s: could not read database: %s\n", command,
		    strerror(saved));
		db_free(db);
	}
	return result;
}

int
db_open(
    struct database *db, const char *root, bool exclusive, const char *command)
{
	return database_open(db, -1, root, exclusive, command);
}

int
db_open_root(
    struct database *db, int rootfd, const char *root, const char *command)
{
	return database_open(db, rootfd, root, true, command);
}

int
db_read(struct database *db, const char *root)
{
	return db_open(db, root, false, "pkginfo");
}

int
package_record_check(const struct package *pkg)
{
	/* Newlines delimit database fields; an empty path ends a record. */
	if (strchr(pkg->name, '\n') || strchr(pkg->version, '\n')) {
		errno = EINVAL;
		return -1;
	}
	for (size_t i = 0; i < pkg->count; i++) {
		if (!*pkg->files[i] || strchr(pkg->files[i], '\n')) {
			errno = EINVAL;
			return -1;
		}
	}
	return 0;
}

int
db_add(struct database *db, struct package *pkg)
{
	if (!db->locked || !db->exclusive) {
		errno = EPERM;
		return -1;
	}
	if (package_record_check(pkg) < 0 || record_add(db, pkg, true) < 0)
		return -1;
	if (db->count > 1)
		qsort(db->packages, db->count, sizeof(*db->packages),
		    packages_compare);
	return 0;
}

int
db_remove(struct database *db, const char *name, struct package *removed)
{
	if (!db->locked || !db->exclusive) {
		errno = EPERM;
		return -1;
	}
	size_t index;
	for (index = 0; index < db->count; index++)
		if (!strcmp(db->packages[index].name, name))
			break;
	if (index == db->count) {
		errno = ENOENT;
		return -1;
	}
	*removed = db->packages[index];
	memmove(&db->packages[index], &db->packages[index + 1],
	    (db->count - index - 1) * sizeof(*db->packages));
	db->count--;
	size_t count = 0;
	for (size_t i = 0; i < removed->count; i++) {
		bool shared = false;
		for (size_t j = 0; j < db->count; j++) {
			if (bsearch(&removed->files[i], db->packages[j].files,
			        db->packages[j].count, sizeof(char *),
			        strings_compare)) {
				shared = true;
				break;
			}
		}
		if (shared)
			free(removed->files[i]);
		else
			removed->files[count++] = removed->files[i];
	}
	removed->count = count;
	return 0;
}

int
db_commit(struct database *db)
{
	if (!db->locked || !db->exclusive) {
		errno = EPERM;
		return -1;
	}
	int dir = db->directory;
	if (unlinkat(dir, "db.incomplete_transaction", 0) < 0 &&
	    errno != ENOENT)
		return -1;
	int fd = openat(dir, "db.incomplete_transaction",
	    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0444);
	if (fd < 0)
		return -1;
	FILE *file = fdopen(fd, "w");
	if (!file) {
		int saved = errno;
		close(fd);
		errno = saved;
		return -1;
	}
	int result = -1;
	for (size_t i = 0; i < db->count; i++) {
		const struct package *pkg = &db->packages[i];
		if (!pkg->count)
			continue;
		if (fprintf(file, "%s\n%s\n", pkg->name, pkg->version) < 0)
			goto done;
		for (size_t j = 0; j < pkg->count; j++)
			if (fprintf(file, "%s\n", pkg->files[j]) < 0)
				goto done;
		if (fputc('\n', file) == EOF)
			goto done;
	}
	if (fflush(file) != 0 || fsync(fd) < 0)
		goto done;
	if (unlinkat(dir, "db.backup", 0) < 0 && errno != ENOENT)
		goto done;
	if (linkat(dir, "db", dir, "db.backup", 0) < 0)
		goto done;
	if (renameat(dir, "db.incomplete_transaction", dir, "db") < 0)
		goto done;
	result = 0;
done:;
	int saved = errno;
	if (fclose(file) != 0 && result == 0) {
		saved = errno;
		result = -1;
	}
	errno = saved;
	return result;
}
