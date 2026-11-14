/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "cancel/cancel.h"
#include "commands/ldconfig.h"
#include "fs/fs.h"

int
command_ldconfig(int root, const char *command)
{
	int config = fs_entry(root, "etc/ld.so.conf");
	if (config < 0)
		return 0;
	close(config);
	int errors[2];
	if (pipe2(errors, O_CLOEXEC) < 0) {
		fprintf(stderr, "%s: could not prepare helper: %s\n", command,
		    strerror(errno));
		return -1;
	}
	pid_t child = fork();
	if (child < 0) {
		fprintf(stderr, "%s: fork() failed: %s\n", command,
		    strerror(errno));
		close(errors[0]);
		close(errors[1]);
		return -1;
	}
	if (!child) {
		close(errors[0]);
		const char *failure = NULL;
		if (cancel_child() < 0)
			failure = "could not restore helper signals";
		else if (fchdir(root) < 0)
			failure = "could not enter root";
		int saved = errno;
		if (failure) {
			if (!strcmp(command, "pkgadd"))
				failure = "could not prepare helper";
		} else {
			execl("/sbin/ldconfig", "/sbin/ldconfig", "-r", ".",
			    (char *)NULL);
			failure = "could not execute /sbin/ldconfig";
			saved = errno;
		}
		fprintf(
		    stderr, "%s: %s: %s\n", command, failure, strerror(saved));
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
		fprintf(stderr, "%s: could not read helper status: %s\n",
		    command, strerror(errno));
	close(errors[0]);
	while (waitpid(child, NULL, 0) < 0) {
		if (errno == EINTR)
			continue;
		fprintf(stderr, "%s: waitpid() failed: %s\n", command,
		    strerror(errno));
		return -1;
	}
	return received == 0 ? 0 : -1;
}
