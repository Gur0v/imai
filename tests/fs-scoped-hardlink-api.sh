#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/link.c" <<'EOF'
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
	    fs_link(root, "./alias//file", "absolute/link") < 0 ||
	    fs_link(root, "absolute/link", "chain") < 0 ||
	    fs_link(root, "symbol", "symbol-copy") < 0)
		return 1;
	if (fs_link(root, "../outside/sentinel", "bad") == 0 || errno != EINVAL ||
	    fs_link(root, "alias/file", "../outside/bad") == 0 || errno != EINVAL ||
	    fs_link(root, "alias/file", "chain") == 0 || errno != EEXIST ||
	    fs_link(root, "missing", "bad") == 0 || errno != ENOENT)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/sentinel", outside);
	if (fs_link(root, magic, "bad") == 0 || errno != ELOOP ||
	    fs_link(root, "alias/file", magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$work/link.c" src/fs.c -o "$work/link"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/link" /tmp/link -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/root/other /tmp/outside
printf payload >/tmp/root/real/file
printf sentinel >/tmp/outside/sentinel
ln -s real /tmp/root/alias
ln -s /other /tmp/root/absolute
ln -s /tmp/outside/sentinel /tmp/root/symbol
/tmp/link
[ /tmp/root/real/file -ef /tmp/root/other/link ]
[ /tmp/root/real/file -ef /tmp/root/chain ]
[ -L /tmp/root/symbol-copy ]
[ "$(readlink /tmp/root/symbol-copy)" = /tmp/outside/sentinel ]
[ ! -e /tmp/root/bad ]
[ ! -e /tmp/outside/bad ]
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: root-scoped hardlink endpoints and final symlink preservation\n'
