#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
candidate=${1:-$PWD/build/pkgadd}
reference=${2:-$PWD/build/reference/pkgadd}
helper=$(mktemp)
trap 'rm -f "$helper"' EXIT HUP INT TERM
cat >"$helper" <<'HELPER'
#!/bin/dash
set -eu
[ "$1" = -r ]
[ "$2" = . ]
[ -f keep ]
grep '^beta$' var/lib/pkg/db >/dev/null
[ -f var/lib/pkg/db.backup ]
printf called >helper-called
kill -TERM "$PPID"
exit 23
HELPER
chmod 755 "$helper"
# The package operations and all writable destinations live in isolated tmpfs.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / --dev /dev \
    --proc /proc \
    --tmpfs /tmp --ro-bind "$candidate" /tmp/bin-new/pkgadd \
    --ro-bind "$reference" /tmp/bin-old/pkgadd \
    --ro-bind "$helper" /sbin/ldconfig -- /bin/dash -eu -c '
mkdir -p /tmp/packages /tmp/payload/etc /tmp/payload/usr/share
printf "original\n" >/tmp/payload/etc/settings
printf "data\n" >/tmp/payload/usr/share/data
(cd /tmp/payload && bsdtar --uid 0 --gid 0 -cf /tmp/packages/alpha#1-1.pkg.tar.gz etc/ usr/)
for tool in old new; do
    root=/tmp/$tool
    mkdir -p "$root/var/lib/pkg" "$root/etc"
    : >"$root/var/lib/pkg/db"
    /tmp/bin-$tool/pkgadd -r "$root" /tmp/packages/alpha#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -s "/tmp/$tool.out" ]
    [ ! -s "/tmp/$tool.err" ]
    cmp /tmp/payload/etc/settings "$root/etc/settings"
    cmp /tmp/payload/usr/share/data "$root/usr/share/data"
    rm -f "/tmp/$tool.db"
    cp "$root/var/lib/pkg/db" "/tmp/$tool.db"
    status=0
    /tmp/bin-$tool/pkgadd -r "$root" /tmp/packages/alpha#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err" || status=$?
    [ "$status" -eq 1 ]
    grep "already installed (use -u to upgrade)" "/tmp/$tool.err" >/dev/null
    printf "UPGRADE ^etc/ NO\n" >"$root/etc/pkgadd.conf"
done
cmp /tmp/old.db /tmp/new.db
printf "updated\n" >/tmp/payload/etc/settings
printf "new-data\n" >/tmp/payload/usr/share/data
(cd /tmp/payload && bsdtar --uid 0 --gid 0 -cf /tmp/packages/alpha#2-1.pkg.tar.gz etc/ usr/)
for tool in old new; do
    root=/tmp/$tool
    /tmp/bin-$tool/pkgadd -u -r "$root" /tmp/packages/alpha#2-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -s "/tmp/$tool.err" ]
    printf "original\n" >/tmp/expected
    cmp /tmp/expected "$root/etc/settings"
    cmp /tmp/payload/etc/settings "$root/var/lib/pkg/rejected/etc/settings"
    cmp /tmp/payload/usr/share/data "$root/usr/share/data"
    grep "rejecting etc/settings, keeping existing version" "/tmp/$tool.out" >/dev/null
    rm -f "/tmp/$tool.db"
    cp "$root/var/lib/pkg/db" "/tmp/$tool.db"
done
cmp /tmp/old.db /tmp/new.db
cmp /tmp/old.out /tmp/new.out
for tool in old new; do
    root=/tmp/$tool
    cp /tmp/payload/etc/settings "$root/etc/settings"
    /tmp/bin-$tool/pkgadd -u -r "$root" /tmp/packages/alpha#2-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -e "$root/var/lib/pkg/rejected/etc/settings" ]
    [ ! -s "/tmp/$tool.out" ]
    [ ! -s "/tmp/$tool.err" ]
done
mkdir -p /tmp/filtered
printf "excluded\n" >/tmp/filtered/skip
printf "retained\n" >/tmp/filtered/keep
(cd /tmp/filtered && bsdtar --uid 0 --gid 0 -cf /tmp/packages/beta#1-1.pkg.tar.gz skip keep)
for tool in old new; do
    root=/tmp/$tool
    printf "INSTALL ^skip$ NO\n" >/tmp/filter.conf
    /tmp/bin-$tool/pkgadd -c /tmp/filter.conf -r "$root" /tmp/packages/beta#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -e "$root/skip" ]
    cmp /tmp/filtered/keep "$root/keep"
    [ ! -s "/tmp/$tool.err" ]
    grep "ignoring skip" "/tmp/$tool.out" >/dev/null
    rm -f "/tmp/$tool.db"
    cp "$root/var/lib/pkg/db" "/tmp/$tool.db"
done
cmp /tmp/old.db /tmp/new.db
cmp /tmp/old.out /tmp/new.out
mkdir -p /tmp/conflict
printf "replacement\n" >/tmp/conflict/keep
(cd /tmp/conflict && bsdtar --uid 0 --gid 0 -cf /tmp/packages/gamma#1-1.pkg.tar.gz keep)
for tool in old new; do
    root=/tmp/$tool
    status=0
    /tmp/bin-$tool/pkgadd -r "$root" /tmp/packages/gamma#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err" || status=$?
    [ "$status" -eq 1 ]
    grep "listed file(s) already installed" "/tmp/$tool.err" >/dev/null
    /tmp/bin-$tool/pkgadd -f -r "$root" /tmp/packages/gamma#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -s "/tmp/$tool.out" ]
    [ ! -s "/tmp/$tool.err" ]
    cmp /tmp/conflict/keep "$root/keep"
    rm -f "/tmp/$tool.db"
    cp "$root/var/lib/pkg/db" "/tmp/$tool.db"
done
cmp /tmp/old.db /tmp/new.db
mkdir -p /tmp/failure
python3 -I -c '\''import io,sys,tarfile
with tarfile.open(sys.argv[1], "w") as archive:
    link=tarfile.TarInfo("forward")
    link.type=tarfile.LNKTYPE
    link.linkname="later"
    archive.addfile(link)
    entry=tarfile.TarInfo("later")
    entry.size=4
    archive.addfile(entry,io.BytesIO(b"late"))
'\'' /tmp/packages/failure#1-1.pkg.tar.gz
for tool in old new; do
    root=/tmp/fail-$tool
    mkdir -p "$root/var/lib/pkg"
    : >"$root/var/lib/pkg/db"
    status=0
    /tmp/bin-$tool/pkgadd -r "$root" /tmp/packages/failure#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err" || status=$?
    [ "$status" -eq 1 ]
    [ ! -s "$root/var/lib/pkg/db" ]
    [ ! -e "$root/later" ]
    rm "$root/var/lib/pkg/db"
    printf "failure\n0\nold\n\n" >"$root/var/lib/pkg/db"
    : >"$root/old"
    /tmp/bin-$tool/pkgadd -u -r "$root" /tmp/packages/failure#1-1.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ ! -e "$root/old" ]
    printf late >/tmp/expected
    cmp /tmp/expected "$root/later"
    grep "could not install forward" "/tmp/$tool.err" >/dev/null
    rm -f "/tmp/$tool.db"
    cp "$root/var/lib/pkg/db" "/tmp/$tool.db"
done
cmp /tmp/old.db /tmp/new.db
python3 -I -c '\''import io,sys,tarfile
with tarfile.open(sys.argv[1], "w") as archive:
    for name,data in (("./settings",b"first"),("settings",b"second")):
        entry=tarfile.TarInfo(name)
        entry.size=len(data)
        entry.mode=0o644
        archive.addfile(entry,io.BytesIO(data))
'\'' /tmp/packages/aliases#2.pkg.tar.gz
for tool in old new; do
    root=/tmp/aliases-$tool
    mkdir -p "$root/var/lib/pkg" "$root/etc"
    printf "aliases\n1\nold\n\n" >"$root/var/lib/pkg/db"
    : >"$root/old"
    printf "UPGRADE .* NO\n" >"$root/etc/pkgadd.conf"
    /tmp/bin-$tool/pkgadd -u -r "$root" /tmp/packages/aliases#2.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    printf first >/tmp/expected
    cmp /tmp/expected "$root/settings"
    printf second >/tmp/expected
    cmp /tmp/expected "$root/var/lib/pkg/rejected/settings"
done
cmp /tmp/old.out /tmp/new.out
mkdir -p /tmp/dirmeta/kept
chmod 700 /tmp/dirmeta/kept
(cd /tmp/dirmeta && bsdtar --uid 0 --gid 0 -cf /tmp/packages/dirmeta#2.pkg.tar.gz kept/)
for mode in 755 700; do
    for tool in old new; do
        root=/tmp/dir-$mode-$tool
        mkdir -p "$root/var/lib/pkg" "$root/etc" "$root/kept"
        chmod "$mode" "$root/kept"
        printf "dirmeta\n1\nkept/\n\n" >"$root/var/lib/pkg/db"
        printf "UPGRADE .* NO\n" >"$root/etc/pkgadd.conf"
        /tmp/bin-$tool/pkgadd -u -r "$root" /tmp/packages/dirmeta#2.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
        if [ "$mode" = 755 ]; then
            [ -d "$root/var/lib/pkg/rejected/kept" ]
        else
            [ ! -d "$root/var/lib/pkg/rejected/kept" ]
        fi
    done
done
mkdir -p /tmp/mixed/kept
chmod 700 /tmp/mixed/kept
printf incoming >/tmp/mixed/kept/file
(cd /tmp/mixed && bsdtar --uid 0 --gid 0 -cf /tmp/packages/mixed#2.pkg.tar.gz kept/)
for tool in old new; do
    root=/tmp/mixed-$tool
    mkdir -p "$root/var/lib/pkg" "$root/etc" "$root/kept"
    chmod 755 "$root/kept"
    printf existing >"$root/kept/file"
    printf "mixed\n1\nkept/\nkept/file\n\n" >"$root/var/lib/pkg/db"
    printf "UPGRADE .* NO\n" >"$root/etc/pkgadd.conf"
    /tmp/bin-$tool/pkgadd -u -r "$root" /tmp/packages/mixed#2.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
done
cmp /tmp/old.out /tmp/new.out
python3 -I -c '\''import io,sys,tarfile
with tarfile.open(sys.argv[1], "w") as archive:
    link=tarfile.TarInfo("switch")
    link.type=tarfile.SYMTYPE
    link.linkname="target"
    archive.addfile(link)
    entry=tarfile.TarInfo("switch/new")
    entry.size=3
    archive.addfile(entry,io.BytesIO(b"new"))
'\'' /tmp/packages/replacement#2.pkg.tar.gz
for tool in old new; do
    root=/tmp/replacement-$tool
    mkdir -p "$root/var/lib/pkg" "$root/switch" "$root/target"
    printf "replacement\n1\nswitch/\nswitch/old\n\n" >"$root/var/lib/pkg/db"
    : >"$root/switch/old"
    /tmp/bin-$tool/pkgadd -u -f -r "$root" /tmp/packages/replacement#2.pkg.tar.gz >"/tmp/$tool.out" 2>"/tmp/$tool.err"
    [ -L "$root/switch" ]
    [ ! -e "$root/target/old" ]
    printf new >/tmp/expected
    cmp /tmp/expected "$root/target/new"
    rm -f "/tmp/$tool.db"
    cp "$root/var/lib/pkg/db" "/tmp/$tool.db"
done
cmp /tmp/old.db /tmp/new.db
cmp /tmp/old.out /tmp/new.out
cmp /tmp/old.err /tmp/new.err
python3 -I -c '\''import io,sys,tarfile
with tarfile.open(sys.argv[1], "w") as archive:
    for name in ("victim", "../outside"):
        entry=tarfile.TarInfo(name)
        entry.size=3
        archive.addfile(entry,io.BytesIO(b"bad"))
'\'' /tmp/packages/unsafe#1-1.pkg.tar.gz
root=/tmp/unsafe
mkdir -p "$root/var/lib/pkg"
printf "original" >"$root/victim"
printf "outside" >/tmp/outside
: >"$root/var/lib/pkg/db"
cp "$root/var/lib/pkg/db" /tmp/unsafe-db
status=0
/tmp/bin-new/pkgadd -f -r "$root" /tmp/packages/unsafe#1-1.pkg.tar.gz >/tmp/unsafe.out 2>/tmp/unsafe.err || status=$?
[ "$status" -eq 1 ]
printf original >/tmp/expected
cmp /tmp/expected "$root/victim"
printf outside >/tmp/expected
cmp /tmp/expected /tmp/outside
cmp /tmp/unsafe-db "$root/var/lib/pkg/db"
[ ! -e "$root/var/lib/pkg/db.backup" ]
root=/tmp/scoped
mkdir -p "$root/tmp/scoped/lib/pkg" "$root/tmp/config" /tmp/scoped/lib/pkg /tmp/config
ln -s /tmp/scoped "$root/var"
ln -s /tmp/config "$root/etc"
: >"$root/tmp/scoped/lib/pkg/db"
printf "outside-db" >/tmp/scoped/lib/pkg/db
printf "INSTALL ^skip$ NO\n" >"$root/tmp/config/pkgadd.conf"
printf "invalid outside configuration\n" >/tmp/config/pkgadd.conf
/tmp/bin-new/pkgadd -r "$root" /tmp/packages/beta#1-1.pkg.tar.gz >/tmp/scoped.out 2>/tmp/scoped.err
[ ! -e "$root/skip" ]
[ -f "$root/keep" ]
printf outside-db >/tmp/expected
cmp /tmp/expected /tmp/scoped/lib/pkg/db
root=/tmp/db-link
mkdir -p "$root/var/lib/pkg"
ln -s /tmp/scoped/lib/pkg/db "$root/var/lib/pkg/db"
status=0
/tmp/bin-new/pkgadd -r "$root" /tmp/packages/beta#1-1.pkg.tar.gz >/tmp/link.out 2>/tmp/link.err || status=$?
[ "$status" -eq 1 ]
[ ! -e "$root/keep" ]
cmp /tmp/expected /tmp/scoped/lib/pkg/db
root=/tmp/helper
mkdir -p "$root/var/lib/pkg" "$root/etc"
: >"$root/var/lib/pkg/db"
: >"$root/etc/ld.so.conf"
/tmp/bin-new/pkgadd -r "$root" /tmp/packages/beta#1-1.pkg.tar.gz >/tmp/helper.out 2>/tmp/helper.err
[ -f "$root/helper-called" ]
grep "termination request deferred until operation completion" /tmp/helper.err >/dev/null
grep "^beta$" "$root/var/lib/pkg/db" >/dev/null
root=/tmp/new
cp "$root/var/lib/pkg/db" /tmp/prior-db
status=0
/tmp/bin-new/pkgadd -c /tmp -r "$root" /tmp/packages/gamma#1-1.pkg.tar.gz >/tmp/read.out 2>/tmp/read.err || status=$?
[ "$status" -eq 1 ]
cmp /tmp/prior-db "$root/var/lib/pkg/db"
'
printf 'PASS: public install, upgrade rejection, exclusions, force ownership, and config failure\n'
