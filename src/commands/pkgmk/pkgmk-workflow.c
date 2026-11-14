/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include "pkgmk-workflow.h"

static FILE *control;
static int channel;
static pid_t controller;
static bool finished;
static int child_status;

static int run(const char *mode, int argc, char **argv);

static void
termination(int signal)
{
	int saved = errno;
	if (controller > 0)
		kill(controller, signal);
	errno = saved;
}

static int
field(const char *text)
{
	return fwrite(text, 1, strlen(text) + 1, control) == strlen(text) + 1
	           ? 0
		   : -1;
}

static char *
read_field(void)
{
	char *text = NULL;
	size_t used = 0, capacity = 0;
	for (;;) {
		struct pollfd ready = {.fd = channel, .events = POLLIN};
		int available = poll(&ready, 1, 50);
		if (available < 0 && errno == EINTR)
			continue;
		if (waitpid(controller, &child_status, WNOHANG) ==
		    controller) {
			finished = true;
			free(text);
			return NULL;
		}
		if (available < 0) {
			free(text);
			return NULL;
		}
		if (available == 0)
			continue;
		char byte;
		ssize_t count = read(channel, &byte, 1);
		if (count < 0 && errno == EINTR)
			continue;
		if (count != 1) {
			free(text);
			return NULL;
		}
		if (used == capacity) {
			size_t next = capacity ? capacity * 2 : 128;
			if (next < capacity) {
				free(text);
				return NULL;
			}
			char *grown = realloc(text, next);
			if (!grown) {
				free(text);
				return NULL;
			}
			text = grown;
			capacity = next;
		}
		text[used++] = byte;
		if (!byte)
			return text;
	}
}

static int
reply(int status, const char *value)
{
	char number[32];
	snprintf(number, sizeof(number), "%d", status);
	return field("R") || field(number) || field(value) || fflush(control)
	           ? -1
		   : 0;
}

/* Nested RUN requests are serviced while a callback waits for its reply. */
static int
receive(char **value)
{
	for (;;) {
		char *kind = read_field();
		if (!kind)
			return -1;
		if (strcmp(kind, "R") == 0) {
			char *number = read_field();
			*value = read_field();
			int status = number ? atoi(number) : -1;
			free(number);
			free(kind);
			return *value ? status : -1;
		}
		if (strcmp(kind, "RUN") != 0) {
			free(kind);
			return -1;
		}
		free(kind);
		char *mode = read_field();
		char *number = read_field();
		if (!mode || !number) {
			free(mode);
			free(number);
			return -1;
		}
		int count = atoi(number);
		free(number);
		if (count < 0 ||
		    (size_t)count > (size_t)-1 / sizeof(char *) - 1) {
			free(mode);
			return -1;
		}
		char **args = calloc((size_t)count + 1, sizeof(*args));
		if (!args) {
			free(mode);
			return -1;
		}
		int actual = 0;
		for (; actual < count; actual++) {
			args[actual] = read_field();
			if (!args[actual])
				break;
		}
		int status = actual == count ? run(mode, count, args) : -1;
		for (int i = 0; i < actual; i++)
			free(args[i]);
		free(args);
		free(mode);
		if (status < 0 || reply(status, "") < 0)
			return -1;
	}
}

static int
request(const char *operation, int argc, const char **argv, char **value)
{
	char number[32];
	snprintf(number, sizeof(number), "%d", argc);
	if (field(operation) < 0 || field(number) < 0)
		return -1;
	for (int i = 0; i < argc; i++) {
		if (field(argv[i]) < 0)
			return -1;
	}
	if (fflush(control) != 0)
		return -1;
	return receive(value);
}

static char *
get(const char *name)
{
	char *value = NULL;
	const char *args[] = {name};
	if (request("GET", 1, args, &value) < 0) {
		free(value);
		return NULL;
	}
	return value;
}

static int
set(const char *name, const char *value)
{
	char *answer = NULL;
	const char *args[] = {name, value};
	int status = request("SET", 2, args, &answer);
	free(answer);
	return status;
}

static int
call(const char *name, const char *arg)
{
	char *value = NULL;
	const char *args[] = {name, arg};
	int status = request("CALL", arg ? 2 : 1, args, &value);
	free(value);
	return status;
}

static int
test(const char *name, const char *arg)
{
	char *value = NULL;
	const char *args[] = {name, arg};
	int status = request("TEST", arg ? 2 : 1, args, &value);
	free(value);
	return status;
}

static int
capture(const char *name, char **value)
{
	const char *args[] = {name};
	return request("CAPTURE", 1, args, value);
}

