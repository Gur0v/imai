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
    -Wall -Wextra -Werror -iquote src "$harness/record-removal-api.c" src/db/db.c -o "$work/remove"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --ro-bind "$work/remove" /tmp/remove -- /bin/dash -eu -c '
mkdir -p /tmp/root/var/lib/pkg
printf "alpha\n1\nunique\nshared/\nlib64/a\n\nzeta\n2\nshared/\nlib/a\n\n" \
    >/tmp/root/var/lib/pkg/db
mkdir -p /tmp/shared/var/lib/pkg
printf "alpha\n1\nshared/\n\nzeta\n2\nshared/\n\n" \
    >/tmp/shared/var/lib/pkg/db
/tmp/remove
printf "zeta\n2\nlib/a\nshared/\n\n" >/tmp/expected
cmp /tmp/expected /tmp/root/var/lib/pkg/db
'
printf 'PASS: database removal preserves exact shared ownership\n'
