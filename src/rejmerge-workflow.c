/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

#include "rejmerge-workflow.h"

enum {
	CMD,
	FOUND,
	INSTALLED,
	ENTRY,
	TEMP,
	MERGE,
	ROOT,
	REJECTED,
	VALUE,
	CWD,
	NSTATES
};
static char *state[NSTATES];
static int uiin, uiout;
static struct termios saved;
static bool terminal;
static volatile sig_atomic_t stopped;

static void
signal_request(int signal)
{
	stopped = signal;
}

static void
restore(void)
{
	if (terminal) {
		int result;
		do {
			result = tcsetattr(uiin, TCSANOW, &saved);
		} while (result < 0 && errno == EINTR);
		if (result < 0)
			dprintf(uiout,
			    "rejmerge: cannot restore terminal settings: %s\n",
			    strerror(errno));
		terminal = false;
	}
}

static void
set(int field, const char *value)
{
	char *next = strdup(value);
	if (!next)
		exit(1);
	free(state[field]);
	state[field] = next;
}

static void
put(const char *value)
{
	if (fwrite(value, 1, strlen(value) + 1, stdout) != strlen(value) + 1)
		exit(1);
}

static char *
get(void)
{
	char *value = NULL;
	size_t size = 0;
	if (getdelim(&value, &size, 0, stdin) < 0) {
		free(value);
		exit(1);
	}
	return value;
}

static void
send_state(void)
{
	for (int i = 0; i < NSTATES; i++)
		put(state[i]);
	fflush(stdout);
}

static void
read_state(void)
{
	for (int i = 0; i < NSTATES; i++) {
		free(state[i]);
		state[i] = get();
	}
	if (chdir(state[CWD]) < 0)
		exit(1);
}

static int dispatch(const char *, int, char **);
static int receive(void);

static int
call(const char *function, int argc, const char **argv)
{
	char count[32];
	snprintf(count, sizeof(count), "%d", argc);
	put("C");
	put(function);
	put(count);
	for (int i = 0; i < argc; i++)
		put(argv[i]);
	send_state();
	for (;;) {
		char *kind = get();
		bool response = strcmp(kind, "R") == 0;
		free(kind);
		if (response) {
			char *status = get();
			int result = atoi(status);
			free(status);
			read_state();
			return result;
		}
		receive();
	}
}

static int
one(const char *function, const char *arg)
{
	const char *args[] = {arg};
	return call(function, 1, args);
}

static int
two(const char *function, const char *a, const char *b)
{
	const char *args[] = {a, b};
	return call(function, 2, args);
}

static void
failure(const char *message)
{
	one("fail", message);
	exit(1);
}

static void
abort_input(void)
{
	restore();
	dprintf(uiout, "\n");
	one("info", "Aborted.");
	exit(1);
}

static int
key(void)
{
	unsigned char byte;
	if (isatty(uiin)) {
		if (tcgetattr(uiin, &saved) < 0)
			failure("cannot read terminal settings");
		struct termios mode = saved;
		mode.c_lflag &= ~ICANON;
		mode.c_cc[VMIN] = 1;
		mode.c_cc[VTIME] = 0;
		terminal = true;
		if (tcsetattr(uiin, TCSANOW, &mode) < 0)
			failure("cannot set terminal mode");
	}
	ssize_t count;
	do {
		count = read(uiin, &byte, 1);
	} while (count == 1 && byte == 0 && !stopped);
	if (stopped) {
		restore();
		exit(1);
	}
	if (count != 1 || byte == 4)
		abort_input();
	restore();
	dprintf(uiout, "\n");
	char value[] = {(char)byte, 0};
	set(CMD, value);
	return 0;
}

static char
choice(const char *prompt)
{
	one("info_n", prompt);
	call("key", 0, NULL);
	return state[CMD][0];
}

static int
permissions_menu(const char *a, const char *b)
{
	for (;;) {
		char *message;
		if (asprintf(&message, "Access permissions %s", a) < 0)
			exit(1);
		one("info", message);
		free(message);
		two("_native_permissions_display", a, b);
		for (;;) {
			switch (choice("[K]eep [U]pgrade [D]iff [S]kip? ")) {
			case 'k':
			case 'K':
				return two("copy_permissions", a, b);
			case 'u':
			case 'U':
				return two("copy_permissions", b, a);
			case 's':
			case 'S':
				return 0;
			case 'd':
			case 'D':
				goto again;
			}
		}
	again:;
	}
}

static int
merge_menu(const char *a, const char *b)
{
	const char *request[] = {"merge", a, b};
	call("request", 3, request);
	for (;;) {
		char *message;
		if (asprintf(&message, "Merged %s", a) < 0)
			exit(1);
		one("info", message);
		free(message);
		call("_native_more", 0, NULL);
		if (*state[MERGE]) {
			one("info", state[MERGE]);
			set(MERGE, "");
		}
		for (;;) {
			switch (choice("[I]nstall [E]dit [V]iew [S]kip? ")) {
			case 'i':
			case 'I':
				two("_native_install_merge", a, b);
				return call("_native_clear_temp", 0, NULL);
			case 'e':
			case 'E': {
				const char *edit[] = {"edit", a, b};
				call("request", 3, edit);
				goto again;
			}
			case 'v':
			case 'V':
				goto again;
			case 's':
			case 'S':
				return call("_native_clear_temp", 0, NULL);
			}
		}
	again:;
	}
}

