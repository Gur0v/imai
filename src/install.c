/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <archive.h>
#include <archive_entry.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "archive.h"
#include "fs.h"
#include "install.h"

int
install_paths_check(const struct package_archive *package)
{
	for (size_t i = 0; i < package->count; i++) {
		const char *path = archive_entry_pathname(package->entries[i]);
		if (!path) {
			errno = EINVAL;
			return -1;
		}
		if (fs_path_check(path) < 0)
			return -1;
		const char *target =
		    archive_entry_hardlink(package->entries[i]);
		if (target && fs_path_check(target) < 0)
			return -1;
	}
	return 0;
}

int
install_metadata_check(const struct package_archive *package)
{
	for (size_t i = 0; i < package->count; i++) {
		la_int64_t uid = archive_entry_uid(package->entries[i]);
		la_int64_t gid = archive_entry_gid(package->entries[i]);
		struct archive_entry *entry = package->entries[i];
		long atime_nsec = archive_entry_atime_nsec(entry);
		long mtime_nsec = archive_entry_mtime_nsec(entry);
		if ((archive_entry_atime_is_set(entry) &&
		        (atime_nsec < 0 || atime_nsec >= 1000000000)) ||
		    (archive_entry_mtime_is_set(entry) &&
		        (mtime_nsec < 0 || mtime_nsec >= 1000000000))) {
			errno = EINVAL;
			return -1;
		}
		if ((archive_entry_filetype(entry) == AE_IFCHR ||
		        archive_entry_filetype(entry) == AE_IFBLK) &&
		    (major(archive_entry_rdev(entry)) !=
		            (uint64_t)archive_entry_rdevmajor(entry) ||
		        minor(archive_entry_rdev(entry)) !=
		            (uint64_t)archive_entry_rdevminor(entry))) {
			errno = EOVERFLOW;
			return -1;
		}
		if (uid < 0 || gid < 0 || (la_int64_t)(uid_t)uid != uid ||
		    (la_int64_t)(gid_t)gid != gid || (uid_t)uid == (uid_t)-1 ||
		    (gid_t)gid == (gid_t)-1) {
			errno = EOVERFLOW;
			return -1;
		}
	}
	return 0;
}

static int
metadata_apply(int fd, struct archive_entry *entry)
{
	struct timespec times[2] = {
	    {.tv_sec = archive_entry_atime(entry),
	        .tv_nsec = archive_entry_atime_nsec(entry)},
	    {.tv_sec = archive_entry_mtime(entry),
	        .tv_nsec = archive_entry_mtime_nsec(entry)},
	};
	if (!archive_entry_atime_is_set(entry))
		times[0].tv_nsec = UTIME_OMIT;
	if (!archive_entry_mtime_is_set(entry))
		times[1].tv_nsec = UTIME_OMIT;
	if (fchown(fd, archive_entry_uid(entry), archive_entry_gid(entry)) <
	        0 ||
	    fchmod(fd, archive_entry_perm(entry)) < 0 ||
	    futimens(fd, times) < 0)
		return -1;
	return 0;
}

/* Simulate header order; select live entries through scoped lookup. */
struct planned {
	char *path;
	mode_t type;
	const char *target;
	bool fresh;
	char *owned_target;
};

