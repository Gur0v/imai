/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <sys/socket.h>
#define VERSION "test"
#define main pkgmk_main
#include "../../../src/commands/pkgmk/pkgmk.c"
#undef main

pid_t __real_fork(void);

pid_t
__wrap_fork(void)
{
	pid_t child = __real_fork();
	if (child == 0)
		raise(SIGTERM);
	return child;
}

int
main(void)
{
	int pair[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) < 0)
		return 90;
	pid_t peer = __real_fork();
	if (peer == 0) {
		close(pair[0]);
		FILE *protocol = fdopen(pair[1], "r+");
		setvbuf(protocol, NULL, _IONBF, 0);
		char *field = NULL;
		size_t size = 0;
		for (int request = 0; request < 2; request++) {
			for (int i = 0; i < 4; i++)
				if (getdelim(&field, &size, 0, protocol) < 0)
					_exit(91);
			if (fwrite("R\0"
			           "0\0\0",
			        1, 5, protocol) != 5)
				_exit(92);
		}
		free(field);
		fclose(protocol);
		_exit(0);
	}
	close(pair[1]);
	if (dup2(pair[0], 63) < 0)
		return 93;
	close(pair[0]);
	char *args[] = {"/bin/true", NULL};
	int result = download_run(args);
	int status;
	if (waitpid(peer, &status, 0) != peer || status != 0)
		return 94;
	if (result != 128 + SIGTERM) {
		fprintf(stderr, "fork-window cancellation lost: %d\n", result);
		return 95;
	}
	return 0;
}
