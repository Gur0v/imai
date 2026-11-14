#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
command=${1:-$root/build/pkgmk}
case $command in /*) ;; *) command=$PWD/$command ;; esac
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --dev /dev --proc /proc \
    --tmpfs /tmp --ro-bind "$command" /tmp/pkgmk \
    --ro-bind "$root/tests/pkgmk/harness/recipe-observation.py" /tmp/observation.py \
    --chdir /tmp -- /bin/dash -eu -c '
mkdir port
cd port
mkdir logs
cat >Pkgfile <<"EOF"
name=observation
version=1
release=1
source=()
build() { printf "recipe-out\000bytes\n"; printf "recipe-err\n" >&2; mkdir -p "$PKG/usr"; printf payload >"$PKG/usr/file"; }
EOF
cat >config <<"EOF"
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
PKGMK_IGNORE_FOOTPRINT=yes
PKGMK_NO_STRIP=yes
PKGMK_LOG_DIR=logs
PKGMK_BUILD_TIME=yes
EOF
/tmp/pkgmk -cf config -f >out 2>err
set -- logs/*
[ "$#" = 1 ]
[ -f "$1" ]
[ "$(stat -c %a "$1")" = 600 ]
grep -q recipe-out "$1"
grep -q recipe-err "$1"
grep -q "Recipe elapsed:" err
grep -q "Recipe log:" err
! grep -q "Building .*succeeded" "$1"
printf "recipe-out\000bytes\n" >expected
# Live stdout retains binary bytes, while xtrace remains on stderr.
python3 -I -c '\''import pathlib; assert pathlib.Path("expected").read_bytes() in pathlib.Path("out").read_bytes()'\''
grep -q recipe-err err
cd /tmp
python3 -I /tmp/observation.py
'
