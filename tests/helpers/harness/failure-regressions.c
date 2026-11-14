#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>
#include "cancel/cancel.h"
#include "db/db.h"
#include "commands/pkgadd/pkgadd.h"

int pkgrm_run(int argc, char **argv);
static const char *failure;
static bool removing;
static int commits;
static int channel = -1;
ssize_t __real_read(int fd, void *buffer, size_t count);
int __real_pipe2(int pipefd[2], int flags);
pid_t __real_fork(void);
pid_t __real_waitpid(pid_t pid, int *status, int options);
int __real_fchdir(int fd);
int __real_db_commit(struct database *db);
int __real_cancel_child(void);

int
__wrap_cancel_child(void)
{
	if (!strcmp(failure, "signals")) {
		kill(getppid(), SIGTERM);
		errno = EACCES;
		return -1;
	}
	return __real_cancel_child();
}

int
__wrap_execl(const char *path, const char *arg, ...)
{
	if (!strcmp(failure, "exec")) {
		kill(getppid(), SIGTERM);
		errno = ENOENT;
		return -1;
	}
	char *args[] = {(char *)arg, "-r", ".", NULL};
	return execv(path, args);
}

int
__wrap_pipe2(int pipefd[2], int flags)
{
	if (!strcmp(failure, "pipe")) {
		raise(SIGTERM);
		errno = EMFILE;
		return -1;
	}
	int result = __real_pipe2(pipefd, flags);
	if (!result)
		channel = pipefd[0];
	return result;
}

ssize_t
__wrap_read(int fd, void *buffer, size_t count)
{
	if (fd == channel && !strcmp(failure, "read")) {
		raise(SIGTERM);
		errno = EIO;
		return -1;
	}
	return __real_read(fd, buffer, count);
}

pid_t
__wrap_fork(void)
{
	if (!strcmp(failure, "fork")) {
		raise(SIGTERM);
		errno = EAGAIN;
		return -1;
	}
	return __real_fork();
}

pid_t
__wrap_waitpid(pid_t pid, int *status, int options)
{
	pid_t result = __real_waitpid(pid, status, options);
	if (result >= 0 && (!strcmp(failure, "wait") ||
	    !strcmp(failure, "combined"))) {
		raise(SIGTERM);
		errno = ECHILD;
		return -1;
	}
	return result;
}

int
__wrap_fchdir(int fd)
{
	if (!strcmp(failure, "child")) {
		kill(getppid(), SIGTERM);
		errno = EACCES;
		return -1;
	}
	return __real_fchdir(fd);
}

int
__wrap_db_commit(struct database *db)
{
	commits++;
	if (!strcmp(failure, "commit") ||
	    (removing && !strcmp(failure, "combined"))) {
		raise(SIGTERM);
		errno = EIO;
		return -1;
	}
	return __real_db_commit(db);
}

int
main(int argc, char **argv)
{
	if (argc != 3)
		return 2;
	removing = !strcmp(argv[1], "pkgrm");
	failure = argv[2];
	char *args[] = {argv[1], "-r", "/tmp/root", removing ? "alpha" :
	    "/tmp/alpha#1.pkg.tar.gz", NULL};
	int result = removing ? pkgrm_run(4, args) : pkgadd_run(4, args);
	if (result != 1 || commits != 1)
		return 3;
	/* Same-process checks prove restoration, not merely process-exit cleanup. */
	struct sigaction action;
	if (sigaction(SIGTERM, NULL, &action) < 0 || action.sa_handler != SIG_DFL ||
	    cancel_begin() < 0 || cancel_end("probe") < 0)
		return 4;
	int fd = open("/tmp/root/var/lib/pkg", O_RDONLY | O_DIRECTORY);
	if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) < 0 || close(fd) < 0)
		return 5;
	return 0;
}