static int
plan_resolve(int root, const char *name, struct planned *plan, size_t count,
    char **resolved, mode_t *type, bool follow_final, bool *textual_loop)
{
	if (textual_loop)
		*textual_loop = false;
	char *pending = strdup(name), *path = strdup("");
	unsigned int links = 0;
	bool synthetic = false;
	int result = -1;
	if (!pending || !path)
		goto out;
	*type = AE_IFDIR;
	while (*pending) {
		char *slash = strchr(pending, '/');
		size_t n = slash ? (size_t)(slash - pending) : strlen(pending);
		char *tail = strdup(slash ? slash + 1 : "");
		if (!tail)
			goto out;
		if (!n || (n == 1 && pending[0] == '.')) {
			free(pending);
			pending = tail;
			continue;
		}
		if (n == 2 && !strncmp(pending, "..", n)) {
			char *last = strrchr(path, '/');
			if (last)
				*last = '\0';
			else
				*path = '\0';
			free(pending);
			pending = tail;
			synthetic = false;
			continue;
		}
		char *candidate;
		if (asprintf(&candidate, "%s%s%.*s", path, *path ? "/" : "",
		        (int)n, pending) < 0) {
			free(tail);
			goto out;
		}
		bool parent_synthetic = synthetic;
		const char *target = NULL;
		char *owned_target = NULL;
		bool found = false;
		for (size_t i = count; i > 0; i--) {
			size_t length = strlen(candidate);
			if (plan[i - 1].type &&
			    !strncmp(plan[i - 1].path, candidate, length) &&
			    plan[i - 1].path[length] == '/') {
				*type = AE_IFDIR;
				found = true;
				break;
			}
			if (!strcmp(candidate, plan[i - 1].path)) {
				*type = plan[i - 1].type;
				target = plan[i - 1].target;
				synthetic |= plan[i - 1].fresh;
				found = true;
				break;
			}
		}
		if (!found && !synthetic) {
			int fd = fs_entry(root, candidate);
			if (fd < 0 && errno != ENOENT) {
				free(candidate);
				free(tail);
				goto out;
			}
			if (fd >= 0) {
				struct stat st;
				if (fstat(fd, &st) < 0) {
					close(fd);
					free(candidate);
					free(tail);
					goto out;
				}
				*type = st.st_mode & S_IFMT;
				if (S_ISLNK(st.st_mode) &&
				    (follow_final || *tail)) {
					/* Classify the pinned link, not its
					 * stale live target:
					 * tmpfs/ext2/ext3/ext4 links are
					 * textual, never magic links. */
					struct statfs filesystem;
					bool textual =
					    fstatfs(fd, &filesystem) == 0 &&
					    (filesystem.f_type ==
					            TMPFS_MAGIC ||
					        filesystem.f_type ==
					            EXT4_SUPER_MAGIC);
					if (!textual) {
						int followed =
						    fs_follow(root, candidate);
						if (followed < 0 &&
						    errno != ENOENT &&
						    errno != ENOTDIR) {
							close(fd);
							free(candidate);
							free(tail);
							goto out;
						}
						if (followed >= 0)
							close(followed);
					}
					size_t capacity = 128;
					for (;;) {
						owned_target =
						    malloc(capacity);
						if (!owned_target)
							break;
						ssize_t length = readlinkat(fd,
						    "", owned_target,
						    capacity - 1);
						if (length < 0) {
							free(owned_target);
							owned_target = NULL;
							break;
						}
						if ((size_t)length <
						    capacity - 1) {
							owned_target[length] =
							    '\0';
							break;
						}
						free(owned_target);
						capacity *= 2;
					}
					target = owned_target;
				}
				close(fd);
				found = true;
			}
		}
		if (!found) {
			*type = 0;
			synthetic = true;
		}
		if (*type == AE_IFLNK && (!follow_final && !*tail)) {
			free(owned_target);
			free(path);
			path = candidate;
			free(pending);
			pending = tail;
			continue;
		}
		if (*type == AE_IFLNK) {
			if (!target || ++links > 40) {
				if (textual_loop && target)
					*textual_loop = true;
				errno = ELOOP;
				free(owned_target);
				free(candidate);
				free(tail);
				goto out;
			}
			char *next;
			if (asprintf(&next, "%s%s%s", target, *tail ? "/" : "",
			        tail) < 0)
				next = NULL;
			synthetic = parent_synthetic;
			if (*target == '/') {
				*path = '\0';
				synthetic = false;
			}
			free(owned_target);
			free(candidate);
			free(tail);
			free(pending);
			pending = next;
			if (!pending)
				goto out;
			continue;
		}
		free(path);
		path = candidate;
		free(pending);
		pending = tail;
		/* Nondirectory parents are operational errors, not lookup
		 * escapes. */
		if (*pending && *type && *type != AE_IFDIR) {
			synthetic = true;
			*type = 0;
		}
	}
	*resolved = path;
	path = NULL;
	result = 0;
out:
	free(pending);
	free(path);
	return result;
}

