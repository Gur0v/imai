#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/archive.py" <<'EOF'
import io
import tarfile
with tarfile.open('/tmp/input#1.pkg.tar', 'w') as archive:
    entry = tarfile.TarInfo('alias/file')
    entry.mode = 0o4751
    entry.uid = 0
    entry.gid = 0
    entry.mtime = 123456789
    entry.size = 8
    archive.addfile(entry, io.BytesIO(b'payload\n'))
EOF
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${INSTALL_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src $(pkg-config --cflags libarchive) \
    "$harness/regular-payload-api.c" src/extraction/install.c src/fs/fs.c src/archive/archive.c \
    $(pkg-config --libs libarchive) -lz -lbz2 -o "$work/regular"
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --tmpfs /tmp --proc /proc --ro-bind "$work/regular" /tmp/regular \
    --ro-bind "$work/archive.py" /tmp/archive.py -- /bin/dash -eu -c '
mkdir -p /tmp/root/real
ln -s /real /tmp/root/alias
python3 -I /tmp/archive.py
/tmp/regular /tmp/input#1.pkg.tar
printf "payload\n" >/tmp/expected
cmp /tmp/expected /tmp/root/real/file
'
printf 'PASS: retained-stream regular payload and descriptor metadata\n'
