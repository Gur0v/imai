/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include "archive.h"
#include "cancel.h"
#include "config.h"
#include "db.h"
#include "fs.h"
#include "install.h"
#include "pkgadd.h"

#define REJECTED "var/lib/pkg/rejected"

struct selection {
	char *name;
	bool install;
	bool keep;
	bool conflict;
};

struct extraction {
	int root;
	struct package_archive *archive;
	char **paths;
	char **originals;
	char **rejected;
	bool *directories;
	unsigned char *messages;
	bool finalize;
};

static const char *
choose_path(size_t index, void *context)
{
	struct extraction *state = context;
	const char *path = state->originals[index];
	state->paths[index] = state->originals[index];
	if (path && state->rejected[index]) {
		int entry = fs_entry(state->root, path);
		if (entry >= 0) {
			close(entry);
			state->paths[index] = state->rejected[index];
		}
	}
	return state->paths[index];
}

static int
path_open(int root, const char *path, int flags)
{
	struct open_how how = {
	    .flags = (unsigned int)(flags | O_CLOEXEC),
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	return syscall(SYS_openat2, root, path, &how, sizeof(how));
}

static bool
contains(const struct package *pkg, const char *path)
{
	for (size_t i = 0; i < pkg->count; i++)
		if (!strcmp(pkg->files[i], path))
			return true;
	return false;
}

static struct package *
find_package(struct database *db, const char *name)
{
	for (size_t i = 0; i < db->count; i++)
		if (!strcmp(db->packages[i].name, name))
			return &db->packages[i];
	return NULL;
}

static int
compare_names(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static int
package_name(struct package *pkg, const char *filename)
{
	const char *base = strrchr(filename, '/');
	base = base ? base + 1 : filename;
	const char *hash = strchr(base, '#');
	const char *extension = NULL;
	for (const char *p = base; (p = strstr(p, ".pkg.tar.")); p++)
		extension = p;
	const char *end = extension ? extension : base + strlen(base);
	if (!hash || hash == base || hash >= end - 1) {
		fprintf(stderr,
		    "pkgadd: could not determine name and/or "
		    "version of %s: Invalid package name\n",
		    base);
		return -1;
	}
	pkg->name = strndup(base, (size_t)(hash - base));
	pkg->version = strndup(hash + 1, (size_t)(end - hash - 1));
	return pkg->name && pkg->version ? 0 : -1;
}

static int
package_record(struct package *pkg, const struct package_archive *archive)
{
	size_t bytes;
	if (ckd_mul(&bytes, archive->count, sizeof(*pkg->files))) {
		errno = ENOMEM;
		return -1;
	}
	pkg->files = malloc(bytes);
	if (!pkg->name || !pkg->version || !pkg->files)
		return -1;
	for (size_t i = 0; i < archive->count; i++) {
		char *name =
		    strdup(archive_entry_pathname(archive->entries[i]));
		if (!name)
			return -1;
		pkg->files[pkg->count++] = name;
	}
	qsort(pkg->files, pkg->count, sizeof(*pkg->files), compare_names);
	size_t count = 0;
	for (size_t i = 0; i < pkg->count; i++) {
		if (count && !strcmp(pkg->files[count - 1], pkg->files[i]))
			free(pkg->files[i]);
		else
			pkg->files[count++] = pkg->files[i];
	}
	pkg->count = count;
	return 0;
}

static struct selection *
selection_find(struct selection *files, size_t count, const char *path)
{
	for (size_t i = 0; i < count; i++)
		if (!strcmp(files[i].name, path))
			return &files[i];
	return NULL;
}

static void
remove_paths(int root, const char *rootname, const struct package *pkg,
    struct selection *files, size_t count, bool preserve, bool quiet_directory)
{
	for (size_t i = pkg->count; i; i--) {
		const char *name = pkg->files[i - 1];
		struct selection *file = selection_find(files, count, name);
		if (preserve && file && file->keep)
			continue;
		if (fs_remove(root, name) < 0 && errno != ENOENT &&
		    !(quiet_directory && errno == ENOTEMPTY))
			fprintf(stderr, "pkgadd: could not remove %s%s: %s\n",
			    rootname, name, strerror(errno));
	}
}

static bool
regular_equal(int root, const char *a, const char *b)
{
	int left = path_open(root, a, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
	int right = path_open(root, b, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
	bool equal = false;
	if (left < 0 || right < 0)
		goto out;
	struct stat x, y;
	if (fstat(left, &x) < 0 || fstat(right, &y) < 0 ||
	    !S_ISREG(x.st_mode) || !S_ISREG(y.st_mode) ||
	    x.st_size != y.st_size)
		goto out;
	char lbuf[8192], rbuf[8192];
	for (;;) {
		ssize_t n = read(left, lbuf, sizeof(lbuf));
		if (n < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		size_t got = 0;
		while (got < (size_t)n) {
			ssize_t m = read(right, rbuf + got, (size_t)n - got);
			if (m < 0 && errno == EINTR)
				continue;
			if (m <= 0)
				goto out;
			got += (size_t)m;
		}
		if (memcmp(lbuf, rbuf, (size_t)n))
			break;
		if (!n) {
			char byte;
			equal = read(right, &byte, 1) == 0;
			break;
		}
	}
out:
	if (left >= 0)
		close(left);
	if (right >= 0)
		close(right);
	return equal;
}

static bool
rejected_equal(int root, const char *rejected, const char *original)
{
	int left = fs_entry(root, rejected), right = fs_entry(root, original);
	struct stat a, b;
	bool equal = false;
	if (left < 0 || right < 0 || fstat(left, &a) < 0 ||
	    fstat(right, &b) < 0)
		goto out;
	if (a.st_mode != b.st_mode || a.st_uid != b.st_uid ||
	    a.st_gid != b.st_gid)
		goto out;
	if (S_ISDIR(a.st_mode) || (S_ISREG(a.st_mode) && !a.st_size))
		equal = true;
	else if (S_ISREG(a.st_mode))
		equal = regular_equal(root, rejected, original);
	else if (S_ISLNK(a.st_mode)) {
		char x[4096], y[4096];
		ssize_t nx = readlinkat(left, "", x, sizeof(x));
		ssize_t ny = readlinkat(right, "", y, sizeof(y));
		equal = nx >= 0 && nx < (ssize_t)sizeof(x) && nx == ny &&
		        !memcmp(x, y, (size_t)nx);
	} else if (S_ISCHR(a.st_mode) || S_ISBLK(a.st_mode)) {
		/* Preserve upstream's st_dev comparison, not st_rdev. */
		equal = a.st_dev == b.st_dev;
	}
out:
	if (left >= 0)
		close(left);
	if (right >= 0)
		close(right);
	return equal;
}

static int
extracted(size_t index, bool success, void *context)
{
	struct extraction *state = context;
	const char *original =
	    archive_entry_pathname(state->archive->entries[index]);
	const char *path = state->paths[index];
	if (!path) {
		state->messages[index] = 1;
		return 0;
	}
	if (!success) {
		fprintf(stderr, "pkgadd: could not install %s: %s\n", original,
		    strerror(errno));
		return 0;
	}
	if (!strcmp(path, original))
		return 0;
	if (!state->finalize &&
	    archive_entry_filetype(state->archive->entries[index]) ==
	        AE_IFDIR) {
		state->directories[index] = true;
		return 0;
	}
	if (state->finalize) {
		int entry = fs_entry(state->root, path);
		if (entry < 0 && errno == ENOENT)
			return 0;
		if (entry >= 0)
			close(entry);
	}
	if (!rejected_equal(state->root, path, original)) {
		state->messages[index] = 2;
		return 0;
	}
	char *parent = strdup(path);
	if (!parent)
		return -1;
	while (strcmp(parent, REJECTED)) {
		if (fs_remove(state->root, parent) < 0)
			break;
		char *slash = strrchr(parent, '/');
		if (!slash)
			break;
		*slash = '\0';
	}
	free(parent);
	return 0;
}

static int
run_ldconfig(int root)
{
	int config = fs_entry(root, "etc/ld.so.conf");
	if (config < 0)
		return 0;
	close(config);
	int errors[2];
	if (pipe2(errors, O_CLOEXEC) < 0) {
		fprintf(stderr, "pkgadd: could not prepare helper: %s\n",
		    strerror(errno));
		return -1;
	}
	pid_t child = fork();
	if (child < 0) {
		fprintf(
		    stderr, "pkgadd: fork() failed: %s\n", strerror(errno));
		close(errors[0]);
		close(errors[1]);
		return -1;
	}
	if (!child) {
		close(errors[0]);
		if (cancel_child() < 0 || fchdir(root) < 0) {
			fprintf(stderr,
			    "pkgadd: could not prepare helper: %s\n",
			    strerror(errno));
			if (write(errors[1], "!", 1) != 1)
				_exit(1);
			_exit(1);
		}
		execl("/sbin/ldconfig", "/sbin/ldconfig", "-r", ".",
		    (char *)NULL);
		fprintf(stderr,
		    "pkgadd: could not execute /sbin/ldconfig: %s\n",
		    strerror(errno));
		if (write(errors[1], "!", 1) != 1)
			_exit(1);
		_exit(1);
	}
	close(errors[1]);
	char failed;
	ssize_t received;
	do {
		received = read(errors[0], &failed, 1);
	} while (received < 0 && errno == EINTR);
	if (received < 0)
		fprintf(stderr, "pkgadd: could not read helper status: %s\n",
		    strerror(errno));
	close(errors[0]);
	int status;
	while (waitpid(child, &status, 0) < 0) {
		if (errno == EINTR)
			continue;
		fprintf(
		    stderr, "pkgadd: waitpid() failed: %s\n", strerror(errno));
		return -1;
	}
	return received == 0 ? 0 : -1;
}

int
pkgadd_run(int argc, char **argv)
{
	const char *rootarg = "/", *configarg = NULL, *filename = NULL;
	bool upgrade = false, force = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-r") || !strcmp(argv[i], "--root") ||
		    !strcmp(argv[i], "-c") || !strcmp(argv[i], "--config")) {
			bool config = !strcmp(argv[i], "-c") ||
			              !strcmp(argv[i], "--config");
			if (i + 1 == argc) {
				fprintf(stderr,
				    "pkgadd: option %s requires an argument\n",
				    argv[i]);
				return 1;
			}
			if (config)
				configarg = argv[++i];
			else
				rootarg = argv[++i];
		} else if (!strcmp(argv[i], "-u") ||
		           !strcmp(argv[i], "--upgrade"))
			upgrade = true;
		else if (!strcmp(argv[i], "-f") || !strcmp(argv[i], "--force"))
			force = true;
		else if (argv[i][0] == '-' || (filename && *filename)) {
			fprintf(
			    stderr, "pkgadd: invalid option %s\n", argv[i]);
			return 1;
		} else
			filename = argv[i];
	}
	if (!filename || !*filename) {
		fputs("pkgadd: option missing\n", stderr);
		return 1;
	}
	if (getuid()) {
		fputs("pkgadd: only root can install/upgrade packages\n",
		    stderr);
		return 1;
	}
	size_t length;
	if (ckd_add(&length, strlen(rootarg), 2))
		return 1;
	char *rootname = malloc(length);
	if (!rootname)
		return 1;
	char *next = rootname;
	for (const char *p = rootarg; *p; p++)
		if (*p != '/' || next == rootname || next[-1] != '/')
			*next++ = *p;
	if (next == rootname || next[-1] != '/')
		*next++ = '/';
	*next = '\0';
	int result = 1, root = -1;
	bool cancelling = false;
	struct database db = {0};
	struct package_archive archive = {0};
	struct package pkg = {0}, removed = {0};
	struct config config = {0};
	struct selection *files = NULL;
	size_t count = 0;
	char **paths = NULL, **originals = NULL, **rejected = NULL;
	const char **removals = NULL;
	size_t removal_count = 0;
	bool *directories = NULL;
	unsigned char *messages = NULL;
	char *configpath = NULL, *name = NULL;
	root = open(rootname, O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0) {
		fprintf(stderr,
		    "pkgadd: could not read directory %svar/lib/pkg: %s\n",
		    rootname, strerror(errno));
		goto out;
	}
	if (fs_root_check(root) < 0) {
		fprintf(stderr,
		    "pkgadd: required root-scoped lookup unavailable: %s\n",
		    strerror(errno));
		goto out;
	}
	if (db_open_root(&db, root, rootname, "pkgadd") < 0)
		goto out;
	if (package_name(&pkg, filename) < 0 ||
	    package_archive_open_command(filename, &archive, "pkgadd") != 0 ||
	    package_record(&pkg, &archive) < 0)
		goto out;
	if (package_record_check(&pkg) < 0) {
		fprintf(stderr,
		    "pkgadd: package record cannot be represented in "
		    "database: %s\n",
		    strerror(errno));
		goto out;
	}
	if (configarg && *configarg) {
		if (config_read(&config, configarg) < 0)
			goto out;
	} else {
		if (ckd_add(
		        &length, strlen(rootname), sizeof("etc/pkgadd.conf")))
			goto out;
		configpath = malloc(length);
		if (!configpath)
			goto out;
		snprintf(configpath, length, "%setc/pkgadd.conf", rootname);
		int fd = path_open(root, "etc/pkgadd.conf", O_RDONLY);
		if (fd >= 0 && config_read_fd(&config, fd, configpath) < 0)
			goto out;
	}
	if (install_paths_check(&archive) < 0 ||
	    install_metadata_check(&archive) < 0) {
		fprintf(stderr, "pkgadd: archive preflight failed: %s\n",
		    strerror(errno));
		goto out;
	}
	struct package *old = find_package(&db, pkg.name);
	bool installed = old != NULL;
	if (installed != upgrade) {
		fprintf(stderr,
		    installed ? "pkgadd: package %s already installed (use -u "
		                "to upgrade)\n"
		              : "pkgadd: package %s not previously installed "
		                "(skip -u to install)\n",
		    pkg.name);
		goto out;
	}
	count = pkg.count;
	files = calloc(count, sizeof(*files));
	paths = calloc(archive.count, sizeof(*paths));
	originals = calloc(archive.count, sizeof(*originals));
	rejected = calloc(archive.count, sizeof(*rejected));
	directories = calloc(archive.count, sizeof(*directories));
	messages = calloc(archive.count, sizeof(*messages));
	if (!files || !paths || !originals || !rejected || !directories ||
	    !messages)
		goto out;
	bool conflicts = false;
	for (size_t i = 0; i < count; i++) {
		files[i].name = strdup(pkg.files[i]);
		if (!files[i].name ||
		    config_action(&config, CONFIG_INSTALL, files[i].name,
		        &files[i].install) < 0)
			goto out;
		if (!files[i].install)
			continue;
		const char *name = files[i].name;
		int entry = fs_entry(root, name);
		files[i].conflict = entry >= 0;
		if (entry >= 0)
			close(entry);
		for (size_t j = 0; j < db.count; j++)
			if (strcmp(db.packages[j].name, pkg.name) &&
			    contains(&db.packages[j], name))
				files[i].conflict = true;
		if (name[strlen(name) - 1] == '/' ||
		    (old && contains(old, name)))
			files[i].conflict = false;
		conflicts |= files[i].conflict;
	}
	if (conflicts && !force) {
		for (size_t i = 0; i < count; i++)
			if (files[i].conflict)
				fprintf(stderr, "%s\n", files[i].name);
		fputs("pkgadd: listed file(s) already installed "
		      "(use -f to ignore and overwrite)\n",
		    stderr);
		goto out;
	}
	if (upgrade)
		for (size_t i = 0; i < count; i++) {
			bool action = true;
			if (files[i].install &&
			    config_action(&config, CONFIG_UPGRADE,
			        files[i].name, &action) < 0)
				goto out;
			files[i].keep = files[i].install && !action;
		}
	if (old)
		for (size_t i = 0; i < old->count; i++)
			if (fs_path_check(old->files[i]) < 0) {
				fprintf(stderr,
				    "pkgadd: unsafe database path: %s\n",
				    old->files[i]);
				goto out;
			}
	for (size_t i = 0; i < archive.count; i++) {
		const char *name = archive_entry_pathname(archive.entries[i]);
		struct selection *file = selection_find(files, count, name);
		if (!file->install)
			continue;
		originals[i] = strdup(name);
		if (!originals[i])
			goto out;
		if (file->keep) {
			if (ckd_add(
			        &length, sizeof(REJECTED "/"), strlen(name)))
				goto out;
			rejected[i] = malloc(length);
			if (!rejected[i])
				goto out;
			snprintf(rejected[i], length, REJECTED "/%s", name);
		}
		paths[i] = rejected[i] ? rejected[i] : originals[i];
	}
	size_t capacity, bytes;
	if (ckd_add(&capacity, count, old ? old->count : 0) ||
	    ckd_mul(&bytes, capacity, sizeof(*removals)))
		goto out;
	removals = malloc(bytes ? bytes : 1);
	if (!removals)
		goto out;
	if (force)
		for (size_t i = count; i; i--)
			if (files[i - 1].conflict && !files[i - 1].keep)
				removals[removal_count++] = files[i - 1].name;
	if (old)
		for (size_t i = old->count; i; i--) {
			const char *path = old->files[i - 1];
			struct selection *file =
			    selection_find(files, count, path);
			if (file && (file->keep || (force && file->conflict)))
				continue;
			bool shared = false;
			for (size_t j = 0; j < db.count; j++)
				if (&db.packages[j] != old &&
				    contains(&db.packages[j], path))
					shared = true;
			if (!shared)
				removals[removal_count++] = path;
		}
	if (install_preflight_routes_after(root, &archive,
	        (const char *const *)originals, (const char *const *)rejected,
	        removals, removal_count) < 0) {
		fprintf(stderr, "pkgadd: archive preflight failed: %s\n",
		    strerror(errno));
		goto out;
	}
	size_t selected = 0;
	for (size_t i = 0; i < pkg.count; i++) {
		if (files[i].install)
			pkg.files[selected++] = pkg.files[i];
		else
			free(pkg.files[i]);
	}
	pkg.count = selected;
	name = strdup(pkg.name);
	if (!name)
		goto out;
	if (cancel_begin() < 0)
		goto out;
	cancelling = true;
	if (force) {
		for (size_t j = 0; j < db.count; j++) {
			struct package *record = &db.packages[j];
			size_t kept = 0;
			for (size_t k = 0; k < record->count; k++) {
				struct selection *file = selection_find(
				    files, count, record->files[k]);
				if (file && file->conflict)
					free(record->files[k]);
				else
					record->files[kept++] =
					    record->files[k];
			}
			record->count = kept;
		}
		for (size_t i = count; i; i--)
			if (files[i - 1].conflict && !files[i - 1].keep) {
				struct package conflict = {
				    .files = &files[i - 1].name, .count = 1};
				remove_paths(root, rootname, &conflict, NULL,
				    0, false, true);
			}
	}
	if (upgrade) {
		if (db_remove(&db, pkg.name, &removed) < 0)
			goto out;
		remove_paths(
		    root, rootname, &removed, files, count, true, true);
		package_free(&removed);
	}
	if (db_add(&db, &pkg) < 0 || db_commit(&db) < 0) {
		fprintf(stderr, "pkgadd: could not write database: %s\n",
		    strerror(errno));
		goto out;
	}
	struct extraction state = {.root = root,
	    .archive = &archive,
	    .paths = paths,
	    .originals = originals,
	    .rejected = rejected,
	    .directories = directories,
	    .messages = messages};
	int extracted_status = install_extract_dynamic(root, &archive,
	    (const char *const *)originals, upgrade, choose_path, extracted,
	    &state);
	state.finalize = true;
	for (size_t i = 0; i < archive.count; i++)
		if (directories[i] && extracted(i, true, &state) < 0)
			extracted_status = -1;
	/* Directory decisions require final metadata, but output follows
	 * headers. */
	for (size_t i = 0; i < archive.count; i++) {
		const char *path = archive_entry_pathname(archive.entries[i]);
		if (messages[i] == 1)
			printf("pkgadd: ignoring %s\n", path);
		else if (messages[i] == 2)
			printf(
			    "pkgadd: rejecting %s, keeping existing version\n",
			    path);
	}
	if (extracted_status < 0 && !installed) {
		if (db_remove(&db, name, &removed) < 0)
			goto out;
		remove_paths(root, rootname, &removed, NULL, 0, false, false);
		if (db_commit(&db) < 0)
			fprintf(stderr,
			    "pkgadd: could not write database: %s\n",
			    strerror(errno));
		fputs("pkgadd: failed\n", stderr);
		goto out;
	}
	result = run_ldconfig(root) < 0 ? 1 : 0;
out:
	if (cancelling && cancel_end("pkgadd") < 0)
		fprintf(stderr,
		    "pkgadd: could not restore signal handlers: %s\n",
		    strerror(errno));
	for (size_t i = 0; i < archive.count; i++) {
		if (originals)
			free(originals[i]);
		if (rejected)
			free(rejected[i]);
	}
	free(paths);
	free(removals);
	free(originals);
	free(rejected);
	free(directories);
	free(messages);
	free(name);
	if (files)
		for (size_t i = 0; i < count; i++)
			free(files[i].name);
	free(files);
	free(configpath);
	config_free(&config);
	package_free(&pkg);
	package_free(&removed);
	package_archive_free(&archive);
	db_free(&db);
	if (root >= 0)
		close(root);
	free(rootname);
	return result;
}
