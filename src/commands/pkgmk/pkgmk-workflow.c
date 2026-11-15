/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/vfs.h>
#include <linux/magic.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <sys/wait.h>
#include <unistd.h>

#include "pkgmk-workflow.h"

static FILE *control;
static int channel;
static pid_t controller;
static bool finished;
static int child_status;
static int output[2] = {-1, -1};
static int log_sink = -1;
static bool capture_used;
static int work_base = -1;
static int work_lock = -1;
struct work_record {
	unsigned long long magic, mount, device, inode, namespace;
	unsigned long long unique_mount, retained;
	char boot[36];
};

/* Linux 6.8 UAPI; older kernels leave this bit absent in stx_mask. */
#ifndef STATX_MNT_ID_UNIQUE
#define STATX_MNT_ID_UNIQUE 0x00004000U
#endif

static int
work_record_context(struct work_record *record)
{
	struct stat st;
	if (stat("/proc/self/ns/mnt", &st) < 0)
		return -1;
	record->namespace = st.st_ino;
	int fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ssize_t size = read(fd, record->boot, sizeof(record->boot));
	close(fd);
	if (size != sizeof(record->boot)) {
		errno = EIO;
		return -1;
	}
	return 0;
}
static char *managed_name;
static struct stat reservation;
static unsigned long long managed_mount;
static bool discard_checked_work;
static volatile sig_atomic_t termination_requested;
static volatile sig_atomic_t downloader_runner;

static int work_release(void);

static void
work_mark_retained(void)
{
	struct work_record record;
	if (pread(work_lock, &record, sizeof(record), 0) != sizeof(record))
		return;
	/* Only a reaped, normally exited controller permits later recovery. */
	record.retained = 1;
	if (pwrite(work_lock, &record, sizeof(record), 0) != sizeof(record) ||
	    fsync(work_lock) < 0)
		perror("pkgmk: cannot record retained work");
}

static void
work_retained(void)
{
	if (managed_name && discard_checked_work && !termination_requested &&
	    work_release() < 0)
		perror("pkgmk: cannot release managed work directory");
	if (managed_name)
		fprintf(stderr,
		    "pkgmk: Retained work directory '/var/tmp/pkgmk/%s'.\n",
		    managed_name);
}

static int
work_identity(const char *path, unsigned long long *identity)
{
	struct statx st;
	if (statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, STATX_MNT_ID, &st) < 0)
		return -1;
	if (!(st.stx_mask & STATX_MNT_ID)) {
		errno = ENOTSUP;
		return -1;
	}
	*identity = st.stx_mnt_id;
	return 0;
}

