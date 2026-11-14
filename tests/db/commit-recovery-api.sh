#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# All database writes execute inside a disposable bubblewrap filesystem.
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2086
${CC:-cc} ${DB_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -iquote src "$harness/commit-recovery-api.c" src/db/db.c -o "$work/write"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --ro-bind "$work/write" /tmp/write --ro-bind "$PWD/build/reference/pkginfo" /tmp/pkginfo \
    -- /bin/dash -eu -c '
mkdir -p /tmp/root/var/lib/pkg
printf "zeta\n2\nz\na\na\n\nalpha\n1\nb\n\n" >/tmp/root/var/lib/pkg/db
cp /tmp/root/var/lib/pkg/db /tmp/original
/tmp/write
printf "alpha\n1\nb\n\nzeta\n2\na\nz\n\n" >/tmp/expected
cmp /tmp/expected /tmp/root/var/lib/pkg/db
cmp /tmp/original /tmp/root/var/lib/pkg/db.backup
[ ! -e /tmp/root/var/lib/pkg/db.incomplete_transaction ]
/tmp/pkginfo -r /tmp/root -i >/tmp/out
printf "alpha 1\nzeta 2\n" >/tmp/expected
cmp /tmp/expected /tmp/out
cp /tmp/root/var/lib/pkg/db /tmp/before-failure
rm /tmp/root/var/lib/pkg/db.backup
mkdir /tmp/root/var/lib/pkg/db.backup
/tmp/write fail
cmp /tmp/before-failure /tmp/root/var/lib/pkg/db
cmp /tmp/before-failure /tmp/root/var/lib/pkg/db.incomplete_transaction
rmdir /tmp/root/var/lib/pkg/db.backup
rm /tmp/root/var/lib/pkg/db.incomplete_transaction
printf "sentinel\n" >/tmp/sentinel
ln -s /tmp/sentinel /tmp/root/var/lib/pkg/db.incomplete_transaction
/tmp/write
printf "sentinel\n" >/tmp/expected
cmp /tmp/expected /tmp/sentinel
'
printf 'PASS: database commit bytes, backup, locking, upstream interchange\n'
