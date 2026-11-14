#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    "$harness/lookup-protection-regressions.c" -o "$work/deny"
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
