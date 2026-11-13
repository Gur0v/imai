#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/ldconfig" <<'EOF'
#!/bin/dash
set -eu
[ "$#" -eq 2 ]
[ "$1" = -r ]
root=$2
if [ -e /tmp/ignored-term ]; then
    kill -TERM "$$"
    : >/tmp/helper-survived
fi
if [ -e /tmp/relocate ]; then
    mv /tmp/new /tmp/moved
    mkdir -p /tmp/new/var/lib/pkg
    printf 'replacement\n' >/tmp/new/var/lib/pkg/db
    : >/tmp/new/victim
fi
[ ! -e "$root/victim" ]
cmp "$root/var/lib/pkg/db" /tmp/before
printf '%s\n' "$root" >/tmp/helper-root
if [ -e /tmp/cancel ]; then
    kill -TERM "$PPID"
fi
exit 7
EOF
chmod 755 "$work/ldconfig"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --tmpfs /tmp --ro-bind "$work/ldconfig" /sbin/ldconfig \
    --ro-bind "$PWD/build/pkgrm" /tmp/bin-new/pkgrm \
    --ro-bind "$PWD/build/reference/pkgrm" /tmp/bin-old/pkgrm \
    -- /bin/dash -eu -c '
for tool in old new; do
    root=/tmp/$tool
    mkdir -p "$root/var/lib/pkg" "$root/etc"
    printf "alpha\n1\nvictim\n\n" >"$root/var/lib/pkg/db"
    cp "$root/var/lib/pkg/db" /tmp/before
    : >"$root/victim"
    : >"$root/etc/ld.so.conf"
    /tmp/bin-$tool/pkgrm -r "$root" alpha >/tmp/out 2>/tmp/err
    [ ! -s "$root/var/lib/pkg/db" ]
    cmp /tmp/before "$root/var/lib/pkg/db.backup"
    if [ "$tool" = new ]; then
        printf ".\n" >/tmp/expected
    else
        printf "%s/\n" "$root" >/tmp/expected
    fi
    cmp /tmp/expected /tmp/helper-root
    [ ! -s /tmp/out ]
    [ ! -s /tmp/err ]
done
root=/tmp/new
rm "$root/var/lib/pkg/db"
cp /tmp/before "$root/var/lib/pkg/db"
: >"$root/victim"
: >/tmp/cancel
/tmp/bin-new/pkgrm -r "$root" alpha >/tmp/out 2>/tmp/err
[ ! -e "$root/victim" ]
[ ! -s "$root/var/lib/pkg/db" ]
cmp /tmp/before "$root/var/lib/pkg/db.backup"
[ ! -s /tmp/out ]
printf "pkgrm: termination request deferred until operation completion\n" >/tmp/expected
cmp /tmp/expected /tmp/err
rm /tmp/cancel
rm "$root/var/lib/pkg/db"
cp /tmp/before "$root/var/lib/pkg/db"
: >"$root/victim"
: >/tmp/relocate
/tmp/bin-new/pkgrm -r "$root" alpha >/tmp/out 2>/tmp/err
[ ! -s /tmp/moved/var/lib/pkg/db ]
cmp /tmp/before /tmp/moved/var/lib/pkg/db.backup
[ ! -e /tmp/moved/victim ]
[ -f /tmp/new/victim ]
printf "replacement\n" >/tmp/expected
cmp /tmp/expected /tmp/new/var/lib/pkg/db
[ ! -e /tmp/new/var/lib/pkg/db.backup ]
[ ! -s /tmp/out ]
[ ! -s /tmp/err ]
rm /tmp/relocate
root=/tmp/ignored
mkdir -p "$root/var/lib/pkg" "$root/etc"
cp /tmp/before "$root/var/lib/pkg/db"
: >"$root/victim"
: >"$root/etc/ld.so.conf"
: >/tmp/ignored-term
(trap "" TERM; exec /tmp/bin-new/pkgrm -r "$root" alpha) >/tmp/out 2>/tmp/err
[ -f /tmp/helper-survived ]
[ ! -s "$root/var/lib/pkg/db" ]
[ ! -s /tmp/out ]
[ ! -s /tmp/err ]
'
printf 'PASS: helper failure status and deferred termination finalization\n'
