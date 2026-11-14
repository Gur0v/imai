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
    "$harness/scoped-create-api.c" src/fs/fs.c -o "$work/create"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/create" /tmp/create -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/root/dir /tmp/outside
printf sentinel >/tmp/outside/sentinel
ln -s /real /tmp/root/alias
ln -s /tmp/outside/sentinel /tmp/root/symbol
ln /tmp/outside/sentinel /tmp/root/hard
/tmp/create
printf payload >/tmp/expected
cmp /tmp/expected /tmp/root/real/file
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
[ -L /tmp/root/symbol ]
[ /tmp/root/hard -ef /tmp/outside/sentinel ]
[ ! -e /tmp/outside/bad ]
'
printf 'PASS: exclusive scoped regular-file creation without truncation\n'
