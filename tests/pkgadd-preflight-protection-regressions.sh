#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
candidate=${1:-$PWD/build/pkgadd}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cp "$candidate" "$work/pkgadd"
cat >"$work/deny.c" <<'EOF'
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc < 3)
		return 125;
	int number;
	if (!strcmp(argv[1], "openat2"))
		number = SYS_openat2;
	else if (!strcmp(argv[1], "fchmodat2"))
		number = SYS_fchmodat2;
	else
		return 125;
	struct sock_filter filter[] = {
	    BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
	        offsetof(struct seccomp_data, nr)),
	    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, number, 0, 1),
	    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS),
	    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
	};
	struct sock_fprog program = {
	    .len = sizeof(filter) / sizeof(*filter),
	    .filter = filter,
	};
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0 ||
	    prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) < 0)
		return 125;
	execv(argv[2], argv + 2);
	return 126;
}
EOF
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    "$work/deny.c" -o "$work/deny"
# The incoming directory requires fchmodat2 for its final permissions.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --ro-bind "$work/deny" /tmp/deny \
    --ro-bind "$work/pkgadd" /tmp/bin/pkgadd -- /bin/dash -eu -c '
mkdir /tmp/packages
python3 -I - /tmp/packages <<"PY"
import bz2
import gzip
import io
import lzma
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as archive:
    entry = tarfile.TarInfo("victim")
    entry.mode = 0o644
    entry.size = 11
    archive.addfile(entry, io.BytesIO(b"replacement"))
    entry = tarfile.TarInfo("new-directory/")
    entry.type = tarfile.DIRTYPE
    entry.mode = 0o700
    archive.addfile(entry)
plain = buffer.getvalue()
(root / "beta#1.pkg.tar.none").write_bytes(plain)
for suffix, encode, decode in [
    ("gzip", gzip.compress, gzip.decompress),
    ("bzip2", bz2.compress, bz2.decompress),
    ("xz", lzma.compress, lzma.decompress),
]:
    encoded = encode(plain + bytes(4 * 1024 * 1024))
    damaged = bytearray(encoded)
    damaged[-8] ^= 1
    for kind, stream in [("checksum", damaged), ("truncated", encoded[:-12])]:
        try:
            decode(stream)
        except (OSError, EOFError, ValueError, lzma.LZMAError):
            pass
        else:
            raise AssertionError("independent decoder accepted " + suffix)
        (root / (kind + "#1.pkg.tar." + suffix)).write_bytes(stream)
with tarfile.open(root / "chain#2.pkg.tar.none", "w") as archive:
    for path, kind, data in [("target", tarfile.REGTYPE, b"new"),
                             ("target/", tarfile.DIRTYPE, b""),
                             ("alias/file", tarfile.REGTYPE, b"safe")]:
        entry = tarfile.TarInfo(path)
        entry.type = kind
        entry.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
for filename, path in [("member#1.pkg.tar.none", "a\nb"),
                       ("bad\nname#1.pkg.tar.none", "victim"),
                       ("version#bad\nversion.pkg.tar.none", "victim")]:
    with tarfile.open(root / filename, "w") as archive:
        entry = tarfile.TarInfo(path)
        entry.size = 3
        archive.addfile(entry, io.BytesIO(b"bad"))
PY
for case in member name version; do
    root=/tmp/record-$case
    mkdir -p "$root/var/lib/pkg"
    printf "alpha\n1\nvictim\n\n" >"$root/var/lib/pkg/db"
    cp "$root/var/lib/pkg/db" /tmp/before-db
    for path in a b victim; do
        printf preserved >"$root/$path"
    done
    case $case in
        member) package=/tmp/packages/member#1.pkg.tar.none ;;
        name) package=$(printf "/tmp/packages/bad\nname#1.pkg.tar.none") ;;
        version) package=$(printf "/tmp/packages/version#bad\nversion.pkg.tar.none") ;;
    esac
    status=0
    /tmp/bin/pkgadd -f -r "$root" "$package" >/tmp/out 2>/tmp/err || status=$?
    if [ "$status" -ne 1 ]; then
        printf "FAIL: newline %s returned status %s\n" "$case" "$status" >&2
        exit 1
    fi
    cmp /tmp/before-db "$root/var/lib/pkg/db"
    for path in a b victim; do
        printf preserved >/tmp/expected
        cmp /tmp/expected "$root/$path"
    done
    [ ! -e "$root/var/lib/pkg/db.backup" ]
    [ ! -e "$root/var/lib/pkg/db.incomplete_transaction" ]
    [ ! -s /tmp/out ]
    grep "pkgadd: package record cannot be represented in database:" /tmp/err >/dev/null
    [ "$(find "$root" -type f | wc -l)" -eq 4 ]
