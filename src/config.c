/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <errno.h>
#include <regex.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"

static int
config_parse(struct config *config, FILE *file, const char *filename)
{
	char *line = NULL;
	size_t capacity = 0, number = 0;
	int result = -1;
	ssize_t length;
	while ((length = getline(&line, &capacity, file)) >= 0) {
		number++;
		if (length && line[length - 1] == '\n')
			line[--length] = '\0';
		if (!length || line[0] == '#')
			continue;
		const char *error = NULL;
		char event[1024], pattern[1024], action[1024], extra[1024];
		if (length >= 1024)
			error = "line too long";
		else if (sscanf(line, "%1023s %1023s %1023s %1023s", event,
		             pattern, action, extra) != 3)
			error = "wrong number of arguments";
		if (error) {
			fprintf(stderr, "pkgadd: %s:%zu: %s, aborting\n",
			    filename, number, error);
			goto out;
		}
		enum config_event kind;
		if (!strcmp(event, "INSTALL"))
			kind = CONFIG_INSTALL;
		else if (!strcmp(event, "UPGRADE"))
			kind = CONFIG_UPGRADE;
		else {
			fprintf(stderr,
			    "pkgadd: %s:%zu: '%s' unknown event, "
			    "aborting\n",
			    filename, number, event);
			goto out;
		}
		bool enabled;
		if (!strcmp(action, "YES"))
			enabled = true;
		else if (!strcmp(action, "NO"))
			enabled = false;
		else {
			fprintf(stderr,
			    "pkgadd: %s:%zu: '%s' unknown action, "
			    "should be YES or NO, aborting\n",
			    filename, number, action);
			goto out;
		}
		size_t count, bytes;
		if (ckd_add(&count, config->count, 1) ||
		    ckd_mul(&bytes, count, sizeof(*config->rules))) {
			errno = ENOMEM;
			goto read_error;
		}
		void *rules = realloc(config->rules, bytes);
		if (!rules)
			goto read_error;
		config->rules = rules;
		char *copy = strdup(pattern);
		if (!copy)
			goto read_error;
		config->rules[config->count++] = (struct config_rule){
		    .event = kind, .pattern = copy, .action = enabled};
	}
	if (ferror(file))
		goto read_error;
	result = 0;
	goto out;
read_error:
	fprintf(stderr, "pkgadd: could not read configuration %s: %s\n",
	    filename, strerror(errno));
out:
	free(line);
	fclose(file);
	if (result < 0)
		config_free(config);
	return result;
}

int
config_read(struct config *config, const char *filename)
{
	FILE *file = fopen(filename, "r");
	if (!file)
		return 0;
	return config_parse(config, file, filename);
}

int
config_read_fd(struct config *config, int fd, const char *filename)
{
	FILE *file = fdopen(fd, "r");
	if (!file) {
		int saved = errno;
		close(fd);
		errno = saved;
		fprintf(stderr,
		    "pkgadd: could not read configuration %s: %s\n", filename,
		    strerror(errno));
		return -1;
	}
	return config_parse(config, file, filename);
}

int
config_action(const struct config *config, enum config_event event,
    const char *path, bool *action)
{
	*action = true;
	for (size_t i = config->count; i; i--) {
		const struct config_rule *rule = &config->rules[i - 1];
		if (rule->event != event)
			continue;
		regex_t regex;
		if (regcomp(&regex, rule->pattern, REG_EXTENDED | REG_NOSUB)) {
			fprintf(stderr,
			    "pkgadd: error compiling regular expression "
			    "'%s', aborting\n",
			    rule->pattern);
			return -1;
		}
		int match = regexec(&regex, path, 0, NULL, 0);
		regfree(&regex);
		if (!match) {
			*action = rule->action;
			return 0;
		}
		if (match != REG_NOMATCH) {
			fputs("pkgadd: error matching regular expression\n",
			    stderr);
			return -1;
		}
	}
	return 0;
}

void
config_free(struct config *config)
{
	for (size_t i = 0; i < config->count; i++)
		free(config->rules[i].pattern);
	free(config->rules);
	*config = (struct config){0};
}
