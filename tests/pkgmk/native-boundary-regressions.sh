#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
command=${1:-$root/build/pkgmk}
case $command in /*) ;; *) command=$PWD/$command ;; esac
# All executable configuration and generated files stay in a disposable root.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --ro-bind / / --dev /dev --proc /proc \
    --tmpfs /tmp --ro-bind "$command" /tmp/pkgmk --chdir /tmp -- /bin/dash -eu -c '
magic=$(od -An -tx1 -N4 /tmp/pkgmk | tr -d " \n")
[ "$magic" = 7f454c46 ]
printf abc >"input space"
printf "abc\\n" >"line
break"
printf abc >"back\\slash"
for algorithm in md5 sha256; do
    "${algorithm}sum" "input space" "line
break" "back\\slash" >expected
    /tmp/pkgmk --imai-internal digest "$algorithm" "input space" "line
break" "back\\slash" >actual
    cmp expected actual
    if /tmp/pkgmk --imai-internal digest "$algorithm" absent >out 2>err; then exit 1; fi
    [ -s err ]
done
if /tmp/pkgmk --imai-internal digest invalid "input space" >out 2>err; then exit 1; fi
printf abc | /tmp/pkgmk --imai-internal digest md5 >actual
printf abc | md5sum >expected
cmp expected actual
printf abc | /tmp/pkgmk --imai-internal digest md5 - - >actual
printf abc | md5sum - - >expected
cmp expected actual
if /tmp/pkgmk --imai-internal digest md5 "input space" >/dev/full 2>err; then exit 1; fi
[ -s err ]
/tmp/pkgmk --imai-internal check-directory /tmp
if /tmp/pkgmk --imai-internal check-directory absent; then exit 1; else [ "$?" = 1 ]; fi
if /tmp/pkgmk --imai-internal check-directory "input space"; then exit 1; else [ "$?" = 1 ]; fi
/tmp/pkgmk --imai-internal check-file "input space"
/tmp/pkgmk --imai-internal check-file absent
mkdir port
cd port
cat >Pkgfile <<"EOF"
name=native
version=1
release=1
source=("../input space")
declare -A state=([key]="persistent value")
build() { :; }
EOF
cat >"config file" <<"EOF"
[[ ${state[key]} == "persistent value" ]] || exit 91
[[ $0 == /tmp/pkgmk && $PKGMK_COMMAND == /tmp/pkgmk ]] || exit 92
PKGMK_IGNORE_SIGNATURE=yes
make_md5sum() { printf "%s\n" "override:${state[key]}"; }
EOF
/tmp/pkgmk -cf "config file" -um >out 2>err
printf "override:persistent value\n" >expected
cmp expected .md5sum
cat >"config file" <<"EOF"
PKGMK_IGNORE_SIGNATURE=yes
md5sum -c sums >checked || exit 95
sha256sum -c sha-sums >sha-checked || exit 96
EOF
md5sum "../input space" >sums
sha256sum "../input space" >sha-sums
/tmp/pkgmk -cf "config file" -um >out 2>err
printf "900150983cd24fb0d6963f7d28e17f72  input space\n" >expected
cmp expected .md5sum
cp Pkgfile original
printf abc >"back\\slash"
printf "\\nsource=(\"back\\\\\\\\slash\")\\n" >>Pkgfile
for lane in gnu busy; do
    if [ "$lane" = busy ]; then
        mkdir -p /tmp/busy
        busybox --install -s /tmp/busy
        PATH=/tmp/busy /tmp/pkgmk -cf "config file" -um >out 2>err
        PATH=/tmp/busy md5sum "back\\slash" >expected
    else
        /tmp/pkgmk -cf "config file" -um >out 2>err
        md5sum "back\\slash" >expected
    fi
    cmp expected .md5sum
done
mv original Pkgfile
cat >>"config file" <<"EOF"
md5sum() { printf "override-digest  input space\n"; }
sha256sum() { printf "override-sha  input space\n"; }
sha256sum "../input space" >sha-output
EOF
/tmp/pkgmk -cf "config file" -um >out 2>err
printf "override-sha  input space\n" >expected
cmp expected sha-output
printf "override-digest  input space\n" >expected
cmp expected .md5sum
bash -c '\''exec -a /proc/self/exe /tmp/pkgmk -cf "config file" -um'\'' >out 2>err
cmp expected .md5sum
cat >>"config file" <<"EOF"
exit 37
EOF
if /tmp/pkgmk -cf "config file" -um >out 2>err; then exit 1; else [ "$?" = 37 ]; fi
cat >"config file" <<"EOF"
PKGMK_KEEP_WORK=yes
kill -TERM "$$"
exit 93
EOF
if /tmp/pkgmk -cf "config file" -um >out 2>err; then exit 1; else [ "$?" = 1 ]; fi
grep -q "ERROR: Interrupted." err
'
printf 'PASS: native pkgmk ELF, digest bytes, argv and persistent overrides\n'
