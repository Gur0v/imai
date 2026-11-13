#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/deny.c" <<'EOF'
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	struct sock_filter filter[] = {
	    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
	        offsetof(struct seccomp_data, nr)),
	    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_openat2, 0, 1),
	    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS),
	    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
	};
	struct sock_fprog program = {
	    .len = sizeof(filter) / sizeof(*filter),
	    .filter = filter,
	};
	if (argc < 2 || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0 ||
	    prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) < 0)
		return 125;
	execv(argv[1], argv + 1);
	return 126;
}
EOF
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    "$work/deny.c" -o "$work/deny"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --tmpfs /tmp --ro-bind "$work/deny" /tmp/deny \
    --ro-bind "$PWD/build/pkgrm" /tmp/pkgrm -- /bin/dash -eu -c '
mkdir -p /tmp/root/var/lib/pkg
for inventory in victim empty; do
    if [ "$inventory" = victim ]; then
        printf "alpha\n1\nvictim\n\n" >/tmp/root/var/lib/pkg/db
    else
        printf "alpha\n1\n\n" >/tmp/root/var/lib/pkg/db
    fi
    cp /tmp/root/var/lib/pkg/db /tmp/before
    : >/tmp/root/victim
    status=0
    /tmp/deny /tmp/pkgrm -r /tmp/root alpha >/tmp/out 2>/tmp/err || status=$?
    if [ "$status" -ne 1 ]; then
        printf "FAIL: unavailable openat2 returned status %s\n" "$status" >&2
        exit 1
    fi
    [ -f /tmp/root/victim ]
    cmp /tmp/before /tmp/root/var/lib/pkg/db
    [ ! -e /tmp/root/var/lib/pkg/db.backup ]
    [ ! -s /tmp/out ]
    grep "pkgrm: required root-scoped lookup unavailable:" /tmp/err >/dev/null
done
'
printf 'PASS: unavailable lookup protection prevents removal and DB changes\n'
