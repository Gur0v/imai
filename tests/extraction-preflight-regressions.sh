#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/check.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/statfs.h>
#include <unistd.h>
#include "archive.h"
#include "install.h"
int __real_fstatfs(int fd, struct statfs *buf);
int __wrap_fstatfs(int fd, struct statfs *buf)
{
	const char *fault = getenv("STATFS_FAULT");
	if (fault && !strcmp(fault, "error")) {
		errno = EIO;
		return -1;
	}
	int result = __real_fstatfs(fd, buf);
	if (!result && fault && !strcmp(fault, "unknown"))
		buf->f_type = 0;
	return result;
}
int main(int argc, char **argv)
{
	if (argc != 3) return 1;
	struct package_archive p = {0};
	if (package_archive_open(argv[1], &p)) return 1;
	int root = open("/tmp/root", O_PATH | O_DIRECTORY);
	if (root < 0) return 1;
	int result;
	if (!strcmp(argv[2], "dangling")) {
		const char *originals[] = {"victim", "dangling"};
		const char *alternates[] = {NULL, "proc/self/fd/0/kept"};
		result = install_preflight_routes(root, &p, originals, alternates);
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	if (!strcmp(argv[2], "implicit")) {
		const char *originals[] = {"created/file", "created/"};
		const char *alternates[] = {NULL, "proc/self/fd/0/kept"};
		const char *removals[] = {"created"};
		result = install_preflight_routes_after(root, &p, originals, alternates,
		    removals, 1);
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	if (!strcmp(argv[2], "routes")) {
		const char *originals[] = {"real/file", "alias/file", "after"};
		const char *alternates[] = {NULL, "blocked/self/fd/0/kept", NULL};
		result = install_preflight_routes(root, &p, originals, alternates);
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	result = install_preflight(root, &p, NULL);
	if (!strcmp(argv[2], "reject") || !strcmp(argv[2], "failure")) {
		package_archive_free(&p);
		close(root);
		return result >= 0;
	}
	if (result < 0) { perror("preflight"); return 1; }
	struct rlimit limit = {32, 32};
	if (setrlimit(RLIMIT_NOFILE, &limit)) return 1;
	result = install_extract(root, &p, NULL, true, NULL, NULL);
	if (result) perror("extract");
	package_archive_free(&p);
	close(root);
	return result < 0;
}
EOF
cat >"$work/fixtures.py" <<'EOF'
import io, tarfile

def make(name, entries):
    with tarfile.open('/tmp/'+name+'#1.pkg.tar', 'w') as tar:
        for path, kind, target in entries:
            e=tarfile.TarInfo(path); e.mode=0o751; e.mtime=123456789
            e.type=kind
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE): e.linkname=target
            if kind==tarfile.REGTYPE:
                data=target.encode(); e.size=len(data)
                tar.addfile(e,io.BytesIO(data))
            else: tar.addfile(e)
make('magic', [('victim',tarfile.REGTYPE,'bad'),('proc/self/fd/0/x',tarfile.REGTYPE,'bad')])
make('plannedmagic', [('alias',tarfile.SYMTYPE,'/proc/self/fd/0'),('alias/x',tarfile.REGTYPE,'bad')])
make('loop', [('a',tarfile.SYMTYPE,'b'),('b',tarfile.SYMTYPE,'a'),('a/x',tarfile.REGTYPE,'bad')])
make('fifo', [('pipe',tarfile.FIFOTYPE,''), ('payload',tarfile.REGTYPE,'safe')])
make('many', [('d'+str(i)+'/',tarfile.DIRTYPE,'') for i in range(128)]+[('d0/file',tarfile.REGTYPE,'safe')])
make('duplicate', [('duplicate/',tarfile.DIRTYPE,''),('duplicate/',tarfile.DIRTYPE,'')])
make('mixed', [('real/file',tarfile.REGTYPE,'new'), ('alias/file',tarfile.REGTYPE,'kept'), ('after',tarfile.REGTYPE,'safe')])
make('dangling', [('victim',tarfile.REGTYPE,'new'), ('dangling',tarfile.REGTYPE,'kept')])
make('implicit', [('created/file',tarfile.REGTYPE,'new'), ('created/',tarfile.DIRTYPE,'')])
make('stale', [('src',tarfile.REGTYPE,'new'), ('dest',tarfile.LNKTYPE,'src'), ('dest/',tarfile.DIRTYPE,''), ('dest/file',tarfile.REGTYPE,'safe')])
make('failure', [('victim',tarfile.REGTYPE,'new'), ('bad',tarfile.SYMTYPE,'/safe'), ('bad/proc/self/fd/0/x',tarfile.REGTYPE,'bad')])
make('stalechain', [('target',tarfile.REGTYPE,'new'), ('target/',tarfile.DIRTYPE,''), ('aliaschain/file',tarfile.REGTYPE,'safe')])
make('relativechain', [('relative',tarfile.REGTYPE,'new'), ('relative/',tarfile.DIRTYPE,''), ('relalias/file',tarfile.REGTYPE,'safe')])
make('livechain', [('victim',tarfile.REGTYPE,'bad'), ('aliaschain/file',tarfile.REGTYPE,'bad')])
make('dirparent', [('parent',tarfile.REGTYPE,'old'), ('parent/child/',tarfile.DIRTYPE,''), ('parent/child/file',tarfile.REGTYPE,'safe')])
make('regularchild', [('parent',tarfile.REGTYPE,'old'), ('parent/child',tarfile.REGTYPE,'new')])
make('danglingdir', [('parent/child/',tarfile.DIRTYPE,'')])
make('finalcycle', [('cycle',tarfile.SYMTYPE,'cycle'), ('cycle/',tarfile.DIRTYPE,''), ('cycle/file',tarfile.REGTYPE,'safe')])
make('finalmagic', [('victim',tarfile.REGTYPE,'bad'), ('proc/self/fd/0/',tarfile.DIRTYPE,'')])
make('plannedfinalmagic', [('victim',tarfile.REGTYPE,'bad'), ('magicfinal',tarfile.SYMTYPE,'proc/self/fd/0'), ('magicfinal/',tarfile.DIRTYPE,'')])
EOF
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${INSTALL_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src $(pkg-config --cflags libarchive) \
    "$work/check.c" src/install.c src/fs.c src/archive.c \
    $(pkg-config --libs libarchive) -lz -lbz2 -Wl,--wrap=fstatfs -o "$work/check"
# The writable root and procfs mount must share the fixture process namespace.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --tmpfs /tmp --proc /proc --dir /tmp/root --proc /tmp/root/proc \
    --ro-bind "$work/check" /tmp/check \
    --ro-bind "$work/fixtures.py" /tmp/fixtures.py -- /bin/dash -eu -c '
python3 -I /tmp/fixtures.py
printf original >/tmp/root/victim
/tmp/check /tmp/magic#1.pkg.tar reject
/tmp/check /tmp/plannedmagic#1.pkg.tar reject
/tmp/check /tmp/finalmagic#1.pkg.tar reject
/tmp/check /tmp/plannedfinalmagic#1.pkg.tar reject
[ ! -e /tmp/root/magicfinal ]
/tmp/check /tmp/dirparent#1.pkg.tar extract
[ -d /tmp/root/parent/child ]
printf safe >/tmp/expected
cmp /tmp/expected /tmp/root/parent/child/file
rm -rf /tmp/root/parent
printf old >/tmp/root/parent
if /tmp/check /tmp/regularchild#1.pkg.tar extract; then
    exit 1
fi
[ -f /tmp/root/parent ]
[ ! -e /tmp/root/parent/child ]
rm /tmp/root/parent
ln -s missing /tmp/root/parent
if /tmp/check /tmp/danglingdir#1.pkg.tar extract; then
    exit 1
fi
[ -L /tmp/root/parent ]
/tmp/check /tmp/finalcycle#1.pkg.tar extract
[ -d /tmp/root/cycle ]
[ ! -L /tmp/root/cycle ]
printf safe >/tmp/expected
cmp /tmp/expected /tmp/root/cycle/file
/tmp/check /tmp/loop#1.pkg.tar reject
mkdir /tmp/root/real
ln -s real /tmp/root/alias
ln -s /proc /tmp/root/blocked
/tmp/check /tmp/mixed#1.pkg.tar routes
ln -s missing /tmp/root/dangling
/tmp/check /tmp/dangling#1.pkg.tar dangling
/tmp/check /tmp/implicit#1.pkg.tar implicit
mkdir /tmp/root/bad
ln -s /proc /tmp/root/bad/proc
/tmp/check /tmp/failure#1.pkg.tar failure
printf original >/tmp/expected
cmp /tmp/expected /tmp/root/victim
ln -s /proc/self/fd/0 /tmp/root/target
ln -s target /tmp/root/aliaschain
/tmp/check /tmp/livechain#1.pkg.tar reject
cmp /tmp/expected /tmp/root/victim
[ "$(readlink /tmp/root/target)" = /proc/self/fd/0 ]
for fault in error unknown; do
    STATFS_FAULT=$fault /tmp/check /tmp/stalechain#1.pkg.tar reject
    [ "$(readlink /tmp/root/target)" = /proc/self/fd/0 ]
    [ "$(readlink /tmp/root/aliaschain)" = target ]
    cmp /tmp/expected /tmp/root/victim
done
/tmp/check /tmp/stalechain#1.pkg.tar extract
[ -d /tmp/root/target ]
[ "$(readlink /tmp/root/aliaschain)" = target ]
printf safe >/tmp/expected
cmp /tmp/expected /tmp/root/target/file
ln -s relative /tmp/root/relative
ln -s relative /tmp/root/relalias
/tmp/check /tmp/relativechain#1.pkg.tar extract
[ -d /tmp/root/relative ]
cmp /tmp/expected /tmp/root/relative/file
ln -s /proc/self/fd/0 /tmp/root/src
/tmp/check /tmp/stale#1.pkg.tar extract
/tmp/check /tmp/fifo#1.pkg.tar extract
[ -p /tmp/root/pipe ]
/tmp/check /tmp/many#1.pkg.tar extract
/tmp/check /tmp/duplicate#1.pkg.tar extract
python3 -I -c '\''import os; assert os.stat("/tmp/root/d0").st_mtime_ns == 123456789000000000; assert os.stat("/tmp/root/pipe").st_mode & 0o777 == 0o751'\''
'
printf 'PASS: ordered destination preflight, FIFO metadata, and bounded directory descriptors\n'
