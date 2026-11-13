#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/stream.c" <<'EOF'
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "archive.h"
#include "install.h"

int
main(int argc, char **argv)
{
	if (argc != 2)
		return 1;
	struct package_archive package = {0};
	if (package_archive_open(argv[1], &package) || unlink(argv[1]) < 0)
		return 1;
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	int result = install_stream(root, &package);
	if (result < 0 && !strstr(argv[1], "/unsafe#") &&
	    !strstr(argv[1], "/forward#"))
		perror("install_stream");
	struct stat st;
	bool ordered = strstr(argv[1], "/ordered#") != NULL;
	if (!result && ordered && (fstatat(root, "real", &st, 0) < 0 ||
	    (st.st_mode & 07777) != 0755 || st.st_mtim.tv_sec != 123456789))
		return 1;
	if (!result && ordered && (fstatat(root, "changed", &st, AT_SYMLINK_NOFOLLOW) < 0 ||
	    !S_ISLNK(st.st_mode) || st.st_uid != 0 || st.st_gid != 0 ||
	    st.st_mtim.tv_sec != 123456790))
		return 1;
	if (!result && ordered && (fstatat(root, "real/file", &st, 0) < 0 ||
	    st.st_mtim.tv_sec != 123456789))
		return 1;
	package_archive_free(&package);
	if (close(root) < 0)
		return 1;
	return result < 0;
}
EOF
cat >"$work/archive.py" <<'EOF'
import io
import tarfile

def make(name, entries):
    with tarfile.open('/tmp/' + name + '#1.pkg.tar', 'w') as archive:
        for path, value in entries:
            entry = tarfile.TarInfo(path)
            entry.mode = 0o755 if value is None else 0o644
            entry.mtime = 123456790 if isinstance(value, tuple) and value[0] == 'sym' else 123456789
            if value is None:
                entry.type = tarfile.DIRTYPE
            elif isinstance(value, tuple):
                entry.type = tarfile.LNKTYPE if value[0] == 'hard' else tarfile.SYMTYPE
                entry.linkname = value[1]
            else:
                value = value.encode()
                entry.size = len(value)
            archive.addfile(entry, io.BytesIO(value) if isinstance(value, bytes) else None)

make('ordered', [('real/', None), ('real/file', 'first'),
                 ('alias', ('sym', '/real')), ('alias/file', 'last'),
                 ('hard', ('hard', 'real/file')), ('chain', ('hard', 'hard')),
                 ('changed', 'regular'), ('changed', ('sym', 'real/file')),
                 ('nested/parent/file', 'nested')])
with tarfile.open('/tmp/payload#1.pkg.tar', 'w', format=tarfile.PAX_FORMAT) as archive:
    entry = tarfile.TarInfo('source'); entry.mode = 0o644; entry.size = 3
    archive.addfile(entry, io.BytesIO(b'old'))
    entry = tarfile.TarInfo('linked'); entry.type = tarfile.LNKTYPE
    entry.linkname = 'source'; entry.mode = 0o751; entry.size = 0
    archive.addfile(entry)
with tarfile.open('/tmp/unknown#1.pkg.tar', 'w') as archive:
    entry = tarfile.TarInfo('unknown'); entry.type = b's'; entry.mode = 0o600
    archive.addfile(entry)
with tarfile.open('/tmp/spelling#1.pkg.tar', 'w') as archive:
    for path, mode in [('./spelled/', 0o700), ('spelled/', 0o751)]:
        entry = tarfile.TarInfo(path); entry.type = tarfile.DIRTYPE
        entry.mode = mode; entry.mtime = 123456789
        archive.addfile(entry)
make('unsafe', [('victim', 'changed'), ('../outside/sentinel', 'bad')])
make('forward', [('partial/', None), ('partial/file', 'kept'),
                 ('forward', ('hard', 'future')), ('future', 'data')])
EOF
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${INSTALL_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src $(pkg-config --cflags libarchive) \
    "$work/stream.c" src/install.c src/fs.c src/archive.c \
    $(pkg-config --libs libarchive) -lz -lbz2 -o "$work/stream"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --tmpfs /tmp --proc /proc --ro-bind "$work/stream" /tmp/stream \
    --ro-bind "$work/archive.py" /tmp/archive.py -- /bin/dash -eu -c '
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
