#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "$root/build/release-test.XXXXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
set -f
# shellcheck disable=SC2086
${CC:-cc} ${CFLAGS:--std=c23 -O2} -ffunction-sections -fdata-sections ${LDFLAGS:-} \
    "$root/tests/pkgmk/harness/work-release.c" -Wl,--gc-sections \
    -Wl,--wrap=umount2 -Wl,--wrap=statx -o "$work/test"
mkdir "$work/tmp"
chmod 1777 "$work/tmp"
for scenario in transient busy identity denied; do
    bwrap --unshare-all --die-with-parent --uid 0 --gid 0 \
        --cap-add CAP_SYS_ADMIN --ro-bind / / --dev /dev --proc /proc \
        --tmpfs /tmp --bind "$work" /var -- "$work/test" "$scenario"
done
