/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "rejmerge-controller.h"
#include "rejmerge-workflow.h"

static int
permissions(const char *path, mode_t mode, uid_t uid, gid_t gid)
{
	struct stat st;

	if (lstat(path, &st) < 0)
		return -1;
	if (S_ISLNK(st.st_mode))
		return lchown(path, uid, gid);
	if (chown(path, uid, gid) < 0)
		return -1;
	return chmod(path, mode);
}

static int
internal(int argc, char **argv)
{
	struct stat source;

	if (argc == 2 && strcmp(argv[0], "metadata") == 0) {
		if (stat(argv[1], &source) < 0)
			goto error;
		printf("%o %ju %ju\n", (unsigned int)(source.st_mode & 07777),
		    (uintmax_t)source.st_uid, (uintmax_t)source.st_gid);
		if (fflush(stdout) == EOF)
			goto error;
		return 0;
	}
	if (argc == 5 && strcmp(argv[0], "set-permissions") == 0) {
		uintmax_t values[3];
		for (int i = 0; i < 3; i++) {
			char *end;
			errno = 0;
			if (!argv[i + 2][0] ||
			    strspn(
			        argv[i + 2], i ? "0123456789" : "01234567") !=
			        strlen(argv[i + 2]))
				goto invalid;
			values[i] = strtoumax(argv[i + 2], &end, i ? 10 : 8);
			if (errno || *end)
				goto invalid;
		}
		if (values[0] > 07777 || values[1] != (uid_t)values[1] ||
		    values[2] != (gid_t)values[2])
			goto invalid;
		if (permissions(argv[1], (mode_t)values[0], (uid_t)values[1],
		        (gid_t)values[2]) < 0)
			goto error;
		return 0;
	}
invalid:
	fputs("rejmerge: invalid internal operation\n", stderr);
	return 1;
error:
	fprintf(stderr, "rejmerge: %s: %s\n", argv[0], strerror(errno));
	return 1;
}

static void
usage(const char *command)
{
	printf("usage: %s [options]\noptions:\n", command);
	puts("  -r,   --root <path>         specify alternative root\n"
	     "  -v,   --version             print version and exit \n"
	     "  -h,   --help                print help and exit");
}

static int
validate(int argc, char **argv, const char *command)
{
	char *rejected = strdup("/var/lib/pkg/rejected");
	struct stat st;
	int result = 1;

	if (!rejected)
		goto error;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-r") == 0 ||
		    strcmp(argv[i], "--root") == 0) {
			if (i + 1 == argc || !argv[i + 1][0]) {
				printf("%s: option %s requires an argument\n",
				    command, argv[i]);
				goto out;
			}
			char *next;
			if (asprintf(&next, "%s%s", argv[++i], rejected) < 0)
				goto error;
			free(rejected);
			rejected = next;
		} else if (strcmp(argv[i], "-v") == 0 ||
		           strcmp(argv[i], "--version") == 0) {
			printf("%s (imai) %s\n", command, VERSION);
			result = 0;
			goto out;
		} else if (strcmp(argv[i], "-h") == 0 ||
		           strcmp(argv[i], "--help") == 0) {
			usage(command);
			result = 0;
			goto out;
		} else {
			printf("%s: invalid option %s\n", command, argv[i]);
			goto out;
		}
	}
	if (stat(rejected, &st) < 0 || !S_ISDIR(st.st_mode)) {
		printf("%s: %s not found\n", command, rejected);
		goto out;
	}
	if (getuid() != 0) {
		printf("%s: only root can merge rejected files\n", command);
		goto out;
	}
	result = -1;
	goto out;
error:
	perror(command);
out:
	free(rejected);
	return result;
}

int
main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "--imai-workflow") == 0) {
		if (argc != 4 ||
		    strspn(argv[2], "0123456789") != strlen(argv[2]) ||
		    strspn(argv[3], "0123456789") != strlen(argv[3])) {
			fputs("rejmerge: invalid workflow descriptors\n",
			    stderr);
			return 1;
		}
		return rejmerge_workflow(atoi(argv[2]), atoi(argv[3]));
	}
	if (argc > 1 && strcmp(argv[1], "--imai-internal") == 0)
		return internal(argc - 2, argv + 2);

	const char *command = strrchr(argv[0], '/');
	command = command ? command + 1 : argv[0];
	int status = validate(argc, argv, command);
	if (status >= 0)
		return status;

	char *binary = realpath("/proc/self/exe", NULL);
	char **args = calloc((size_t)argc + 5, sizeof(*args));
	if (!binary || !args) {
		perror(command);
		free(binary);
		free(args);
		return 1;
	}
	args[0] = "bash";
	args[1] = "-c";
	args[2] = (char *)rejmerge_controller;
	args[3] = argv[0];
	args[4] = binary;
	for (int i = 1; i < argc; i++)
		args[i + 4] = argv[i];
	execv("/bin/bash", args);
	fprintf(stderr, "%s: /bin/bash: %s\n", command, strerror(errno));
	free(binary);
	free(args);
	return 1;
}