static int
plan_nonempty(int root, const char *path, struct planned *plan, size_t count)
{
	size_t length = strlen(path);
	for (size_t i = 0; i < count; i++) {
		if (!plan[i].type || strncmp(plan[i].path, path, length) ||
		    plan[i].path[length] != '/')
			continue;
		bool current = true;
		for (size_t j = i + 1; j < count; j++)
			if (!strcmp(plan[i].path, plan[j].path))
				current = false;
		if (current)
			return 1;
	}
	for (size_t i = count; i > 0; i--) {
		if (!strcmp(plan[i - 1].path, path)) {
			if (plan[i - 1].fresh)
				return 0;
			break;
		}
	}
	int fd = fs_directory(root, path);
	if (fd < 0)
		return errno == ENOENT || errno == ENOTDIR ? 0 : -1;
	DIR *directory = fdopendir(fd);
	if (!directory) {
		int saved = errno;
		close(fd);
		errno = saved;
		return -1;
	}
	int result = 0;
	struct dirent *child;
	errno = 0;
	while ((child = readdir(directory))) {
		if (!strcmp(child->d_name, ".") ||
		    !strcmp(child->d_name, ".."))
			continue;
		char *key;
		if (asprintf(&key, "%s/%s", path, child->d_name) < 0) {
			result = -1;
			break;
		}
		bool exists = true;
		for (size_t i = count; i > 0; i--) {
			if (!strcmp(plan[i - 1].path, key)) {
				exists = plan[i - 1].type != 0;
				break;
			}
		}
		free(key);
		if (exists) {
			result = 1;
			break;
		}
		errno = 0;
	}
	if (!child && errno)
		result = -1;
	int saved = errno;
	closedir(directory);
	errno = saved;
	return result;
}