done
for case in control openat2 fchmodat2 checksum-gzip truncated-gzip checksum-bzip2 truncated-bzip2 checksum-xz truncated-xz; do
    root=/tmp/root-$case
    mkdir -p "$root/var/lib/pkg"
    printf "alpha\n1\nvictim\n\n" >"$root/var/lib/pkg/db"
    printf original >"$root/victim"
    cp "$root/var/lib/pkg/db" /tmp/before-db
    cp "$root/victim" /tmp/before-victim
    package=/tmp/packages/beta#1.pkg.tar.none
    set -- /tmp/bin/pkgadd
    case "$case" in
        openat2|fchmodat2) set -- /tmp/deny "$case" /tmp/bin/pkgadd ;;
        checksum-*|truncated-*) package=/tmp/packages/${case%-*}#1.pkg.tar.${case#*-} ;;
    esac
    status=0
    "$@" -f -r "$root" "$package" >/tmp/out 2>/tmp/err || status=$?
    if [ "$case" = control ]; then
        [ "$status" -eq 0 ]
        printf replacement >/tmp/expected
        cmp /tmp/expected "$root/victim"
        [ -d "$root/new-directory" ]
        grep "^beta$" "$root/var/lib/pkg/db" >/dev/null
        [ -f "$root/var/lib/pkg/db.backup" ]
        continue
    fi
    if [ "$status" -ne 1 ]; then
        printf "FAIL: %s returned status %s\n" "$case" "$status" >&2
        exit 1
    fi
    cmp /tmp/before-db "$root/var/lib/pkg/db"
    cmp /tmp/before-victim "$root/victim"
    [ ! -e "$root/new-directory" ]
    [ ! -e "$root/var/lib/pkg/db.backup" ]
    [ ! -e "$root/var/lib/pkg/db.incomplete_transaction" ]
    [ ! -s /tmp/out ]
    [ -s /tmp/err ]
    case "$case" in
        openat2) grep "pkgadd: required root-scoped lookup unavailable:" /tmp/err >/dev/null ;;
        fchmodat2) grep "pkgadd: archive preflight failed:" /tmp/err >/dev/null ;;
    esac
done
root=/tmp/root-chain
mkdir -p "$root/var/lib/pkg"
printf "chain\n1\nold-missing\n\n" >"$root/var/lib/pkg/db"
cp "$root/var/lib/pkg/db" /tmp/chain-before
printf preserved >"$root/unrelated"
ln -s /proc/self/fd/0 "$root/target"
ln -s target "$root/alias"
/tmp/bin/pkgadd -u -f -r "$root" /tmp/packages/chain#2.pkg.tar.none >/tmp/out 2>/tmp/err
[ ! -s /tmp/out ]
[ ! -s /tmp/err ]
[ -d "$root/target" ]
[ "$(readlink "$root/alias")" = target ]
printf safe >/tmp/expected
cmp /tmp/expected "$root/target/file"
printf preserved >/tmp/expected
cmp /tmp/expected "$root/unrelated"
printf "chain\n2\nalias/file\ntarget\ntarget/\n\n" >/tmp/expected
cmp /tmp/expected "$root/var/lib/pkg/db"
cmp /tmp/chain-before "$root/var/lib/pkg/db.backup"
'
printf 'PASS: installer capability/archive refusal and ordered stale-chain upgrade\n'
