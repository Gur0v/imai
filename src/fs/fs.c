/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "fs.h"

int
fs_root_check(int root)
{
	struct open_how how = {
	    .flags = O_PATH | O_DIRECTORY | O_CLOEXEC,
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	int fd = syscall(SYS_openat2, root, ".", &how, sizeof(how));
	if (fd < 0)
		return -1;
	return close(fd);
}

int
fs_entry(int root, const char *path)
{
	if (fs_path_check(path) < 0)
		return -1;
	struct open_how how = {
	    .flags = O_PATH | O_NOFOLLOW | O_CLOEXEC,
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	return syscall(SYS_openat2, root, path, &how, sizeof(how));
}

int
fs_follow(int root, const char *path)
{
	struct open_how how = {
	    .flags = O_PATH | O_CLOEXEC,
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	return syscall(SYS_openat2, root, path, &how, sizeof(how));
}

int
fs_directory(int root, const char *path)
{
	if (fs_path_check(path) < 0)
		return -1;
	struct open_how how = {
	    .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	return syscall(SYS_openat2, root, path, &how, sizeof(how));
}

int
fs_path_check(const char *path)
{
	if (!*path || *path == '/') {
		errno = EINVAL;
		return -1;
	}
	for (const char *part = path; *part;) {
		size_t length = strcspn(part, "/");
		if (length == 2 && part[0] == '.' && part[1] == '.') {
			errno = EINVAL;
			return -1;
		}
		part += length;
		while (*part == '/')
			part++;
	}
	return 0;
}

char *
fs_archive_path(const char *path)
{
	if (!*path || *path == '/') {
		errno = EINVAL;
		return NULL;
	}
	char *normalized = strdup(path);
	if (!normalized)
		return NULL;
	char *write = normalized;
	for (const char *part = path; *part;) {
		size_t length = strcspn(part, "/");
		if (length == 2 && part[0] == '.' && part[1] == '.') {
			free(normalized);
			errno = EINVAL;
			return NULL;
		}
		if (length && !(length == 1 && part[0] == '.')) {
			if (write != normalized)
				*write++ = '/';
			memcpy(write, part, length);
			write += length;
		}
		part += length;
		while (*part == '/')
			part++;
	}
	if (write == normalized)
		*write++ = '.';
	else {
		size_t length = strlen(path);
		if (path[length - 1] == '/' ||
		    (length >= 2 && path[length - 2] == '/' &&
		        path[length - 1] == '.'))
			*write++ = '/';
	}
	*write = '\0';
	return normalized;
}

int
fs_mkdirs(int root, const char *path)
{
	char *copy = fs_archive_path(path);
	if (!copy)
		return -1;
	struct open_how how = {
	    .flags = O_PATH | O_DIRECTORY | O_CLOEXEC,
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	int result = -1;
	for (char *part = copy; *part;) {
		char *end = strchr(part, '/');
		if (end)
			*end = '\0';
		int fd = syscall(SYS_openat2, root, copy, &how, sizeof(how));
		if (fd < 0 && errno == ENOENT) {
			const char *parent = ".";
			if (part != copy) {
				part[-1] = '\0';
				parent = copy;
			}
			int dir = syscall(
			    SYS_openat2, root, parent, &how, sizeof(how));
			if (part != copy)
				part[-1] = '/';
			if (dir < 0)
				goto out;
			int made = mkdirat(dir, part, 0755);
			int saved = errno;
			close(dir);
			errno = saved;
			if (made < 0 && errno != EEXIST)
				goto out;
			/* Re-resolve from the pinned root, never from a
			 * symlink's target directory as a new resolution root.
			 */
			fd = syscall(
			    SYS_openat2, root, copy, &how, sizeof(how));
		}
		if (fd < 0)
			goto out;
		close(fd);
		if (!end)
			break;
		*end = '/';
		part = end + 1;
	}
	result = 0;
out:
	int saved = errno;
	free(copy);
	errno = saved;
	return result;
}

static int
path_parent(int root, char *path, const char **base)
{
	char *slash = strrchr(path, '/');
	const char *parent = ".";
	*base = path;
	if (slash) {
		*slash = '\0';
		*base = slash + 1;
		parent = path;
	}
	struct open_how how = {
	    .flags = O_PATH | O_DIRECTORY | O_CLOEXEC,
	    .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	return syscall(SYS_openat2, root, parent, &how, sizeof(how));
}

int
fs_create(int root, const char *path)
{
	if (fs_path_check(path) < 0)
		return -1;
	char *copy = strdup(path);
	if (!copy)
		return -1;
	const char *base;
	int parent = path_parent(root, copy, &base);
	int fd = -1;
	if (parent >= 0)
		fd = openat(parent, base,
		    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
		    0600);
	int saved = errno;
	if (parent >= 0)
		close(parent);
	free(copy);
	errno = saved;
	return fd;
}

int
fs_symlink(int root, const char *target, const char *path)
{
	if (fs_path_check(path) < 0)
		return -1;
	char *copy = strdup(path);
	if (!copy)
		return -1;
	const char *base;
	int parent = path_parent(root, copy, &base);
	int result = -1;
	if (parent >= 0)
		result = symlinkat(target, parent, base);
	int saved = errno;
	if (parent >= 0)
		close(parent);
	free(copy);
	errno = saved;
	return result;
}

int
fs_node(int root, const char *path, mode_t mode, dev_t device)
{
	if (fs_path_check(path) < 0)
		return -1;
	char *copy = strdup(path);
	if (!copy)
		return -1;
	const char *base;
	int parent = path_parent(root, copy, &base);
	int result = -1;
	if (parent >= 0)
		result = mknodat(parent, base, mode, device);
	int saved = errno;
	if (parent >= 0)
		close(parent);
	free(copy);
	errno = saved;
	return result;
}

int
fs_link(int root, const char *source, const char *destination)
{
	if (fs_path_check(source) < 0 || fs_path_check(destination) < 0)
		return -1;
	char *from = strdup(source);
	char *to = strdup(destination);
	int result = -1, src = -1, dst = -1;
	if (!from || !to)
		goto out;
	const char *srcbase, *dstbase;
	src = path_parent(root, from, &srcbase);
	if (src < 0)
		goto out;
	dst = path_parent(root, to, &dstbase);
	if (dst < 0)
		goto out;
	result = linkat(src, srcbase, dst, dstbase, 0);
out:
	int saved = errno;
	if (src >= 0)
		close(src);
	if (dst >= 0)
		close(dst);
	free(from);
	free(to);
	errno = saved;
	return result;
}

int
fs_remove(int root, const char *path)
{
	if (fs_path_check(path) < 0)
		return -1;
	char *copy = strdup(path);
	if (!copy)
		return -1;
	size_t length = strlen(copy);
	bool directory = copy[length - 1] == '/';
	while (length && copy[length - 1] == '/')
		copy[--length] = '\0';
	const char *base;
	int fd = path_parent(root, copy, &base);
	int result = -1;
	if (fd >= 0) {
		/* AT_REMOVEDIR refuses final symlinks, including names ending
		 * in '/'. */
		result = unlinkat(fd, base, directory ? AT_REMOVEDIR : 0);
		if (result < 0 && !directory && errno == EISDIR)
			result = unlinkat(fd, base, AT_REMOVEDIR);
	}
	int saved = errno;
	if (fd >= 0)
		close(fd);
	free(copy);
	errno = saved;
	return result;
}
