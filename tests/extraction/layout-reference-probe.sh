#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Reference extraction probes execute only inside disposable bubblewrap tmpfs.
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --tmpfs /tmp --ro-bind "$harness/layout-reference-probe.py" /tmp/layouts.py \
    --ro-bind "$PWD/build/reference/pkgadd" /tmp/pkgadd -- /bin/dash -eu -c '
python3 -I /tmp/layouts.py
for name in duplicate forward chain typechange alias spelling hard-symlink; do
    root=/tmp/$name
    mkdir -p "$root/var/lib/pkg"
    : >"$root/var/lib/pkg/db"
    mkdir -p "$root/real"
    status=0
    /tmp/pkgadd -r "$root" "/tmp/archives/$name#1.pkg.tar.gz" >"/tmp/$name.out" 2>"/tmp/$name.err" || status=$?
    printf "%s status=%s\n" "$name" "$status"
    case $name in
    duplicate)
        [ "$status" -eq 0 ]
        printf two >/tmp/expected
        cmp /tmp/expected "$root/file"
        ;;
    forward)
        [ "$status" -eq 1 ]
        [ ! -e "$root/file" ]
        [ ! -e "$root/alias" ]
        [ ! -s "$root/var/lib/pkg/db" ]
        ;;
    chain)
        [ "$status" -eq 0 ]
        [ "$root/file" -ef "$root/alias" ]
        [ "$root/file" -ef "$root/second" ]
        ;;
    alias)
        [ "$status" -eq 0 ]
        printf data >/tmp/expected
        cmp /tmp/expected "$root/real/file"
        [ -L "$root/alias" ]
        ;;
    spelling)
        [ "$status" -eq 0 ]
        printf data >/tmp/expected
        cmp /tmp/expected "$root/real/file"
        grep -F "./real//./file" "$root/var/lib/pkg/db" >/dev/null
        ;;
    hard-symlink)
        [ "$status" -eq 0 ]
        [ -L "$root/second" ]
        [ "$(readlink "$root/second")" = target ]
        ;;
    typechange)
        [ "$status" -eq 0 ]
        [ -L "$root/file" ]
        [ "$(readlink "$root/file")" = target ]
        ;;
    esac
done
'
printf 'PASS: reference duplicate, forward-link, chained-link, and type-change layouts\n'