static bool
equals(const char *name, const char *expected)
{
	char *value = get(name);
	bool result = value && strcmp(value, expected) == 0;
	free(value);
	return result;
}

static bool
yes(const char *name)
{
	return equals(name, "yes");
}

static int
message(const char *function, const char *format, const char *value)
{
	char *text;
	if (asprintf(&text, format, value) < 0)
		return -1;
	int status = call(function, text);
	free(text);
	return status;
}

static int
target_message(const char *function, const char *format)
{
	char *target = get("TARGET");
	if (!target)
		return -1;
	int status = message(function, format, target);
	free(target);
	return status;
}

static int
parse(int argc, char **argv)
{
	static const struct {
		const char *short_name, *long_name, *variable, *value;
	} options[] = {{"-i", "--install", "PKGMK_INSTALL", "install"},
	    {"-u", "--upgrade", "PKGMK_INSTALL", "upgrade"},
	    {"-r", "--recursive", "PKGMK_RECURSIVE", "yes"},
	    {"-d", "--download", "PKGMK_DOWNLOAD", "yes"},
	    {"-do", "--download-only", "PKGMK_DOWNLOAD_ONLY", "yes"},
	    {"-eo", "--extract-only", "PKGMK_EXTRACT_ONLY", "yes"},
	    {"-utd", "--up-to-date", "PKGMK_UP_TO_DATE", "yes"},
	    {"-uf", "--update-footprint", "PKGMK_UPDATE_FOOTPRINT", "yes"},
	    {"-if", "--ignore-footprint", "PKGMK_IGNORE_FOOTPRINT", "yes"},
	    {"-in", "--ignore-new", "PKGMK_IGNORE_NEW", "yes"},
	    {"-um", "--update-md5sum", "PKGMK_UPDATE_MD5SUM", "yes"},
	    {"-im", "--ignore-md5sum", "PKGMK_IGNORE_MD5SUM", "yes"},
	    {"-cm", "--check-md5sum", "PKGMK_CHECK_MD5SUM", "yes"},
	    {"-us", "--update-signature", "PKGMK_UPDATE_SIGNATURE", "yes"},
	    {"-cs", "--check-signature", "PKGMK_CHECK_SIGNATURE", "yes"},
	    {"-is", "--ignore-signature", "PKGMK_IGNORE_SIGNATURE", "yes"},
	    {"-rs", "--refresh-signature", "PKGMK_REFRESH_SIGNATURE", "yes"},
	    {"-ns", "--no-strip", "PKGMK_NO_STRIP", "yes"},
	    {"-f", "--force", "PKGMK_FORCE", "yes"},
	    {"-c", "--clean", "PKGMK_CLEAN", "yes"},
	    {"-kw", "--keep-work", "PKGMK_KEEP_WORK", "yes"},
	    {"-pk", "--public-key", "PKGMK_PUBLICKEY", NULL},
	    {"-sk", "--secret-key", "PKGMK_PRIVATEKEY", NULL},
	    {"-cf", "--config-file", "PKGMK_CONFFILE", NULL}};
	for (int i = 0; i < argc && argv[i][0]; i++) {
		const char *option = argv[i];
		if (strcmp(option, "--referesh-signature") == 0)
			option = "--refresh-signature";
		if (strcmp(option, "-h") == 0 || strcmp(option, "--help") == 0)
			return call("print_help", NULL) < 0
			           ? -1
				   : call("native_exit", "0");
		if (strcmp(option, "-v") == 0 ||
		    strcmp(option, "--version") == 0)
			return call("native_version", NULL) < 0
			           ? -1
				   : call("native_exit", "0");
		size_t n;
		for (n = 0; n < sizeof(options) / sizeof(options[0]); n++) {
			if (strcmp(option, options[n].short_name) == 0 ||
			    strcmp(option, options[n].long_name) == 0)
				break;
		}
		if (n == sizeof(options) / sizeof(options[0])) {
			call("native_invalid_option", argv[i]);
			return call("native_exit", "1");
		}
		const char *value = options[n].value;
		if (!value) {
			if (++i >= argc || !argv[i][0]) {
				call("native_missing_argument", option);
				return call("native_exit", "1");
			}
			value = argv[i];
		}
		if (set(options[n].variable, value) < 0)
			return -1;
		if (strcmp(option, "-do") == 0 ||
		    strcmp(option, "--download-only") == 0) {
			if (set("PKGMK_DOWNLOAD", "yes") < 0)
				return -1;
		}
	}
	return 0;
}

