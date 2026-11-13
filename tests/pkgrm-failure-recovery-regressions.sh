#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test-only Linux seccomp injection requires x86-64 clone/clone3 syscalls.
set -eu
candidate=${1:-$PWD/build/pkgrm}
reference=${2:-$PWD/build/reference/pkgrm}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/launch.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc < 3)
		return 125;
	if (!strcmp(argv[1], "wait")) {
		/* SIG_IGN survives exec and makes waitpid return ECHILD. */
		if (signal(SIGCHLD, SIG_IGN) == SIG_ERR)
			return 125;
	} else {
		struct sock_filter filter[] = {
		    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
		        offsetof(struct seccomp_data, nr)),
		    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_clone, 0, 1),
		    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EAGAIN),
		    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_clone3, 0, 1),
		    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EAGAIN),
		    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
		};
		struct sock_fprog program = {
		    .len = sizeof(filter) / sizeof(*filter),
		    .filter = filter,
		};
		if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0 ||
		    prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) < 0)
			return 125;
	}
	execv(argv[2], argv + 2);
	return 126;
}
EOF
${CC:-cc} -std=c23 -Wall -Wextra -Werror "$work/launch.c" -o "$work/launch"
printf '#!/bin/dash\nexit 0\n' >"$work/ldconfig"
chmod 755 "$work/ldconfig"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind "$work/launch" /tmp/launch \
    --ro-bind "$work/ldconfig" /sbin/ldconfig \
    --ro-bind "$candidate" /tmp/new/pkgrm \
    --ro-bind "$reference" /tmp/old/pkgrm -- /bin/dash -eu -c '
for mode in fork wait backup; do
    for tool in new old; do
        root=/tmp/root
        mkdir -p "$root/var/lib/pkg" "$root/etc"
        printf "alpha\n1\nvictim\n\nzeta\n2\nshared\n\n" >"$root/var/lib/pkg/db"
        cp "$root/var/lib/pkg/db" /tmp/before
        : >"$root/victim"
        : >"$root/shared"
        : >"$root/etc/ld.so.conf"
        status=0
        if [ "$mode" = backup ]; then
            mkdir "$root/var/lib/pkg/db.backup"
            /tmp/$tool/pkgrm -r "$root" alpha >/tmp/out 2>/tmp/err || status=$?
        else
            /tmp/launch "$mode" /tmp/$tool/pkgrm -r "$root" alpha >/tmp/out 2>/tmp/err || status=$?
        fi
        [ "$status" -eq 1 ]
        [ ! -e "$root/victim" ]
        [ -f "$root/shared" ]
        [ ! -s /tmp/out ]
        case $mode in
        fork|wait)
            if [ "$tool" = new ]; then
                printf "zeta\n2\nshared\n\n" >/tmp/expected
                cmp /tmp/expected "$root/var/lib/pkg/db"
                cmp /tmp/before "$root/var/lib/pkg/db.backup"
            else
                cmp /tmp/before "$root/var/lib/pkg/db"
                [ ! -e "$root/var/lib/pkg/db.backup" ]
            fi
            [ ! -e "$root/var/lib/pkg/db.incomplete_transaction" ]
            grep "pkgrm: ${mode}.*() failed:" /tmp/err >/dev/null
            if [ "$tool" = new ]; then
                cp /tmp/err /tmp/new.err
            else
                cmp /tmp/new.err /tmp/err
            fi
            ;;
        backup)
            cmp /tmp/before "$root/var/lib/pkg/db"
            [ -d "$root/var/lib/pkg/db.backup" ]
            printf "zeta\n2\nshared\n\n" >/tmp/expected
            cmp /tmp/expected "$root/var/lib/pkg/db.incomplete_transaction"
            [ -s /tmp/err ]
            ;;
        esac
        flock -n "$root/var/lib/pkg" /bin/true
        rm -rf "$root"
    done
done
for tool in old new; do
    root=/tmp/root
    mkdir -p "$root/var/lib/pkg"
    printf "alpha\n1\nparent/child\n\n" >"$root/var/lib/pkg/db"
    cp "$root/var/lib/pkg/db" /tmp/before
    printf "parent sentinel\n" >"$root/parent"
    /tmp/$tool/pkgrm -r "$root" alpha >/tmp/$tool.out 2>/tmp/$tool.err
    [ ! -s "$root/var/lib/pkg/db" ]
    cmp /tmp/before "$root/var/lib/pkg/db.backup"
    printf "parent sentinel\n" >/tmp/expected
    cmp /tmp/expected "$root/parent"
    [ ! -s /tmp/$tool.out ]
    rm -rf "$root"
done
[ ! -s /tmp/old.err ]
cmp /tmp/old.err /tmp/new.err
'
printf 'PASS: removal failure recovery, lock release, and stale-path diagnostics\n'
