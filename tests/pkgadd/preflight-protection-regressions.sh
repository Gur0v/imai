#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
candidate=${1:-$PWD/build/pkgadd}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cp "$candidate" "$work/pkgadd"
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    "$harness/preflight-protection-regressions.c" -o "$work/deny"
# The incoming directory requires fchmodat2 for its final permissions.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --ro-bind "$harness/preflight-protection-regressions.py" /tmp/test-harness.py --ro-bind "$work/deny" /tmp/deny \
    --ro-bind "$work/pkgadd" /tmp/bin/pkgadd -- /bin/dash -eu -c '
mkdir /tmp/packages
python3 -I "/tmp/test-harness.py" /tmp/packages
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