int
install_preflight_routes_after(int root, const struct package_archive *package,
    const char *const *paths, const char *const *alternates,
    const char *const *removals, size_t removal_count)
{
	if (install_paths_check(package) < 0 ||
	    install_metadata_check(package) < 0 || fs_root_check(root) < 0)
		return -1;
	/* Probe without changing an object; unsupported flags must fail
	 * closed. */
	if (syscall(SYS_fchmodat2, -1, "", 0600, AT_EMPTY_PATH) >= 0 ||
	    errno != EBADF)
		return -1;
	if (removal_count > SIZE_MAX - package->count - 1) {
		errno = EOVERFLOW;
		return -1;
	}
	size_t capacity = package->count + removal_count + 1;
	for (size_t i = 0; i < package->count; i++) {
		if (archive_entry_filetype(package->entries[i]) != AE_IFDIR ||
		    archive_entry_hardlink(package->entries[i]))
			continue;
		const char *names[] = {
		    paths ? paths[i]
		          : archive_entry_pathname(package->entries[i]),
		    alternates ? alternates[i] : NULL};
		for (size_t j = 0; j < 2; j++) {
			if (!names[j])
				continue;
			size_t length = strlen(names[j]);
			if (length > SIZE_MAX - capacity) {
				errno = EOVERFLOW;
				return -1;
			}
			capacity += length;
		}
	}
	struct planned *plan = calloc(capacity, sizeof(*plan));
	if (!plan)
		return -1;
	size_t count = 0;
	int result = -1;
	for (size_t i = 0; i < removal_count; i++) {
		if (fs_path_check(removals[i]) < 0)
			goto out;
		char *path = NULL;
		mode_t type;
		if (plan_resolve(root, removals[i], plan, count, &path, &type,
		        false, NULL) < 0)
			goto out;
		size_t length = strlen(removals[i]);
		if ((!strcmp(path, "") || !strcmp(path, ".")) ||
		    (type != AE_IFDIR && removals[i][length - 1] == '/')) {
			free(path);
			continue;
		}
		if (type == AE_IFDIR) {
			int nonempty = plan_nonempty(root, path, plan, count);
			if (nonempty < 0) {
				free(path);
				goto out;
			}
			if (nonempty) {
				free(path);
				continue;
			}
		}
		plan[count++] = (struct planned){path, 0, NULL, true, NULL};
	}
	for (size_t i = 0; i < package->count; i++) {
		struct archive_entry *entry = package->entries[i];
		mode_t type = archive_entry_filetype(entry);
		const char *hard = archive_entry_hardlink(entry);
		if (!hard && type != AE_IFREG && type != AE_IFDIR &&
		    type != AE_IFLNK && type != AE_IFIFO && type != AE_IFCHR &&
		    type != AE_IFBLK) {
			errno = ENOTSUP;
			goto out;
		}
		const char *name =
		    paths ? paths[i] : archive_entry_pathname(entry);
		if (!name)
			continue;
		if (alternates && alternates[i]) {
			char *selected = NULL;
			mode_t exists;
			if (plan_resolve(root, name, plan, count, &selected,
			        &exists, false, NULL) < 0)
				goto out;
			free(selected);
			if (exists)
				name = alternates[i];
		}
		char *path = fs_archive_path(name);
		if (!path)
			goto out;
		size_t length = strlen(path);
		while (length > 1 && path[length - 1] == '/')
			path[--length] = '\0';
		if (!hard && type == AE_IFDIR) {
			for (char *end = strchr(path, '/'); end;
			    end = strchr(end + 1, '/')) {
				*end = '\0';
				char *resolved = NULL;
				mode_t previous;
				int checked = plan_resolve(root, path, plan,
				    count, &resolved, &previous, true, NULL);
				free(resolved);
				resolved = NULL;
				if (!checked && previous != AE_IFDIR) {
					mode_t binding;
					checked = plan_resolve(root, path,
					    plan, count, &resolved, &binding,
					    false, NULL);
					/* A dangling alias cannot be replaced
					 * by the implicit-directory creation
					 * path. */
					if (!checked &&
					    (previous ||
					        binding != AE_IFLNK)) {
						plan[count++] =
						    (struct planned){resolved,
						        AE_IFDIR, NULL, true,
						        NULL};
						resolved = NULL;
					}
				}
				free(resolved);
				*end = '/';
				if (checked < 0) {
					free(path);
					goto out;
				}
			}
		}
		char *slash = strrchr(path, '/');
		const char *base = slash ? slash + 1 : path;
		if (slash)
			*slash = '\0';
		char *parent = NULL;
		mode_t previous;
		if (plan_resolve(root, slash ? path : ".", plan, count,
		        &parent, &previous, true, NULL) < 0) {
			free(path);
			goto out;
		}
		char *destination;
		if (asprintf(&destination, "%s%s%s", parent,
		        *parent ? "/" : "", base) < 0)
			destination = NULL;
		free(parent);
		free(path);
		if (!destination)
			goto out;
		bool fresh = true;
		if (!hard && type == AE_IFDIR) {
			char *resolved = NULL;
			bool planned_link = false, textual_loop;
			for (size_t j = count; j > 0; j--)
				if (!strcmp(destination, plan[j - 1].path)) {
					planned_link =
					    plan[j - 1].type == AE_IFLNK;
					break;
				}
			if (plan_resolve(root, destination, plan, count,
			        &resolved, &previous, true,
			        &textual_loop) < 0) {
				/* A planned textual cycle is replaced at its
				 * final binding, not traversed. Kernel lookup
				 * failures still reject the archive, including
				 * magic links. */
				if (!planned_link || !textual_loop) {
					free(destination);
					goto out;
				}
				previous = 0;
			}
			if (previous == AE_IFDIR) {
				free(destination);
				destination = resolved;
				resolved = NULL;
				fresh = false;
			}
			free(resolved);
		}
		/* Failed directory replacement preserves the live binding. */
		bool retained_directory = false;
		if (hard || type != AE_IFDIR) {
			char *current = NULL;
			mode_t current_type;
			if (plan_resolve(root, destination, plan, count,
			        &current, &current_type, false, NULL) < 0) {
				free(destination);
				goto out;
			}
			if (current_type == AE_IFDIR) {
				int nonempty =
				    plan_nonempty(root, current, plan, count);
				if (nonempty < 0) {
					free(current);
					free(destination);
					goto out;
				}
				retained_directory = nonempty != 0;
			}
			free(current);
		}
		if (retained_directory) {
			free(destination);
			continue;
		}
		char *owned_target = NULL;
		const char *link_target =
		    type == AE_IFLNK ? archive_entry_symlink(entry) : NULL;
		if (hard) {
			char *source = fs_archive_path(hard);
			if (!source) {
				free(destination);
				goto out;
			}
			char *end = strrchr(source, '/');
			const char *source_base = end ? end + 1 : source;
			if (end)
				*end = '\0';
			char *resolved = NULL;
			int checked = plan_resolve(root, end ? source : ".",
			    plan, count, &resolved, &previous, true, NULL);
			if (!checked) {
				char *key;
				if (asprintf(&key, "%s%s%s", resolved,
				        *resolved ? "/" : "", source_base) < 0)
					checked = -1;
				else {
					bool planned_source = false;
					for (size_t j = count; j > 0; j--) {
						if (!strcmp(key,
						        plan[j - 1].path)) {
							planned_source = true;
							type =
							    plan[j - 1].type;
							link_target =
							    plan[j - 1].target;
							break;
						}
					}
					if (!planned_source) {
						int fd = fs_entry(root, key);
						struct stat st;
						if (fd >= 0 &&
						    !fstat(fd, &st) &&
						    S_ISLNK(st.st_mode)) {
							size_t capacity = 128;
							for (;;) {
								owned_target =
								    malloc(
								        capacity);
								if (!owned_target) {
									checked =
									    -1;
									break;
								}
								ssize_t n =
								    readlinkat(
								        fd, "",
								        owned_target,
								        capacity -
								            1);
								if (n < 0) {
									checked =
									    -1;
									break;
								}
								if ((size_t)n <
								    capacity -
								        1) {
									owned_target
									    [n] =
									        '\0';
									type =
									    AE_IFLNK;
									link_target =
									    owned_target;
									break;
								}
								free(
								    owned_target);
								capacity *= 2;
							}
						}
						if (fd >= 0)
							close(fd);
					}
					free(key);
				}
			}
			free(source);
			free(resolved);
			if (checked < 0) {
				free(owned_target);
				free(destination);
				goto out;
			}
		}
		plan[count++] = (struct planned){
		    destination, type, link_target, fresh, owned_target};
	}
	result = 0;
out:
	for (size_t i = 0; i < count; i++) {
		free(plan[i].path);
		free(plan[i].owned_target);
	}
	free(plan);
	return result;
}