static int
file_menu(const char *a, const char *b, const char *type)
{
	bool regular = strcmp(type, "regular") == 0;
	for (;;) {
		one("info", a);
		if (regular)
			call("_native_more", 0, NULL);
		else
			two("_native_types", a, b);
		for (;;) {
			char selected = choice(
			    regular
			        ? "[K]eep [U]pgrade [M]erge [D]iff [S]kip? "
			        : "[K]eep [U]pgrade [D]iff [S]kip? ");
			switch (selected) {
			case 'k':
			case 'K':
				return one("_native_remove", b);
			case 'u':
			case 'U':
				return two("_native_upgrade", a, b);
			case 'm':
			case 'M':
				if (regular)
					return two("merge_menu", a, b);
				break;
			case 'd':
			case 'D':
				goto again;
			case 's':
			case 'S':
				return 0;
			}
		}
	again:;
	}
}

static int
process_file(const char *path)
{
	struct stat st;
	char *installed;
	size_t prefix = strlen(state[REJECTED]);
	const char *suffix =
	    strncmp(path, state[REJECTED], prefix) == 0 ? path + prefix : path;
	if (asprintf(&installed, "%s%s", state[ROOT], suffix) < 0)
		exit(1);
	set(INSTALLED, installed);
	if (stat(installed, &st) < 0) {
		free(installed);
		return one("_native_remove", path);
	}
	two("_native_compare_permissions", installed, path);
	if (strcmp(state[VALUE], "different") == 0) {
		set(FOUND, "yes");
		two("permissions_menu", installed, path);
	}
	if (two("files_regular", installed, path) == 0) {
		two("_native_compare", installed, path);
		if (strcmp(state[VALUE], "0") == 0)
			one("_native_remove", path);
		else {
			set(FOUND, "yes");
			two("diff_menu", installed, path);
		}
	} else {
		set(FOUND, "yes");
		two("file_menu", installed, path);
	}
	free(installed);
	return 0;
}

static int
walk(const char *directory)
{
	one("_native_expand", directory);
	size_t count = strtoull(state[VALUE], NULL, 10);
	char **entries = calloc(count ? count : 1, sizeof(*entries));
	if (!entries)
		exit(1);
	for (size_t i = 0; i < count; i++) {
		char index[32];
		snprintf(index, sizeof(index), "%zu", i);
		one("_native_expanded", index);
		entries[i] = strdup(state[VALUE]);
		if (!entries[i])
			exit(1);
	}
	for (size_t i = 0; i < count; i++) {
		struct stat st;
		set(ENTRY, entries[i]);
		if (lstat(entries[i], &st) == 0)
			one(S_ISDIR(st.st_mode) ? "walk" : "process_file",
			    entries[i]);
		free(entries[i]);
	}
	free(entries);
	if (strcmp(directory, state[REJECTED]) != 0)
		one("_native_rmdir", directory);
	return 0;
}

static int
dispatch(const char *operation, int argc, char **argv)
{
	if (strcmp(operation, "main") == 0) {
		set(FOUND, "no");
		one("walk", state[REJECTED]);
		if (strcmp(state[FOUND], "no") == 0)
			call("_native_nothing", 0, NULL);
		return 0;
	}
	if (strcmp(operation, "key") == 0 && argc == 0)
		return key();
	if (strcmp(operation, "walk") == 0 && argc == 1)
		return walk(argv[0]);
	if (strcmp(operation, "process_file") == 0 && argc == 1)
		return process_file(argv[0]);
	if (strcmp(operation, "permissions_menu") == 0 && argc == 2)
		return permissions_menu(argv[0], argv[1]);
	if (strcmp(operation, "merge_menu") == 0 && argc == 2)
		return merge_menu(argv[0], argv[1]);
	if (strcmp(operation, "file_menu") == 0 && argc == 2)
		return file_menu(argv[0], argv[1], "special");
	if (strcmp(operation, "diff_menu") == 0 && argc == 2) {
		const char *request[] = {"diff", argv[0], argv[1]};
		call("request", 3, request);
		file_menu(argv[0], argv[1], "regular");
		return call("_native_clear_temp", 0, NULL);
	}
	failure("invalid native workflow operation");
	return 1;
}

static int
receive(void)
{
	char *operation = get(), *count = get();
	int argc = atoi(count);
	free(count);
	if (argc < 0 || argc > 16)
		exit(1);
	char *argv[16];
	for (int i = 0; i < argc; i++)
		argv[i] = get();
	read_state();
	int result = dispatch(operation, argc, argv);
	for (int i = 0; i < argc; i++)
		free(argv[i]);
	free(operation);
	char status[32];
	snprintf(status, sizeof(status), "%d", result);
	put("D");
	put(status);
	send_state();
	return result;
}

int
rejmerge_workflow(int input_fd, int output_fd)
{
	uiin = input_fd;
	uiout = output_fd;
	atexit(restore);
	struct sigaction action = {.sa_handler = signal_request};
	sigemptyset(&action.sa_mask);
	int signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM};
	for (size_t i = 0; i < sizeof(signals) / sizeof(*signals); i++)
		sigaction(signals[i], &action, NULL);
	for (;;) {
		char *kind = get();
		bool request = strcmp(kind, "N") == 0;
		free(kind);
		if (!request)
			return 1;
		receive();
	}
}
