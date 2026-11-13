#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/mkdirs.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include "fs.h"

int
main(void)
{
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	const char *paths[] = {"./new//deep", "alias/child", "absolute/child",
	    "up/child", "alias/link/new", "alias/relative/next", "."};
	for (unsigned i = 0; i < sizeof(paths) / sizeof(*paths); i++)
		if (fs_mkdirs(root, paths[i]) < 0)
			return 1;
	if (fs_mkdirs(root, "../outside/bad") == 0 || errno != EINVAL ||
	    fs_mkdirs(root, "/tmp/outside/bad") == 0 || errno != EINVAL ||
	    fs_mkdirs(root, "file/child") == 0 || errno != ENOTDIR ||
	    fs_mkdirs(root, "dangling/child") == 0)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/bad", outside);
	if (fs_mkdirs(root, magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
EOF
cat >"$work/replace.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fs.h"

static int outside;
static unsigned injections;
int __real_mkdirat(int dir, const char *path, mode_t mode);

int
__wrap_mkdirat(int dir, const char *path, mode_t mode)
{
	if (!strcmp(path, "race-dir")) {
		if (__real_mkdirat(dir, path, mode) < 0)
			return -1;
	} else if (!strcmp(path, "race-file")) {
		int fd = openat(dir, path, O_WRONLY | O_CREAT | O_EXCL, 0600);
		if (fd < 0 || close(fd) < 0)
			return -1;
	} else if (!strcmp(path, "race-magic")) {
		char target[80];
		snprintf(target, sizeof(target), "/proc/self/fd/%d", outside);
		if (symlinkat(target, dir, path) < 0)
			return -1;
	} else {
		return __real_mkdirat(dir, path, mode);
	}
	injections++;
	return __real_mkdirat(dir, path, mode);
}

int
main(void)
{
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0 || outside < 0 ||
	    fs_mkdirs(root, "race-dir/child") < 0 ||
	    fs_mkdirs(root, "race-file/child") == 0 || errno != ENOTDIR ||
	    fs_mkdirs(root, "race-magic/child") == 0 || errno != ELOOP ||
	    injections != 3)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$work/mkdirs.c" src/fs.c -o "$work/mkdirs"
# GNU-compatible linker wrapping schedules replacement without product hooks.
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$work/replace.c" src/fs.c -Wl,--wrap=mkdirat -o "$work/replace"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp --proc /proc --proc /tmp/root/proc \
    --ro-bind "$work/mkdirs" /tmp/mkdirs --ro-bind "$work/replace" /tmp/replace -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/root/other /tmp/root/tmp/outside /tmp/outside
printf sentinel >/tmp/outside/sentinel
ln -s real /tmp/root/alias
ln -s /other /tmp/root/real/link
ln -s ../other /tmp/root/real/relative
ln -s /other /tmp/root/absolute
ln -s ../../tmp/outside /tmp/root/up
ln -s absent /tmp/root/dangling
: >/tmp/root/file
/tmp/mkdirs
/tmp/replace
[ -d /tmp/root/race-dir/child ]
[ -f /tmp/root/race-file ]
[ -L /tmp/root/race-magic ]
[ -d /tmp/root/new/deep ]
[ -d /tmp/root/real/child ]
[ -d /tmp/root/other/child ]
[ -d /tmp/root/other/new ]
[ -d /tmp/root/other/next ]
[ ! -e /tmp/root/real/other ]
[ -d /tmp/root/tmp/outside/child ]
[ ! -e /tmp/outside/child ]
[ ! -e /tmp/outside/bad ]
[ ! -e /tmp/root/absent ]
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: root-scoped directory creation through aliases\n'