int
install_preflight_routes(int root, const struct package_archive *package,
    const char *const *paths, const char *const *alternates)
{
	return install_preflight_routes_after(
	    root, package, paths, alternates, NULL, 0);
}

int
install_preflight(
    int root, const struct package_archive *package, const char *const *paths)
{
	return install_preflight_routes(root, package, paths, NULL);
}

struct fixup {
	char *path;
	char *sort_path;
	struct archive_entry *entry;
	size_t order;
	bool times;
};

static int
fixup_compare(const void *left, const void *right)
{
	const struct fixup *a = left, *b = right;
	int compared = strcmp(b->sort_path, a->sort_path);
	if (compared)
		return compared;
	return (a->order > b->order) - (a->order < b->order);
}

static int
object_metadata(int fd, struct archive_entry *entry, bool ownership,
    bool permissions, bool timestamps)
{
	struct timespec times[2] = {
	    {archive_entry_atime(entry), archive_entry_atime_nsec(entry)},
	    {archive_entry_mtime(entry), archive_entry_mtime_nsec(entry)},
	};
	if (!archive_entry_atime_is_set(entry))
		times[0].tv_nsec = UTIME_OMIT;
	if (!archive_entry_mtime_is_set(entry))
		times[1].tv_nsec = UTIME_OMIT;
	if (ownership && fchownat(fd, "", archive_entry_uid(entry),
	                     archive_entry_gid(entry),
	                     AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW) < 0)
		return -1;
	if (permissions && syscall(SYS_fchmodat2, fd, "",
	                       archive_entry_perm(entry), AT_EMPTY_PATH) < 0)
		return -1;
	if (timestamps &&
	    utimensat(fd, "", times, AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW) < 0)
		return -1;
	return 0;
}

