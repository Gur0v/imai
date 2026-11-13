#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/remove.c" <<'EOF'
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
	const char *paths[] = {"alias/file", "absolute/file", "final", "dangling",
	    "empty/", "nested/up/file", "escape/sentinel", "repeat//file",
	    "fifo", "hardlink", "./dots//./file"};
	for (unsigned i = 0; i < sizeof(paths) / sizeof(*paths); i++)
		if (fs_remove(root, paths[i]) < 0)
			return 1;
	const char *unsafe[] = {"", ".", "..", "/outside/sentinel",
	    "../outside/sentinel", "dir/../final", "dir/.", "///"};
	for (unsigned i = 0; i < sizeof(unsafe) / sizeof(*unsafe); i++)
		if (fs_remove(root, unsafe[i]) == 0 || errno != EINVAL)
			return 1;
	if (fs_remove(root, "alias/") == 0 ||
	    fs_remove(root, "nonempty/") == 0 ||
	    fs_remove(root, "missing") == 0 || errno != ENOENT)
		return 1;
	int outside = open("/tmp/outside", O_PATH | O_DIRECTORY | O_CLOEXEC);
	char magic[80];
	if (outside < 0)
		return 1;
	snprintf(magic, sizeof(magic), "proc/self/fd/%d/sentinel", outside);
	if (fs_remove(root, magic) == 0 || errno != ELOOP)
		return 1;
	return close(outside) < 0 || close(root) < 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$work/remove.c" src/fs.c -o "$work/remove"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/remove" /tmp/remove -- /bin/dash -eu -c '
mkdir -p /tmp/root/dir /tmp/root/other /tmp/root/empty /tmp/root/nonempty /tmp/outside
mkdir -p /tmp/root/nested /tmp/root/target /tmp/root/tmp/outside /tmp/root/repeat /tmp/root/dots
: >/tmp/root/dots/file
: >/tmp/root/repeat/file
mkfifo /tmp/root/fifo
ln -s ../target /tmp/root/nested/up
ln -s ../../tmp/outside /tmp/root/escape
: >/tmp/root/target/file
: >/tmp/root/tmp/outside/sentinel
printf "sentinel\n" >/tmp/outside/sentinel
ln /tmp/outside/sentinel /tmp/root/hardlink
printf "keep\n" >/tmp/root/nonempty/keep
: >/tmp/root/dir/file
: >/tmp/root/other/file
ln -s dir /tmp/root/alias
ln -s /other /tmp/root/absolute
ln -s /tmp/outside/sentinel /tmp/root/final
ln -s nowhere /tmp/root/dangling
/tmp/remove
[ ! -e /tmp/root/dir/file ]
[ ! -e /tmp/root/other/file ]
[ ! -L /tmp/root/final ]
[ ! -L /tmp/root/dangling ]
[ ! -d /tmp/root/empty ]
[ ! -e /tmp/root/fifo ]
[ ! -e /tmp/root/hardlink ]
[ ! -e /tmp/root/repeat/file ]
[ ! -e /tmp/root/dots/file ]
[ ! -e /tmp/root/target/file ]
[ ! -e /tmp/root/tmp/outside/sentinel ]
[ -L /tmp/root/alias ]
[ -f /tmp/root/nonempty/keep ]
printf "sentinel\n" >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: scoped filesystem removal and final symlink handling\n'