static int
lifecycle(void)
{
	char *pkgfile = get("PKGMK_PKGFILE"), *config = get("PKGMK_CONFFILE");
	char *target = NULL, *root = NULL, *compression = NULL;
	int status = -1;
	if (!pkgfile || !config)
		goto out;
	const char *sources[] = {pkgfile, config};
	for (size_t i = 0; i < 2; i++) {
		char *answer = NULL;
		if (set("FILE", sources[i]) < 0 ||
		    request("SOURCE", 1, &sources[i], &answer) < 0) {
			free(answer);
			goto out;
		}
		free(answer);
	}
	const char *directories[] = {"PKGMK_SOURCE_DIR", "PKGMK_PACKAGE_DIR"};
	for (size_t i = 0; i < 2; i++) {
		char *directory = get(directories[i]);
		if (!directory)
			goto out;
		status = call("check_directory", directory);
		free(directory);
		if (status < 0)
			goto out;
	}
	if (call("native_check_work_parent", NULL) < 0 ||
	    call("check_pkgfile", NULL) < 0)
		goto out;
	compression = get("PKGMK_COMPRESSION_MODE");
	if (!compression)
		goto out;
	if (strcmp(compression, "gz") && strcmp(compression, "bz2") &&
	    strcmp(compression, "xz") && strcmp(compression, "lz") &&
	    strcmp(compression, "zst")) {
		message("error", "Compression mode '%s' not supported",
		    compression);
		status = call("native_exit", "1");
		goto out;
	}
	root = get("PKGMK_PACKAGE_DIR");
	char *name = get("name"), *version = get("version"),
	     *release = get("release");
	if (!root || !name || !version || !release) {
		free(name);
		free(version);
		free(release);
		goto out;
	}
	status = asprintf(&target, "%s/%s#%s-%s.pkg.tar.%s", root, name,
	    version, release, compression);
	free(name);
	free(version);
	free(release);
	if (status < 0 || set("TARGET", target) < 0)
		goto out;
	status = 0;
	if (yes("PKGMK_CLEAN")) {
		call("clean", NULL);
		goto done;
	}
	if (yes("PKGMK_UPDATE_FOOTPRINT")) {
		call("update_footprint", NULL);
		goto done;
	}
	if (yes("PKGMK_UPDATE_MD5SUM") || yes("PKGMK_UPDATE_SIGNATURE")) {
		bool signature = !yes("PKGMK_UPDATE_MD5SUM");
		call("download_source", NULL);
		char *file =
		    get(signature ? "PKGMK_SIGNATURE" : "PKGMK_MD5SUM");
		if (!file)
			goto out;
		call("check_file", file);
		free(file);
		call(signature ? "make_signature" : "native_write_md5sum",
		    NULL);
		call("info",
		    signature ? "Signature updated." : "Md5sum updated.");
		goto done;
	}
	if (yes("PKGMK_REFRESH_SIGNATURE")) {
		char *file = get("PKGMK_SIGNATURE");
		if (!file)
			goto out;
		call("check_file", file);
		free(file);
		call("refresh_signature", NULL);
		call("info", "Signature refreshed.");
		goto done;
	}
	if (yes("PKGMK_DOWNLOAD_ONLY")) {
		call("download_source", NULL);
		goto done;
	}
	if (yes("PKGMK_EXTRACT_ONLY")) {
		call("download_source", NULL);
		call("make_work_dir", NULL);
		call("native_extract_message", NULL);
		call("unpack_source", NULL);
		goto done;
	}
	char *needed = NULL;
	if (capture("build_needed", &needed) < 0)
		goto out;
	bool build = strcmp(needed, "yes") == 0;
	bool skip = strcmp(needed, "no") == 0;
	free(needed);
	if (yes("PKGMK_UP_TO_DATE")) {
		target_message("info", build
		                           ? "Package '%s' is not up to date."
					   : "Package '%s' is up to date.");
		goto done;
	}
	if (skip && equals("PKGMK_FORCE", "no") &&
	    equals("PKGMK_CHECK_MD5SUM", "no") &&
	    equals("PKGMK_CHECK_SIGNATURE", "no")) {
		target_message("info", "Package '%s' is up to date.");
	} else {
		call("download_source", NULL);
		call("build_package", NULL);
	}
	char *install = get("PKGMK_INSTALL");
	if (!install)
		goto out;
	if (strcmp(install, "no") != 0)
		call("install_package", NULL);
	free(install);
done:
	status = call("native_exit", "0");
out:
	free(pkgfile);
	free(config);
	free(target);
	free(root);
	free(compression);
	return status;
}

