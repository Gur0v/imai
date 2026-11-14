#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/statfs.h>
#include <unistd.h>
#include "archive/archive.h"
#include "extraction/install.h"
int __real_fstatfs(int fd, struct statfs *buf);
int __wrap_fstatfs(int fd, struct statfs *buf)
{
	const char *fault = getenv("STATFS_FAULT");
	if (fault && !strcmp(fault, "error")) {
		errno = EIO;
		return -1;
	}
	int result = __real_fstatfs(fd, buf);
	if (!result && fault && !strcmp(fault, "unknown"))
		buf->f_type = 0;
	return result;
}
int main(int argc, char **argv)
{
	if (argc != 3) return 1;
	struct package_archive p = {0};
	if (package_archive_open(argv[1], &p)) return 1;
	int root = open("/tmp/root", O_PATH | O_DIRECTORY);
	if (root < 0) return 1;
	int result;
	if (!strcmp(argv[2], "dangling")) {
		const char *originals[] = {"victim", "dangling"};
		const char *alternates[] = {NULL, "proc/self/fd/0/kept"};
		result = install_preflight_routes_after(root, &p, originals, alternates,
		    NULL, 0);
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	if (!strcmp(argv[2], "implicit")) {
		const char *originals[] = {"created/file", "created/"};
		const char *alternates[] = {NULL, "proc/self/fd/0/kept"};
		const char *removals[] = {"created"};
		result = install_preflight_routes_after(root, &p, originals, alternates,
		    removals, 1);
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	if (!strcmp(argv[2], "routes")) {
		const char *originals[] = {"real/file", "alias/file", "after"};
		const char *alternates[] = {NULL, "blocked/self/fd/0/kept", NULL};
		result = install_preflight_routes_after(root, &p, originals, alternates,
		    NULL, 0);
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	result = install_preflight(root, &p, NULL);
	if (!strcmp(argv[2], "reject") || !strcmp(argv[2], "failure")) {
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	if (result < 0) { perror("preflight"); return 1; }
	struct rlimit limit = {32, 32};
	if (setrlimit(RLIMIT_NOFILE, &limit)) return 1;
	result = install_extract_dynamic(root, &p, NULL, true, NULL, NULL, NULL);
	if (result) perror("extract");
	package_archive_free(&p);
	close(root);
	return !strcmp(argv[2], "partial") ? result >= 0 : result < 0;
}
