#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/regular.c" <<'EOF'
#define _GNU_SOURCE
#include <archive.h>
#include <archive_entry.h>
#include <fcntl.h>
#include <stdio.h>
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
	if (package_archive_open(argv[1], &package) ||
	    install_paths_check(&package) < 0 || unlink(argv[1]) < 0)
		return 1;
	struct archive *reader = archive_read_new();
	struct archive_entry *entry;
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (!reader || root < 0 ||
	    archive_read_support_format_tar(reader) != ARCHIVE_OK ||
	    archive_read_open_FILE(reader, package.stream) != ARCHIVE_OK ||
	    archive_read_next_header(reader, &entry) != ARCHIVE_OK ||
	    install_regular(root, "alias/file", reader, entry) < 0)
		return 1;
	struct stat st;
	if (fstatat(root, "real/file", &st, 0) < 0 ||
	    st.st_size != 8 || (st.st_mode & 07777) != 04751 ||
	    st.st_uid != 0 || st.st_gid != 0 || st.st_mtim.tv_sec != 123456789 ||
	    archive_read_next_header(reader, &entry) != ARCHIVE_EOF)
		return 1;
	archive_read_free(reader);
	package_archive_free(&package);
	return close(root) < 0;
}
EOF
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
    "$work/regular.c" src/install.c src/fs.c src/archive.c \
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
