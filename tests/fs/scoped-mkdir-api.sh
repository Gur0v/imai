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
    "$harness/scoped-mkdir-api.c" src/fs/fs.c -o "$work/mkdirs"
# GNU-compatible linker wrapping schedules replacement without product hooks.
# shellcheck disable=SC2086
${CC:-cc} ${FS_TEST_CFLAGS:-} -std=c23 -Wall -Wextra -Werror -iquote src \
    "$harness/scoped-mkdir-api-replace.c" src/fs/fs.c -Wl,--wrap=mkdirat -o "$work/replace"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp --proc /proc --proc /tmp/root/proc \
    --ro-bind "$work/mkdirs" /tmp/mkdirs --ro-bind "$work/replace" /tmp/replace -- /bin/dash -eu -c '
mkdir -p /tmp/root/real /tmp/root/other /tmp/root/tmp/outside /tmp/outside
printf sentinel >/tmp/outside/sentinel
ln -s real /tmp/root/alias
ln -s /other /tmp/root/real/link
ln -s ../other /tmp/root/real/relative
ln -s /other /tmp/root/absolute
ln -s ../../tmp/outside /tmp/root/up
ln -s absent /tmp/root/dangling
: >/tmp/root/file
/tmp/mkdirs
/tmp/replace
[ -d /tmp/root/race-dir/child ]
[ -f /tmp/root/race-file ]
[ -L /tmp/root/race-magic ]
[ -d /tmp/root/new/deep ]
[ -d /tmp/root/real/child ]
[ -d /tmp/root/other/child ]
[ -d /tmp/root/other/new ]
[ -d /tmp/root/other/next ]
[ ! -e /tmp/root/real/other ]
[ -d /tmp/root/tmp/outside/child ]
[ ! -e /tmp/outside/child ]
[ ! -e /tmp/outside/bad ]
[ ! -e /tmp/root/absent ]
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: root-scoped directory creation through aliases\n'