static int
work_directory(void)
{
	char *work = get("PKGMK_WORK_DIR");
	char *pkg = NULL, *src = NULL;
	if (!work || asprintf(&pkg, "%s/pkg", work) < 0 ||
	    asprintf(&src, "%s/src", work) < 0) {
		free(work);
		free(pkg);
		free(src);
		return -1;
	}
	int status = set("PKG", pkg) < 0 || set("SRC", src) < 0 ? -1 : 0;
	free(work);
	free(pkg);
	free(src);
	if (status < 0)
		return -1;
	call("native_work_prepare", NULL);
	call("remove_work_dir", NULL);
	call("native_work_mkdir", NULL);
	if (equals("PKGMK_IGNORE_SIGNATURE", "no") ||
	    yes("PKGMK_CHECK_SIGNATURE")) {
		test("native_copy_signature", NULL);
		if (test("check_signature", NULL) == 0 &&
		    test("native_md5_absent", NULL) == 0)
			return 0;
	}
	if (equals("PKGMK_IGNORE_MD5SUM", "no"))
		return call("check_md5sum", NULL);
	return 0;
}

static int
build_package(void)
{
	char *target = get("TARGET");
	if (!target)
		return -1;
	call("check_file", target);
	free(target);
	call("make_work_dir", NULL);
	char *uid = get("UID");
	if (!uid)
		return -1;
	if (strcmp(uid, "0"))
		call("warning", "Packages should be built as root.");
	free(uid);
	target_message("info", "Building '%s'.");
	call("unpack_source", NULL);
	int result = call("native_recipe_build", NULL);
	char number[32];
	snprintf(number, sizeof(number), "%d", result);
	set("build_status", number);
	if (result == 0) {
		if (equals("PKGMK_NO_STRIP", "no"))
			call("strip_files", NULL);
		call("compress_manpages", NULL);
		call("native_build_result", NULL);
		char *mode = get("PKGMK_COMPRESSION_MODE");
		if (!mode)
			return -1;
		const char *flag = NULL;
		if (!strcmp(mode, "gz"))
			flag = "-z";
		else if (!strcmp(mode, "bz2"))
			flag = "-j";
		else if (!strcmp(mode, "xz"))
			flag = "-J";
		else if (!strcmp(mode, "lz"))
			flag = "--lzip";
		else if (!strcmp(mode, "zst"))
			flag = "--zstd";
		free(mode);
		if (flag)
			set("COMPRESSION", flag);
		if (test("native_archive_package", NULL) == 0) {
			set("BUILD_SUCCESSFUL", "yes");
			if (yes("PKGMK_IGNORE_FOOTPRINT"))
				call("warning", "Footprint ignored.");
			else
				call("check_footprint", NULL);
		}
	}
	if (equals("PKGMK_KEEP_WORK", "no"))
		call("remove_work_dir", NULL);
	if (yes("BUILD_SUCCESSFUL")) {
		target_message("info", "Building '%s' succeeded.");
		return 0;
	}
	call("native_failed_touch", NULL);
	target_message("error", "Building '%s' failed.");
	return call("native_exit", "1");
}

static int
install_package(void)
{
	char *target = get("TARGET"), *install = get("PKGMK_INSTALL");
	if (!target || !install) {
		free(target);
		free(install);
		return -1;
	}
	message("info", "Installing '%s'.", target);
	int result = call("native_install_command",
	    !strcmp(install, "install") ? "install" : "upgrade");
	target_message(result == 0 ? "info" : "error",
	    result == 0 ? "Installing '%s' succeeded."
	                : "Installing '%s' failed.");
	free(target);
	free(install);
	return result == 0 ? 0 : call("native_exit", "1");
}

