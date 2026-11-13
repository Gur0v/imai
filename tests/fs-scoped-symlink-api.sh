#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/symlink.c" <<'EOF'
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
	if (root < 0 ||
	    fs_symlink(root, "/tmp/outside/sentinel", "alias/absolute") < 0 ||
	    fs_symlink(root, "../../outside/sentinel", "alias/relative") < 0 ||
	    fs_symlink(root, "replacement", "alias/absolute") == 0 || errno != EEXIST ||
	    fs_symlink(root, "target", "../outside/bad") == 0 || errno != EINVAL)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/bad", outside);
	if (fs_symlink(root, "target", magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$work/symlink.c" src/fs.c -o "$work/symlink"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/symlink" /tmp/symlink -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/outside
printf sentinel >/tmp/outside/sentinel
ln -s /real /tmp/root/alias
/tmp/symlink
[ "$(readlink /tmp/root/real/absolute)" = /tmp/outside/sentinel ]
[ "$(readlink /tmp/root/real/relative)" = ../../outside/sentinel ]
[ ! -e /tmp/outside/bad ]
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: scoped symlink creation preserves target bytes\n'
