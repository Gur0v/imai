/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <unistd.h>

#include "pkgmk-controller.h"
#include "pkgmk-workflow.h"

static int
digest_file(const EVP_MD *algorithm, const char *name, const char *command)
{
	unsigned char buffer[32768], digest[EVP_MAX_MD_SIZE];
	unsigned int length;
	size_t count;
	FILE *file;
	EVP_MD_CTX *context;
	int result = 1;

	file = strcmp(name, "-") == 0 ? stdin : fopen(name, "rb");
	if (!file) {
		fprintf(
		    stderr, "%s: %s: %s\n", command, name, strerror(errno));
		return 1;
	}
	context = EVP_MD_CTX_new();
	if (!context || EVP_DigestInit_ex(context, algorithm, NULL) != 1)
		goto crypto_error;
	while (!feof(file) && !ferror(file)) {
		count = fread(buffer, 1, sizeof(buffer), file);
		if (EVP_DigestUpdate(context, buffer, count) != 1)
			goto crypto_error;
	}
	if (ferror(file)) {
		fprintf(
		    stderr, "%s: %s: %s\n", command, name, strerror(errno));
		goto out;
	}
	if (EVP_DigestFinal_ex(context, digest, &length) != 1)
		goto crypto_error;
	if (file != stdin) {
		int status = fclose(file);
		file = NULL;
		if (status != 0) {
			fprintf(stderr, "%s: %s: %s\n", command, name,
			    strerror(errno));
			goto out;
		}
	}
	bool escaped = strpbrk(name, "\\\n\r") != NULL;
	if (escaped)
		putchar('\\');
	for (unsigned int i = 0; i < length; i++)
		printf("%02x", digest[i]);
	fputs("  ", stdout);
	for (const char *p = name; *p; p++) {
		switch (*p) {
		case '\\':
			fputs("\\\\", stdout);
			break;
		case '\n':
			fputs("\\n", stdout);
			break;
		case '\r':
			fputs("\\r", stdout);
			break;
		default:
			putchar((unsigned char)*p);
			break;
		}
	}
	putchar('\n');
	result = 0;
	goto out;

crypto_error:
	fprintf(stderr, "%s: %s: digest computation failed\n", command, name);
out:
	EVP_MD_CTX_free(context);
	if (file && file != stdin)
		fclose(file);
	return result;
}

static int
internal(int argc, char **argv)
{
	struct stat st;

	if (argc >= 2 && strcmp(argv[0], "digest") == 0) {
		const EVP_MD *algorithm;
		const char *command;
		int result = 0;
		if (strcmp(argv[1], "md5") == 0) {
			algorithm = EVP_md5();
			command = "md5sum";
		} else if (strcmp(argv[1], "sha256") == 0) {
			algorithm = EVP_sha256();
			command = "sha256sum";
		} else {
			goto invalid;
		}
		if (argc == 2)
			result = digest_file(algorithm, "-", command);
		for (int i = 2; i < argc; i++)
			result |= digest_file(algorithm, argv[i], command);
		if (fflush(stdout) == EOF || ferror(stdout)) {
			fprintf(stderr, "%s: write error: %s\n", command,
			    strerror(errno));
			result = 1;
		}
		return result;
	}
	if (argc == 2 && strcmp(argv[0], "check-tmpfs") == 0) {
		struct statfs fs;
		struct statvfs mount;
		int fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		const char *reason = NULL;
		if (fd < 0)
			reason = strerror(errno);
		else if (fstatfs(fd, &fs) < 0 || fstatvfs(fd, &mount) < 0)
			reason = strerror(errno);
		else if (fs.f_type != TMPFS_MAGIC)
			reason = "not tmpfs";
		else if (mount.f_flag & (ST_NOEXEC | ST_RDONLY))
			reason = "tmpfs is noexec or read-only";
		else if (faccessat(fd, ".", R_OK | W_OK | X_OK, AT_EACCESS) <
		         0)
			reason = strerror(errno);
		if (fd >= 0)
			close(fd);
		if (reason)
			fprintf(stderr, "pkgmk: tmpfs directory %s: %s\n",
			    argv[1], reason);
		return reason ? 1 : 0;
	}
	if (argc == 2 && strcmp(argv[0], "check-directory") == 0) {
		if (stat(argv[1], &st) < 0 || !S_ISDIR(st.st_mode))
			return 1;
		if (faccessat(AT_FDCWD, argv[1], W_OK, AT_EACCESS) < 0)
			return 2;
		if (faccessat(AT_FDCWD, argv[1], R_OK | X_OK, AT_EACCESS) < 0)
			return 3;
		return 0;
	}
	if (argc == 2 && strcmp(argv[0], "check-file") == 0)
		return stat(argv[1], &st) == 0 &&
		       faccessat(AT_FDCWD, argv[1], W_OK, AT_EACCESS) < 0;
invalid:
	fputs("pkgmk: invalid internal operation\n", stderr);
	return 1;
}

int
main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "--imai-internal") == 0)
		return internal(argc - 2, argv + 2);

	char *command = NULL;
	size_t capacity = 256;
	for (;;) {
		char *next = realloc(command, capacity);
		if (!next) {
			free(command);
			perror("pkgmk");
			return 1;
		}
		command = next;
		ssize_t length =
		    readlink("/proc/self/exe", command, capacity - 1);
		if (length < 0) {
			perror("pkgmk: /proc/self/exe");
			free(command);
			return 1;
		}
		if ((size_t)length < capacity - 1) {
			command[length] = '\0';
			break;
		}
		if (capacity > (size_t)-1 / 2) {
			free(command);
			return 1;
		}
		capacity *= 2;
	}

	char **args = calloc((size_t)argc + 6, sizeof(*args));
	if (!args) {
		perror("pkgmk");
		free(command);
		return 1;
	}
	args[0] = "bash";
	args[1] = "-c";
	args[2] = (char *)pkgmk_controller;
	args[3] = argv[0];
	args[4] = VERSION;
	args[5] = command;
	for (int i = 1; i < argc; i++)
		args[i + 5] = argv[i];
	int status = pkgmk_workflow_launch(args);
	free(args);
	free(command);
	return status;
}
