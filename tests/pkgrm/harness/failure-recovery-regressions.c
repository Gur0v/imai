#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc < 3)
		return 125;
	if (!strcmp(argv[1], "wait")) {
		/* SIG_IGN survives exec and makes waitpid return ECHILD. */
		if (signal(SIGCHLD, SIG_IGN) == SIG_ERR)
			return 125;
	} else {
		struct sock_filter filter[] = {
		    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
		        offsetof(struct seccomp_data, nr)),
		    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_clone, 0, 1),
		    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EAGAIN),
		    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_clone3, 0, 1),
		    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EAGAIN),
		    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
		};
		struct sock_fprog program = {
		    .len = sizeof(filter) / sizeof(*filter),
		    .filter = filter,
		};
		if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0 ||
		    prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) < 0)
			return 125;
	}
	execv(argv[2], argv + 2);
	return 126;
}