static int
recursive(int argc, char **argv)
{
	char *root = get("PWD"), *command = get("PKGMK_COMMAND");
	char **args = calloc((size_t)argc + 2, sizeof(*args));
	FILE *list = tmpfile(), *sorted = tmpfile();
	int status = -1;
	if (!root || !command || !args || !list || !sorted)
		goto out;
	args[0] = command;
	int count = 1;
	for (int i = 0; i < argc && argv[i][0]; i++) {
		if (!strcmp(argv[i], "-r") || !strcmp(argv[i], "--recursive"))
			continue;
		args[count++] = argv[i];
		if ((!strcmp(argv[i], "-cf") ||
		        !strcmp(argv[i], "--config-file") ||
		        !strcmp(argv[i], "-sk") ||
		        !strcmp(argv[i], "--secret-key") ||
		        !strcmp(argv[i], "-pk") ||
		        !strcmp(argv[i], "--public-key")) &&
		    i + 1 < argc)
			args[count++] = argv[++i];
	}
	pid_t child = fork();
	if (child == 0) {
		if (dup2(fileno(list), STDOUT_FILENO) < 0)
			_exit(1);
		execlp("find", "find", root, "-name", "Pkgfile", "-print",
		    (char *)NULL);
		_exit(1);
	}
	if (child < 0)
		goto out;
	while (waitpid(child, &status, 0) < 0)
		if (errno != EINTR)
			goto out;
	if (fseek(list, 0, SEEK_SET) < 0)
		goto out;
	child = fork();
	if (child == 0) {
		if (dup2(fileno(list), STDIN_FILENO) < 0 ||
		    dup2(fileno(sorted), STDOUT_FILENO) < 0)
			_exit(1);
		if (setenv("LC_ALL", "C", 1) < 0)
			_exit(1);
		execlp("sort", "sort", (char *)NULL);
		_exit(1);
	}
	if (child < 0)
		goto out;
	while (waitpid(child, &status, 0) < 0)
		if (errno != EINTR)
			goto out;
	if (fseek(sorted, 0, SEEK_SET) < 0)
		goto out;
	char *line = NULL;
	size_t size = 0;
	while (getline(&line, &size, sorted) >= 0) {
		char *end = strrchr(line, '\n');
		if (end)
			*end = '\0';
		end = strrchr(line, '/');
		if (end)
			end[1] = '\0';
		printf("=======> Entering directory '%s'.\n", line);
		fflush(stdout);
		child = fork();
		if (child == 0) {
			if (chdir(line) < 0)
				_exit(1);
			execv(command, args);
			_exit(1);
		}
		if (child > 0)
			while (waitpid(child, &status, 0) < 0)
				if (errno != EINTR)
					break;
		printf("=======> Leaving directory '%s'.\n", line);
		fflush(stdout);
	}
	free(line);
	status = call("native_exit", "0");
out:
	if (list)
		fclose(list);
	if (sorted)
		fclose(sorted);
	free(args);
	free(root);
	free(command);
	return status;
}

static int
run(const char *mode, int argc, char **argv)
{
	if (strcmp(mode, "parse") == 0)
		return parse(argc, argv);
	if (strcmp(mode, "main") == 0)
		return lifecycle();
	if (strcmp(mode, "recursive") == 0)
		return recursive(argc, argv);
	if (strcmp(mode, "work-directory") == 0)
		return work_directory();
	if (strcmp(mode, "build-package") == 0)
		return build_package();
	if (strcmp(mode, "install-package") == 0)
		return install_package();
	return -1;
}

int
pkgmk_workflow_launch(char **args)
{
	int sockets[2];
	if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) < 0) {
		perror("pkgmk: socketpair");
		return 1;
	}
	pid_t child = fork();
	if (child < 0) {
		perror("pkgmk: fork");
		close(sockets[0]);
		close(sockets[1]);
		return 1;
	}
	if (child == 0) {
		close(sockets[0]);
		if (sockets[1] != 63 && dup2(sockets[1], 63) < 0)
			_exit(1);
		if (sockets[1] != 63)
			close(sockets[1]);
		if (fcntl(63, F_SETFD, 0) < 0)
			_exit(1);
		execv("/bin/bash", args);
		perror("pkgmk: /bin/bash");
		_exit(1);
	}
	controller = child;
	struct sigaction broken = {.sa_handler = SIG_IGN};
	sigemptyset(&broken.sa_mask);
	sigaction(SIGPIPE, &broken, NULL);
	close(sockets[1]);
	channel = sockets[0];
	control = fdopen(sockets[0], "w");
	if (!control) {
		kill(child, SIGTERM);
		close(sockets[0]);
		waitpid(child, NULL, 0);
		return 1;
	}
	setvbuf(control, NULL, _IONBF, 0);
	const int signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM};
	for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
		struct sigaction previous,
		    action = {.sa_handler = termination};
		sigemptyset(&action.sa_mask);
		if (sigaction(signals[i], NULL, &previous) == 0 &&
		    previous.sa_handler != SIG_IGN)
			sigaction(signals[i], &action, NULL);
	}
	int status;
	for (;;) {
		if (finished) {
			status = child_status;
			break;
		}
		pid_t done = waitpid(child, &status, WNOHANG);
		if (done == child)
			break;
		if (done < 0 && errno != EINTR) {
			status = 1 << 8;
			break;
		}
		struct pollfd ready = {.fd = sockets[0], .events = POLLIN};
		int available = poll(&ready, 1, 50);
		if (available < 0 && errno == EINTR)
			continue;
		if (available > 0 && (ready.revents & POLLIN)) {
			char *unused = NULL;
			receive(&unused);
			free(unused);
		}
	}
	fclose(control);
	return WIFEXITED(status) ? WEXITSTATUS(status)
	                         : 128 + WTERMSIG(status);
}
