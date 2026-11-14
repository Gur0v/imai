#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$harness/scoped-symlink-api.c" src/fs/fs.c -o "$work/symlink"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/symlink" /tmp/symlink -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/outside
printf sentinel >/tmp/outside/sentinel
ln -s /real /tmp/root/alias
/tmp/symlink
[ "$(readlink /tmp/root/real/absolute)" = /tmp/outside/sentinel ]
[ "$(readlink /tmp/root/real/relative)" = ../../outside/sentinel ]
[ ! -e /tmp/outside/bad ]
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: scoped symlink creation preserves target bytes\n'