static int
work_acquire(const char *name, bool force)
{
	struct stat st;
	char path[NAME_MAX + 64];
	if (managed_name) {
		errno = EBUSY;
		return -1;
	}
	if (!name[0] || !strcmp(name, ".") || !strcmp(name, "..") ||
	    strchr(name, '/')) {
		errno = EINVAL;
		return -1;
	}
	int var =
	    open("/var", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (var < 0)
		return -1;
	if (fstat(var, &st) < 0 || st.st_uid != 0 || (st.st_mode & 0022)) {
		close(var);
		errno = EPERM;
		return -1;
	}
	int parent = openat(
	    var, "tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	close(var);
	if (parent < 0)
		return -1;
	if (fstat(parent, &st) < 0 || st.st_uid != 0 ||
	    ((st.st_mode & 0022) && !(st.st_mode & S_ISVTX))) {
		close(parent);
		errno = EPERM;
		return -1;
	}
	if (mkdirat(parent, "pkgmk", 0700) < 0 && errno != EEXIST) {
		close(parent);
		return -1;
	}
	work_base = openat(
	    parent, "pkgmk", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	close(parent);
	if (work_base < 0)
		return -1;
	if (fstat(work_base, &st) < 0 || st.st_uid != 0 ||
	    (st.st_mode & 07777) != 0700) {
		errno = EPERM;
		return -1;
	}
	if (!strcmp(name, ".state")) {
		errno = EINVAL;
		return -1;
	}
	if (mkdirat(work_base, ".state", 0700) < 0 && errno != EEXIST)
		return -1;
	int state = openat(work_base, ".state",
	    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (state < 0)
		return -1;
	if (fstat(state, &st) < 0 || st.st_uid != 0 ||
	    (st.st_mode & 07777) != 0700) {
		close(state);
		errno = EPERM;
		return -1;
	}
	work_lock = openat(state, name,
	    O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
	close(state);
	if (work_lock < 0)
		return -1;
	if (fstat(work_lock, &st) < 0 || !S_ISREG(st.st_mode) ||
	    st.st_uid != 0 || st.st_nlink != 1 ||
	    (st.st_mode & 07777) != 0600) {
		errno = EPERM;
		return -1;
	}
	if (flock(work_lock, LOCK_EX | LOCK_NB) < 0)
		return -1;
	struct work_record context = {0}, recorded;
	if (work_record_context(&context) < 0)
		return -1;
	if (snprintf(path, sizeof(path), "/proc/self/fd/%d/%s", work_base,
	        name) >= (int)sizeof(path)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	char *copy = strdup(name);
	if (!copy)
		return -1;
	if (mkdirat(work_base, name, 0700) < 0) {
		if (errno != EEXIST || !force) {
			free(copy);
			return -1;
		}
		unsigned long long identity;
		struct statx base_mount, unique;
		struct statfs fs;
		if (pread(work_lock, &recorded, sizeof(recorded), 0) !=
		        sizeof(recorded) ||
		    st.st_size != sizeof(recorded) ||
		    recorded.magic != 0x696d6169776f726bULL ||
		    !recorded.retained || !recorded.unique_mount ||
		    statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW,
		        STATX_MNT_ID_UNIQUE, &unique) < 0 ||
		    !(unique.stx_mask & STATX_MNT_ID_UNIQUE) ||
		    unique.stx_mnt_id != recorded.unique_mount ||
		    recorded.namespace != context.namespace ||
		    memcmp(
		        recorded.boot, context.boot, sizeof(context.boot)) ||
		    fstatat(work_base, name, &st, AT_SYMLINK_NOFOLLOW) < 0 ||
		    !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
		    (st.st_mode & 07777) != 0700 || statfs(path, &fs) < 0 ||
		    fs.f_type != TMPFS_MAGIC ||
		    work_identity(path, &identity) < 0 ||
		    identity != recorded.mount ||
		    statx(work_base, "", AT_EMPTY_PATH, STATX_MNT_ID,
		        &base_mount) < 0 ||
		    !(base_mount.stx_mask & STATX_MNT_ID) ||
		    identity == base_mount.stx_mnt_id) {
			fprintf(stderr, "pkgmk: Unknown managed work; manual "
			                "recovery required.\n");
			free(copy);
			errno = ESTALE;
			return -1;
		}
		if (umount2(path, 0) < 0) {
			free(copy);
			return -1;
		}
		if (fstatat(work_base, name, &st, AT_SYMLINK_NOFOLLOW) < 0 ||
		    st.st_dev != recorded.device ||
		    st.st_ino != recorded.inode ||
		    unlinkat(work_base, name, AT_REMOVEDIR) < 0 ||
		    mkdirat(work_base, name, 0700) < 0) {
			free(copy);
			errno = ESTALE;
			return -1;
		}
	}
	managed_name = copy;
	if (fstatat(work_base, name, &reservation, AT_SYMLINK_NOFOLLOW) < 0)
		return -1;
	if (snprintf(path, sizeof(path), "/proc/self/fd/%d/%s", work_base,
	        name) >= (int)sizeof(path)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	if (mount("tmpfs", path, "tmpfs", 0, "mode=0700") < 0) {
		int saved = errno;
		if (unlinkat(work_base, managed_name, AT_REMOVEDIR) == 0) {
			free(managed_name);
			managed_name = NULL;
		}
		errno = saved;
		return -1;
	}
	if (work_identity(path, &managed_mount) < 0)
		return -1;
	struct statx unique;
	if (statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, STATX_MNT_ID_UNIQUE,
	        &unique) == 0 &&
	    (unique.stx_mask & STATX_MNT_ID_UNIQUE))
		context.unique_mount = unique.stx_mnt_id;
	context.magic = 0x696d6169776f726bULL;
	context.mount = managed_mount;
	context.device = reservation.st_dev;
	context.inode = reservation.st_ino;
	if (ftruncate(work_lock, 0) < 0 ||
	    pwrite(work_lock, &context, sizeof(context), 0) !=
	        sizeof(context) ||
	    fsync(work_lock) < 0)
		return -1;
	return 0;
}

static int
work_release(void)
{
	char *path = NULL;
	unsigned long long identity;
	struct stat st;
	if (asprintf(&path, "/proc/self/fd/%d/%s", work_base, managed_name) <
	    0)
		return -1;
	int result = -1;
	if (work_identity(path, &identity) < 0 || identity != managed_mount) {
		errno = ESTALE;
		goto out;
	}
	if (umount2(path, 0) < 0)
		goto out;
	if (fstatat(work_base, managed_name, &st, AT_SYMLINK_NOFOLLOW) < 0 ||
	    st.st_dev != reservation.st_dev ||
	    st.st_ino != reservation.st_ino) {
		errno = ESTALE;
		goto out;
	}
	if (unlinkat(work_base, managed_name, AT_REMOVEDIR) < 0)
		goto out;
	free(managed_name);
	managed_name = NULL;
	if (ftruncate(work_lock, 0) < 0 || fsync(work_lock) < 0)
		goto out;
	close(work_lock);
	work_lock = -1;
	close(work_base);
	work_base = -1;
	result = 0;
out:
	free(path);
	return result;
}

static void
observation_warning(void)
{
	fprintf(stderr, "pkgmk: warning: recipe logging unavailable: %s\n",
	    strerror(errno));
}

static int
write_bytes(int fd, const char *bytes, size_t size)
{
	while (size) {
		ssize_t n = write(fd, bytes, size);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		bytes += n;
		size -= (size_t)n;
	}
	return 0;
}

/* One bounded batch per stream also services writers after capture ends. */
static void
relay(void)
{
	for (int i = 0; i < 2; i++) {
		char bytes[8192];
		ssize_t n = read(output[i], bytes, sizeof(bytes));
		if (n <= 0)
			continue;
		if (write_bytes(i + 1, bytes, (size_t)n) < 0) {
			fprintf(stderr,
			    "pkgmk: warning: recipe live output failed: %s\n",
			    strerror(errno));
			close(output[i]);
			output[i] = -1;
		}
		if (log_sink >= 0 &&
		    write_bytes(log_sink, bytes, (size_t)n) < 0) {
			observation_warning();
			close(log_sink);
			log_sink = -1;
		}
	}
}

static int
poll_channel(void)
{
	struct pollfd ready[3] = {{.fd = channel, .events = POLLIN},
	    {.fd = output[0], .events = POLLIN},
	    {.fd = output[1], .events = POLLIN}};
	int status = poll(ready, 3, 50);
	if (status >= 0)
		relay();
	return status < 0 ? -1 : !!ready[0].revents;
}

static int run(const char *mode, int argc, char **argv);

static void
termination(int signal)
{
	int saved = errno;
	termination_requested = signal;
	if (downloader_runner > 1)
		kill(downloader_runner, signal);
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
		int available = poll_channel();
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
	if (yes("PKGMK_TMPFS")) {
		char *selected = get("PKGMK_WORK_DIR"),
		     *root = get("PKGMK_ROOT");
		char *automatic = NULL;
		if (!selected || !root ||
		    asprintf(&automatic, "%s/work", root) < 0) {
			free(selected);
			free(root);
			return -1;
		}
		bool automatic_work = !strcmp(selected, automatic);
		free(selected);
		free(root);
		free(automatic);
		if (managed_name || automatic_work) {
			char *name = get("name"), *path = NULL;
			int result =
			    name ? work_acquire(name, yes("PKGMK_FORCE")) : -1;
			if (result == 0 &&
			    asprintf(&path, "/var/tmp/pkgmk/%s", name) >= 0) {
				result = set("PKGMK_WORK_DIR", path);
				fprintf(stderr,
				    "pkgmk: Using tmpfs work directory "
				    "'%s'.\n",
				    path);
			} else {
				result = -1;
			}
			free(name);
			free(path);
			if (result != 0) {
				perror("pkgmk: managed work directory");
				call("native_exit", "1");
				return 1;
			}
		}
	}
	if (call("native_work_select", NULL) != 0)
		return 1;
	char *work = get("PKGMK_WORK_DIR");
	char *pkg = NULL, *src = NULL;
	int status = -1;
	if (!work || asprintf(&pkg, "%s/pkg", work) < 0 ||
	    asprintf(&src, "%s/src", work) < 0)
		goto release;
	status = set("PKG", pkg) < 0 || set("SRC", src) < 0 ? -1 : 0;
release:
	free(work);
	free(pkg);
	free(src);
	if (status < 0) {
		if (yes("PKGMK_TMPFS"))
			call("native_work_failed", NULL);
		return -1;
	}
	call("native_work_prepare", NULL);
	call("native_work_remove", NULL);
	call("native_work_mkdir", NULL);
	discard_checked_work = equals("PKGMK_KEEP_WORK", "no");
	if (equals("PKGMK_IGNORE_SIGNATURE", "no") ||
	    yes("PKGMK_CHECK_SIGNATURE")) {
		test("native_copy_signature", NULL);
		int signature = test("check_signature", NULL);
		if (signature < 0)
			return -1;
		if (signature == 0 && test("native_md5_absent", NULL) == 0) {
			discard_checked_work = false;
			return 0;
		}
	}
	int result = equals("PKGMK_IGNORE_MD5SUM", "no")
	                 ? call("check_md5sum", NULL)
	                 : 0;
	if (result >= 0)
		discard_checked_work = false;
	return result;
}

static int
recipe_build(void)
{
	char *directory = get("PKGMK_LOG_DIR");
	bool timed = yes("PKGMK_BUILD_TIME");
	struct timespec start, end;
	bool clock_ok;
	bool logging = directory && directory[0] && !capture_used &&
	               output[0] >= 0 && output[1] >= 0;
	if (directory && directory[0] && !logging) {
		fprintf(stderr, "pkgmk: warning: skipping separate recipe log "
		                "(capture used or unavailable).\n");
	}
	if (logging) {
		char *root = get("PKGMK_ROOT"), *path = NULL;
		if (root && asprintf(&path, "%s/%s", root, directory) >= 0) {
			const char *selected =
			    directory[0] == '/' ? directory : path;
			int dir =
			    open(selected, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
			unsigned long long random;
			char name[64];
			if (dir >= 0 && getrandom(&random, sizeof(random),
			                    0) == sizeof(random)) {
				snprintf(name, sizeof(name),
				    "recipe-%016llx.log", random);
				log_sink = openat(dir, name,
				    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW |
				        O_CLOEXEC,
				    0600);
				if (log_sink >= 0 &&
				    fchmod(log_sink, 0600) < 0) {
					close(log_sink);
					log_sink = -1;
				}
			}
			if (log_sink >= 0)
				fprintf(stderr, "pkgmk: Recipe log: %s/%s\n",
				    selected, name);
			else
				observation_warning();
			if (dir >= 0)
				close(dir);
		} else {
			observation_warning();
		}
		free(root);
		free(path);
		logging = log_sink >= 0;
	}
	free(directory);
	if (logging) {
		capture_used = true;
		for (int i = 0; i < 2; i++) {
			struct stat st;
			char number[64], variable[64];
			if (fstat(output[i], &st) < 0)
				break;
			snprintf(number, sizeof(number), "%llu",
			    (unsigned long long)st.st_dev);
			snprintf(variable, sizeof(variable),
			    "__imai_capture_dev%d", i);
			set(variable, number);
			snprintf(number, sizeof(number), "%llu",
			    (unsigned long long)st.st_ino);
			snprintf(variable, sizeof(variable),
			    "__imai_capture_ino%d", i);
			set(variable, number);
		}
		set("__imai_recipe_capture", "yes");
	}
	clock_ok = timed && clock_gettime(CLOCK_MONOTONIC, &start) == 0;
	int result = call("native_recipe_build", NULL);
	bool end_ok = timed && clock_gettime(CLOCK_MONOTONIC, &end) == 0;
	if (logging) {
		/* Do not wait for EOF: descendants may retain the writers. */
		for (int i = 0; i < 16; i++)
			relay();
		if (log_sink >= 0)
			close(log_sink);
		log_sink = -1;
		if (!finished && result >= 0)
			set("__imai_recipe_capture", "no");
	}
	if (timed) {
		if (clock_ok && end_ok)
			fprintf(stderr, "pkgmk: Recipe elapsed: %.3f s\n",
			    (double)(end.tv_sec - start.tv_sec) +
			        (double)(end.tv_nsec - start.tv_nsec) /
			            1000000000.0);
		else
			fprintf(stderr,
			    "pkgmk: warning: recipe clock unavailable.\n");
	}
	return result;
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
	int result = recipe_build();
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
			else {
				discard_checked_work =
				    equals("PKGMK_KEEP_WORK", "no");
				if (call("check_footprint", NULL) < 0)
					return -1;
				discard_checked_work = false;
			}
		}
	}
	if (equals("PKGMK_KEEP_WORK", "no")) {
		if (managed_name) {
			if (yes("BUILD_SUCCESSFUL")) {
				if (call("native_work_leave", NULL) != 0 ||
				    work_release() < 0) {
					perror("pkgmk: cannot release managed "
					       "work directory");
					return call("native_exit", "1");
				}
			}
		} else {
			call("remove_work_dir", NULL);
		}
	}
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
	if (strcmp(mode, "download-runner") == 0 && argc == 1) {
		char *end;
		long pid = strtol(argv[0], &end, 10);
		if (*end || pid < 0 || pid == 1 || pid > INT_MAX)
			return 1;
		downloader_runner = (sig_atomic_t)pid;
		if (pid && termination_requested)
			kill((pid_t)pid, termination_requested);
		return 0;
	}
	if (strcmp(mode, "parse") == 0)
		return parse(argc, argv);
	if (strcmp(mode, "main") == 0)
		return lifecycle();
	if (strcmp(mode, "recursive") == 0)
		return recursive(argc, argv);
	if (strcmp(mode, "work-interrupted") == 0) {
		termination_requested = 1;
		return 0;
	}
	if (strcmp(mode, "work-managed") == 0)
		return managed_name ? 0 : 1;
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
	int pipes[2][2] = {{-1, -1}, {-1, -1}};
	bool pipes_ok = fcntl(61, F_GETFD) < 0 && errno == EBADF &&
	                fcntl(62, F_GETFD) < 0 && errno == EBADF;
	for (int i = 0; pipes_ok && i < 2; i++) {
		int pair[2];
		if (pipe2(pair, O_CLOEXEC) < 0) {
			pipes_ok = false;
			break;
		}
		for (int j = 0; j < 2; j++) {
			pipes[i][j] = fcntl(pair[j], F_DUPFD_CLOEXEC, 64);
			close(pair[j]);
			if (pipes[i][j] < 0)
				pipes_ok = false;
		}
	}
	if (!pipes_ok) {
		for (int i = 0; i < 2; i++)
			for (int j = 0; j < 2; j++) {
				close(pipes[i][j]);
				pipes[i][j] = -1;
			}
	}
	pid_t child = fork();
	if (child < 0) {
		perror("pkgmk: fork");
		close(sockets[0]);
		close(sockets[1]);
		for (int i = 0; i < 2; i++)
			for (int j = 0; j < 2; j++)
				close(pipes[i][j]);
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
		bool inherited = pipes_ok;
		for (int i = 0; i < 2; i++) {
			close(pipes[i][0]);
			if (pipes_ok && dup2(pipes[i][1], 61 + i) < 0)
				inherited = false;
			close(pipes[i][1]);
		}
		if (pipes_ok && !inherited) {
			close(61);
			close(62);
		}
		execv("/bin/bash", args);
		perror("pkgmk: /bin/bash");
		_exit(1);
	}
	for (int i = 0; i < 2; i++) {
		close(pipes[i][1]);
		output[i] = pipes[i][0];
		if (output[i] >= 0 &&
		    fcntl(output[i], F_SETFL, O_NONBLOCK) < 0) {
			close(output[i]);
			output[i] = -1;
		}
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
		for (int i = 0; i < 2; i++)
			close(output[i]);
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
		if (done == child) {
			finished = true;
			break;
		}
		if (done < 0 && errno != EINTR) {
			status = 1 << 8;
			break;
		}
		int available = poll_channel();
		if (available < 0 && errno == EINTR)
			continue;
		if (available > 0) {
			char *unused = NULL;
			receive(&unused);
			free(unused);
		}
	}
	relay();
	for (int i = 0; i < 2; i++)
		close(output[i]);
	fclose(control);
	if (WIFSIGNALED(status))
		discard_checked_work = false;
	if (managed_name && finished && WIFEXITED(status) &&
	    !termination_requested)
		work_mark_retained();
	work_retained();
	if (work_lock >= 0)
		close(work_lock);
	if (work_base >= 0)
		close(work_base);
	return WIFEXITED(status) ? WEXITSTATUS(status)
	                         : 128 + WTERMSIG(status);
}
