#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include "config/config.h"

int
main(int argc, char **argv)
{
	struct config config = {0};
	if (argc != 3)
		return 2;
	if (getenv("CONFIG_FD")) {
		int fd = open(argv[1], O_RDONLY);
		if (fd < 0 || config_read_fd(&config, fd, argv[1]) < 0)
			return 1;
		if (fcntl(fd, F_GETFD) >= 0 || errno != EBADF)
			return 1;
	} else if (config_read(&config, argv[1]) < 0)
		return 1;
	bool action;
	int result = config_action(&config, CONFIG_INSTALL, argv[2], &action);
	if (!result)
		printf("install %s\n", action ? "yes" : "no");
	if (!result) {
		result = config_action(&config, CONFIG_UPGRADE, argv[2], &action);
		if (!result)
			printf("upgrade %s\n", action ? "yes" : "no");
	}
	config_free(&config);
	return result < 0;
}
