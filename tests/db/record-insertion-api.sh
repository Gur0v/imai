#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2086
${CC:-cc} ${DB_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$harness/record-insertion-api.c" src/db/db.c -o "$work/add"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --proc /proc --tmpfs /tmp \
    --ro-bind "$work/add" /tmp/add -- /bin/dash -eu -c '
mkdir -p /tmp/root/var/lib/pkg
printf "zeta\n2\nold\n\n" >/tmp/root/var/lib/pkg/db
/tmp/add
printf "zeta\n3\na\nz\n\n" >/tmp/expected
cmp /tmp/expected /tmp/root/var/lib/pkg/db
'
printf 'PASS: exclusive database insertion, replacement, and ownership transfer\n'
