#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires GCC 14.4, bubblewrap, mktemp, and an extracted glibc 2.40 sysroot.
set -eu
sysroot=${1:?usage: pinned-libc-c23-probe.sh /absolute/glibc-2.40-sysroot}
case $sysroot in
/*) ;;
*) printf 'baseline: sysroot must be absolute\n' >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/probe.c" <<'EOF'
#include <gnu/libc-version.h>
#include <stdckdint.h>
#include <stdio.h>
#include <string.h>

int
main(void)
{
	unsigned result;
	bool overflow = ckd_add(&result, ~0U, 1U);
	if (!overflow || strcmp(gnu_get_libc_version(), "2.40"))
		return 1;
	puts("PASS: static C23 and glibc 2.40 runtime probe");
	return 0;
}
EOF
# --sysroot alone can retain the compiler's absolute host libc search path.
# -B selects target startup objects/libc, retaining matching compiler libgcc.
${CC:-cc} --sysroot="$sysroot" -B"$sysroot/usr/lib/" -std=c23 \
    -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror \
    -fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=3 \
    -static -Wl,-z,relro,-z,now,-z,noexecstack \
    "$work/probe.c" -o "$work/probe"
bwrap --unshare-all --die-with-parent --ro-bind / / --chdir / -- \
    "$work/probe"