/* Only directory headers may replace nondirectory parents. Unlink the final
 * binding, not its symlink target; dangling aliases remain errors. */
static int
directory_parents(int root, char *path)
{
	for (char *slash = strchr(path, '/'); slash;
	    slash = strchr(slash + 1, '/')) {
		*slash = '\0';
		int fd = fs_follow(root, path);
		int result = 0;
		if (fd >= 0) {
			struct stat st;
			result = fstat(fd, &st);
			close(fd);
			if (!result && !S_ISDIR(st.st_mode))
				result = fs_remove(root, path);
		} else if (errno != ENOENT) {
			result = -1;
		}
		if (!result)
			result = fs_mkdirs(root, path);
		*slash = '/';
		if (result < 0)
			return -1;
	}
	return 0;
}

int
install_extract_dynamic(int root, struct package_archive *package,
    const char *const *paths, bool upgrade,
    const char *(*choose)(size_t index, void *context),
    int (*done)(size_t index, bool success, void *context), void *context)
{
	if (fseeko(package->stream, 0, SEEK_SET) < 0)
		return -1;
	struct archive *reader = archive_read_new();
	struct fixup *fixups = calloc(package->count + 1, sizeof(*fixups));
	if (!reader || !fixups) {
		archive_read_free(reader);
		free(fixups);
		errno = ENOMEM;
		return -1;
	}
	size_t count = 0, index = 0;
	int result = 0, saved = 0;
	if (archive_read_support_format_tar(reader) != ARCHIVE_OK ||
	    archive_read_open_FILE(reader, package->stream) != ARCHIVE_OK) {
		saved = EIO;
		result = -1;
		goto out;
	}
	struct archive_entry *entry;
	int status;
	while ((status = archive_read_next_header(reader, &entry)) ==
	       ARCHIVE_OK) {
		if (index >= package->count) {
			saved = EIO;
			result = -1;
			goto out;
		}
		const char *name =
		    choose ? choose(index, context)
		           : (paths ? paths[index]
		                    : archive_entry_pathname(entry));
		int extracted = 0;
		char *path = name ? fs_archive_path(name) : NULL;
		if (name && !path)
			extracted = -1;
		if (path) {
			size_t length = strlen(path);
			while (length > 1 && path[length - 1] == '/')
				path[--length] = '\0';
			const char *hard = archive_entry_hardlink(entry);
			mode_t type = archive_entry_filetype(entry);
			char *slash = strrchr(path, '/');
			if (!hard && type == AE_IFDIR) {
				extracted = directory_parents(root, path);
			} else if (slash) {
				*slash = '\0';
				extracted = fs_mkdirs(root, path);
				*slash = '/';
			}
			if (!extracted && !hard && type == AE_IFDIR) {
				int before = fs_follow(root, path);
				struct stat st;
				bool existing = before >= 0 &&
				                !fstat(before, &st) &&
				                S_ISDIR(st.st_mode);
				if (before >= 0)
					close(before);
				if (!existing && fs_remove(root, path) < 0 &&
				    errno != ENOENT)
					extracted = -1;
				if (!extracted)
					extracted = fs_mkdirs(root, path);
				int fd = extracted ? -1 : fs_entry(root, path);
				if (!extracted && fd < 0)
					extracted = -1;
				if (fd >= 0) {
					extracted = object_metadata(
					    fd, entry, true, false, existing);
					close(fd);
				}
				if (!extracted) {
					char *sort_path = strdup(name);
					if (!sort_path) {
						extracted = -1;
					} else {
						/* Upstream collapses repeated
						 * separators, but retains dot
						 * components for fixups. */
						char *write = sort_path;
						for (const char *read = name;
						    *read; read++)
							if (*read != '/' ||
							    write ==
							        sort_path ||
							    write[-1] != '/')
								*write++ =
								    *read;
						*write = '\0';
						fixups[count++] =
						    (struct fixup){path,
						        sort_path,
						        package
						            ->entries[index],
						        index, !existing};
						path = NULL;
					}
				}
			} else if (!extracted) {
				if (fs_remove(root, path) < 0 &&
				    errno != ENOENT)
					extracted = -1;
				if (!extracted && hard) {
					extracted = fs_link(root, hard, path);
				} else if (!extracted && type == AE_IFREG) {
					extracted = install_regular(
					    root, path, reader, entry);
				} else if (!extracted) {
					if (type == AE_IFLNK)
						extracted = fs_symlink(root,
						    archive_entry_symlink(
						        entry),
						    path);
					else
						extracted = fs_node(root, path,
						    type | 0600,
						    archive_entry_rdev(entry));
					if (!extracted) {
						int fd = fs_entry(root, path);
						extracted =
						    fd < 0
						        ? -1
						        : object_metadata(fd,
						              entry, true,
						              type != AE_IFLNK,
						              true);
						if (fd >= 0)
							close(fd);
					}
				}
			}
		}
		free(path);
		int error = errno;
		if (done && done(index, extracted == 0, context) < 0) {
			extracted = -1;
			error = errno;
		}
		index++;
		if (extracted < 0) {
			if (!saved)
				saved = error;
			result = -1;
			if (!upgrade)
				goto out;
		}
	}
	if (status != ARCHIVE_EOF || index != package->count) {
		saved = EIO;
		result = -1;
	}
out:
	/* Upstream fresh-install failures bypass disk-writer finalization. */
	if (!result || upgrade) {
		qsort(fixups, count, sizeof(*fixups), fixup_compare);
		for (size_t i = 0; i < count; i++) {
			int fd = fs_entry(root, fixups[i].path);
			struct stat st;
			if (fd >= 0 && !fstat(fd, &st) &&
			    S_ISDIR(st.st_mode)) {
				{
					struct archive_entry *copy =
					    archive_entry_clone(
					        fixups[i].entry);
					if (copy && !fixups[i].times) {
						archive_entry_unset_atime(
						    copy);
						archive_entry_unset_mtime(
						    copy);
					}
					if (!copy ||
					    object_metadata(fd, copy, false,
					        true, fixups[i].times) < 0) {
						if (!saved)
							saved = copy ? errno
							             : ENOMEM;
						result = -1;
					}
					archive_entry_free(copy);
				}
			}
			if (fd >= 0)
				close(fd);
		}
	}
	for (size_t i = 0; i < count; i++) {
		free(fixups[i].path);
		free(fixups[i].sort_path);
	}
	free(fixups);
	archive_read_free(reader);
	errno = saved;
	return result;
}

int
install_extract(int root, struct package_archive *package,
    const char *const *paths, bool upgrade,
    int (*done)(size_t index, bool success, void *context), void *context)
{
	return install_extract_dynamic(
	    root, package, paths, upgrade, NULL, done, context);
}

int
install_stream(int root, struct package_archive *package)
{
	if (install_preflight(root, package, NULL) < 0)
		return -1;
	return install_extract(root, package, NULL, false, NULL, NULL);
}

int
install_regular(int root, const char *path, struct archive *reader,
    struct archive_entry *entry)
{
	int fd = fs_create(root, path);
	if (fd < 0)
		return -1;
	int result = -1;
	if (archive_read_data_into_fd(reader, fd) != ARCHIVE_OK) {
		errno = EIO;
		goto out;
	}
	if (metadata_apply(fd, entry) < 0)
		goto out;
	result = 0;
out:
	int saved = errno;
	if (close(fd) < 0 && !result)
		return -1;
	errno = saved;
	return result;
}
