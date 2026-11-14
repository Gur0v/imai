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
    "$harness/scoped-hardlink-api.c" src/fs/fs.c -o "$work/link"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/link" /tmp/link -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/root/other /tmp/outside
printf payload >/tmp/root/real/file
printf sentinel >/tmp/outside/sentinel
ln -s real /tmp/root/alias
ln -s /other /tmp/root/absolute
ln -s /tmp/outside/sentinel /tmp/root/symbol
/tmp/link
[ /tmp/root/real/file -ef /tmp/root/other/link ]
[ /tmp/root/real/file -ef /tmp/root/chain ]
[ -L /tmp/root/symbol-copy ]
[ "$(readlink /tmp/root/symbol-copy)" = /tmp/outside/sentinel ]
[ ! -e /tmp/root/bad ]
[ ! -e /tmp/outside/bad ]
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: root-scoped hardlink endpoints and final symlink preservation\n'
