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
    "$harness/scoped-removal-api.c" src/fs/fs.c -o "$work/remove"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --proc /proc --proc /tmp/root/proc --ro-bind "$work/remove" /tmp/remove -- /bin/dash -eu -c '
mkdir -p /tmp/root/dir /tmp/root/other /tmp/root/empty /tmp/root/nonempty /tmp/outside
mkdir -p /tmp/root/nested /tmp/root/target /tmp/root/tmp/outside /tmp/root/repeat /tmp/root/dots
: >/tmp/root/dots/file
: >/tmp/root/repeat/file
mkfifo /tmp/root/fifo
ln -s ../target /tmp/root/nested/up
ln -s ../../tmp/outside /tmp/root/escape
: >/tmp/root/target/file
: >/tmp/root/tmp/outside/sentinel
printf "sentinel\n" >/tmp/outside/sentinel
ln /tmp/outside/sentinel /tmp/root/hardlink
printf "keep\n" >/tmp/root/nonempty/keep
: >/tmp/root/dir/file
: >/tmp/root/other/file
ln -s dir /tmp/root/alias
ln -s /other /tmp/root/absolute
ln -s /tmp/outside/sentinel /tmp/root/final
ln -s nowhere /tmp/root/dangling
/tmp/remove
[ ! -e /tmp/root/dir/file ]
[ ! -e /tmp/root/other/file ]
[ ! -L /tmp/root/final ]
[ ! -L /tmp/root/dangling ]
[ ! -d /tmp/root/empty ]
[ ! -e /tmp/root/fifo ]
[ ! -e /tmp/root/hardlink ]
[ ! -e /tmp/root/repeat/file ]
[ ! -e /tmp/root/dots/file ]
[ ! -e /tmp/root/target/file ]
[ ! -e /tmp/root/tmp/outside/sentinel ]
[ -L /tmp/root/alias ]
[ -f /tmp/root/nonempty/keep ]
printf "sentinel\n" >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: scoped filesystem removal and final symlink handling\n'
