#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
# Installation may write only to disposable staging, never the host tree.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --chdir "$root" \
    -- /bin/dash -eu -c '
root=$1
version=$2
stage="/tmp/staged installation"
make install DESTDIR="$stage"
for command in pkgadd pkgrm pkginfo pkgmk rejmerge; do
    "$stage/usr/bin/$command" --version > /tmp/version
    printf "%s (imai) %s\n" "$command" "$version" > /tmp/expected
    cmp /tmp/expected /tmp/version
    "$stage/usr/bin/$command" --help > /tmp/help
    [ -s /tmp/help ]
done
for command in pkgadd pkgmk rejmerge; do
    file="$stage/usr/bin/$command"
    [ "$(find "$file" -prune -type f -perm 0755 -print)" = "$file" ]
done
for command in pkgrm pkginfo; do
    file="$stage/usr/bin/$command"
    [ -L "$file" ]
    case $(LC_ALL=C ls -ld "$file") in
        *" -> pkgadd") ;;
        *) exit 1 ;;
    esac
done
[ ! -e "$stage/usr/bin/pkgmk-bash" ]
[ ! -e "$stage/usr/bin/rejmerge-bash" ]
for command in pkgmk rejmerge; do
    [ "$(od -An -tx1 -N4 "$stage/usr/bin/$command" | tr -d " \n")" = 7f454c46 ]
done
for command in pkgadd pkgmk rejmerge; do
    file="$stage/etc/$command.conf"
    cmp "$root/config/$command.conf" "$file"
    [ "$(find "$file" -prune -type f -perm 0644 -print)" = "$file" ]
done
for manual in pkgadd.8 pkgrm.8 pkginfo.8 pkgmk.8 rejmerge.8 pkgfile.5 pkgmk.conf.5; do
    section=${manual##*.}
    file="$stage/usr/share/man/man$section/$manual"
    sed "s/#VERSION#/$version/g" "$root/$manual.in" > /tmp/expected
    cmp /tmp/expected "$root/build/$manual"
    cmp /tmp/expected "$file"
    [ "$(find "$file" -prune -type f -perm 0644 -print)" = "$file" ]
done
mkdir /tmp/recipe
printf "name=probe\nversion=1\nrelease=1\nbuild() { :; }\n" > /tmp/recipe/Pkgfile
printf '\''. "$STAGED_CONFIG"\n[ "$CFLAGS" = "-O2 -march=x86-64 -pipe" ] || exit 1\nprintf "Bash evaluation reached\\n"\nexit 0\n'\'' > /tmp/probe.conf
(cd /tmp/recipe && STAGED_CONFIG="$stage/etc/pkgmk.conf" \
    "$stage/usr/bin/pkgmk" -cf /tmp/probe.conf) > /tmp/bridge
printf "Bash evaluation reached\n" > /tmp/expected
cmp /tmp/expected /tmp/bridge
chmod 600 "$stage/usr/bin/pkgadd" "$stage/etc/pkgadd.conf"
make install DESTDIR="$stage"
[ "$(find "$stage/usr/bin/pkgadd" -prune -perm 0755 -print)" = "$stage/usr/bin/pkgadd" ]
[ "$(find "$stage/etc/pkgadd.conf" -prune -perm 0644 -print)" = "$stage/etc/pkgadd.conf" ]
printf "staged installation checks passed\n"
' sh "$root" "${1:-0.1.1}"
