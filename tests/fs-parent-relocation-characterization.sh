#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Demonstrate why scoped parent lookup alone cannot confine later unlinkat.
# All namespace mutations occur in disposable bubblewrap tmpfs.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/relocation.c" <<'EOF'
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/openat2.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int
main(void)
{
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	struct open_how how = {
		.flags = O_PATH | O_DIRECTORY | O_CLOEXEC,
		.resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	int parent = syscall(SYS_openat2, root, "writable/parent", &how,
	    sizeof(how));
	if (parent < 0) {
		perror("required openat2 protections unavailable");
		return 1;
	}
	/* Deterministic adversarial schedule: relocation after scoped lookup. */
	if (rename("/tmp/root/writable", "/tmp/outside/moved") < 0 ||
	    unlinkat(parent, "victim", 0) < 0)
		return 1;
	if (close(parent) < 0 || close(root) < 0)
		return 1;
	return 0;
}
EOF
${CC:-cc} -std=c23 -O2 -Wall -Wextra -Werror \
    "$work/relocation.c" -o "$work/relocation"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --ro-bind "$work/relocation" /tmp/relocation -- /bin/dash -eu -c '
mkdir -p /tmp/root/writable/parent /tmp/outside
printf "victim\n" >/tmp/root/writable/parent/victim
printf "sentinel\n" >/tmp/outside/sentinel
/tmp/relocation
[ -d /tmp/outside/moved/parent ]
[ ! -e /tmp/outside/moved/parent/victim ]
[ ! -e /tmp/root/writable ]
printf "sentinel\n" >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: reproduced post-lookup parent relocation outside selected root\n'
