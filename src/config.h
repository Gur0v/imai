/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IMAI_CONFIG_H
#define IMAI_CONFIG_H

#include <stddef.h>

enum config_event { CONFIG_INSTALL, CONFIG_UPGRADE };

struct config_rule {
	enum config_event event;
	char *pattern;
	bool action;
};

struct config {
	struct config_rule *rules;
	size_t count;
};

int config_read(struct config *config, const char *filename);
/* Takes ownership of fd; filename is used only for diagnostics. */
int config_read_fd(struct config *config, int fd, const char *filename);
int config_action(const struct config *config, enum config_event event,
    const char *path, bool *action);
void config_free(struct config *config);

#endif
