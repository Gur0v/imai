#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${INSTALL_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src $(pkg-config --cflags libarchive) \
    "$harness/ordered-stream-api.c" src/extraction/install.c src/fs/fs.c src/archive/archive.c \
    $(pkg-config --libs libarchive) -lz -lbz2 -o "$work/stream"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --tmpfs /tmp --proc /proc --ro-bind "$work/stream" /tmp/stream \
    --ro-bind "$harness/ordered-stream-api.py" /tmp/archive.py -- /bin/dash -eu -c '
mkdir -p /tmp/root /tmp/outside
printf sentinel >/tmp/outside/sentinel
python3 -I /tmp/archive.py
/tmp/stream /tmp/ordered#1.pkg.tar
printf last >/tmp/expected
cmp /tmp/expected /tmp/root/real/file
[ /tmp/root/real/file -ef /tmp/root/hard ]
[ /tmp/root/hard -ef /tmp/root/chain ]
[ -L /tmp/root/changed ]
[ "$(readlink /tmp/root/changed)" = real/file ]
printf nested >/tmp/expected
cmp /tmp/expected /tmp/root/nested/parent/file
/tmp/stream /tmp/payload#1.pkg.tar
/tmp/stream /tmp/unknown#1.pkg.tar
/tmp/stream /tmp/spelling#1.pkg.tar
python3 -I -c '\''import os; assert os.stat("/tmp/root/spelled").st_mode & 0o777 == 0o700, "directory fixups lost original pathname ordering"'\''
printf old >/tmp/expected
cmp /tmp/expected /tmp/root/source
[ /tmp/root/source -ef /tmp/root/linked ]
[ -f /tmp/root/unknown ]
python3 -I -c '\''import os; assert os.stat("/tmp/root/linked").st_mode & 0o777 == 0o644'\''
printf original >/tmp/root/victim
if /tmp/stream /tmp/unsafe#1.pkg.tar; then exit 1; fi
printf original >/tmp/expected
cmp /tmp/expected /tmp/root/victim
printf sentinel >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
if /tmp/stream /tmp/forward#1.pkg.tar; then exit 1; fi
python3 -I -c '\''import os; s = os.stat("/tmp/root/partial"); assert s.st_mtime_ns != 123456789000000000, "fresh failure incorrectly finalized deferred metadata"'\''
[ ! -e /tmp/root/future ]
[ ! -e /tmp/root/forward ]
'
printf 'PASS: ordered snapshot extraction, aliases, links, and whole-archive path rejection\n'
