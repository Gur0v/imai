#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -efu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/failures.c" <<'EOF'
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
#include "cancel.h"
#include "db.h"
#include "pkgadd.h"

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
EOF
# shellcheck disable=SC2046,SC2086
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    ${TEST_CFLAGS:-} -iquote src "$work/failures.c" \
    src/pkgadd.c src/pkgrm.c src/archive.c src/install.c src/config.c src/db.c \
    src/fs.c src/cancel.c -Wl,--wrap=pipe2,--wrap=read,--wrap=fork,--wrap=waitpid,--wrap=fchdir,--wrap=db_commit,--wrap=cancel_child,--wrap=execl \
    $(pkg-config --cflags --libs libarchive) -lz -lbz2 ${TEST_LDFLAGS:-} -o "$work/failures"
printf '#!/bin/dash\nexit 0\n' >"$work/ldconfig"
chmod 755 "$work/ldconfig"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind "$work/failures" /tmp/failures \
    --ro-bind "$work/ldconfig" /sbin/ldconfig -- /bin/dash -eu -c '
mkdir /tmp/payload
printf payload >/tmp/payload/victim
bsdtar -cf /tmp/alpha#1.pkg.tar.gz -C /tmp/payload victim
for command in pkgrm pkgadd; do
    for failure in pipe fork wait child signals exec read commit combined; do
        [ "$command:$failure" != pkgadd:combined ] || continue
        mkdir -p /tmp/root/var/lib/pkg /tmp/root/etc
        : >/tmp/root/etc/ld.so.conf
        if [ "$command" = pkgrm ]; then
            printf "alpha\n1\nvictim\n\nzeta\n2\nshared\n\n" >/tmp/root/var/lib/pkg/db
            : >/tmp/root/victim
            printf "zeta\n2\nshared\n\n" >/tmp/expected
        else
            printf "zeta\n2\nshared\n\n" >/tmp/root/var/lib/pkg/db
            printf "alpha\n1\nvictim\n\nzeta\n2\nshared\n\n" >/tmp/expected
        fi
        cp /tmp/root/var/lib/pkg/db /tmp/before
        /tmp/failures "$command" "$failure" >/tmp/out 2>/tmp/err || {
            printf "FAIL: %s %s\n" "$command" "$failure"
            cat /tmp/err
            exit 1
        }
        [ ! -s /tmp/out ]
        grep "termination request deferred" /tmp/err >/dev/null
        case $failure in
        pipe) grep "could not prepare helper:" /tmp/err >/dev/null ;;
        fork) grep "fork() failed:" /tmp/err >/dev/null ;;
        wait|combined) grep "waitpid() failed:" /tmp/err >/dev/null ;;
        child|signals) grep -E "could not .*root:|could not prepare helper:|could not restore helper signals:" /tmp/err >/dev/null ;;
        exec) grep "could not execute /sbin/ldconfig:" /tmp/err >/dev/null ;;
        read) grep "could not read helper status:" /tmp/err >/dev/null ;;
        esac
        case $failure in
        commit|combined)
            cmp /tmp/before /tmp/root/var/lib/pkg/db
            [ ! -e /tmp/root/var/lib/pkg/db.backup ]
            grep "could not write database:" /tmp/err >/dev/null
            ;;
        *)
            cmp /tmp/expected /tmp/root/var/lib/pkg/db
            cmp /tmp/before /tmp/root/var/lib/pkg/db.backup
            ;;
        esac
        if [ "$command" = pkgrm ]; then
            [ ! -e /tmp/root/victim ]
        elif [ "$failure" != commit ] && [ "$failure" != combined ]; then
            cmp /tmp/payload/victim /tmp/root/victim
        fi
        rm -rf /tmp/root
    done
done
'
printf 'PASS: helper failures finalize database and restore cancellation/locks\n'
