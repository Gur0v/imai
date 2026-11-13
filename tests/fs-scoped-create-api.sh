#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/create.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "fs.h"

int
main(void)
{
	umask(0);
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	int fd = fs_create(root, "./alias//file");
	struct stat st;
	if (fd < 0 || write(fd, "payload", 7) != 7 || fstat(fd, &st) < 0 ||
	    (st.st_mode & 0777) != 0600 || !(fcntl(fd, F_GETFD) & FD_CLOEXEC) ||
	    close(fd) < 0)
		return 1;
	const char *existing[] = {"symbol", "hard", "dir", "alias/file"};
	for (unsigned i = 0; i < sizeof(existing) / sizeof(*existing); i++)
		if (fs_create(root, existing[i]) >= 0 || errno != EEXIST)
			return 1;
	if (fs_create(root, "../outside/bad") >= 0 || errno != EINVAL ||
	    fs_create(root, "/tmp/outside/bad") >= 0 || errno != EINVAL)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/bad", outside);
	if (fs_create(root, magic) >= 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$work/create.c" src/fs.c -o "$work/create"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/create" /tmp/create -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/root/dir /tmp/outside
printf sentinel >/tmp/outside/sentinel
ln -s /real /tmp/root/alias
ln -s /tmp/outside/sentinel /tmp/root/symbol
ln /tmp/outside/sentinel /tmp/root/hard
/tmp/create
printf payload >/tmp/expected
cmp /tmp/expected /tmp/root/real/file
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
[ -L /tmp/root/symbol ]
[ /tmp/root/hard -ef /tmp/outside/sentinel ]
[ ! -e /tmp/outside/bad ]
'
printf 'PASS: exclusive scoped regular-file creation without truncation\n'
