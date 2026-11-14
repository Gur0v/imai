#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
binary=${1:-$PWD/build/rejmerge}
magic=$(od -An -tx1 -N4 "$binary" | tr -d ' \n')
[ "$magic" = 7f454c46 ] || { printf 'rejmerge is not ELF\n' >&2; exit 1; }
# Metadata and permission changes occur only in the disposable tmpfs.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --ro-bind "$binary" /tmp/rejmerge \
    -- /bin/dash -eu -c '
root="/tmp/root with space"
mkdir -p "$root/etc" "$root/var/lib/pkg/rejected/etc"
printf source > /tmp/source
printf target > /tmp/target
chmod 4751 /tmp/source
chmod 600 /tmp/target
[ "$(/tmp/rejmerge --imai-internal metadata /tmp/source)" = "4751 0 0" ]
ln -s source /tmp/reference
[ "$(/tmp/rejmerge --imai-internal metadata /tmp/reference)" = "4751 0 0" ]
/tmp/rejmerge --imai-internal set-permissions /tmp/target 4751 0 0
[ "$(stat -c %a /tmp/target)" = 4751 ]
printf unrelated > /tmp/victim
chmod 600 /tmp/victim
ln -s victim /tmp/destination
/tmp/rejmerge --imai-internal set-permissions /tmp/destination 4751 0 0
[ "$(stat -c %a /tmp/victim)" = 600 ]
[ "$(cat /tmp/victim)" = unrelated ]
if /tmp/rejmerge --imai-internal metadata /tmp/absent; then exit 1; fi
if /tmp/rejmerge --imai-internal set-permissions /tmp/absent 600 0 0; then exit 1; fi
if /tmp/rejmerge --imai-internal nonsense; then exit 1; fi
if /tmp/rejmerge --imai-internal set-permissions /tmp/target 888 0 0; then exit 1; fi
if /tmp/rejmerge --imai-internal set-permissions /tmp/target 600 -1 0; then exit 1; fi
odd="/tmp/line
back\\slash"
printf unusual > "$odd"
chmod 640 "$odd"
[ "$(/tmp/rejmerge --imai-internal metadata "$odd")" = "640 0 0" ]
/tmp/rejmerge --imai-internal set-permissions "$odd" 600 0 0
[ "$(stat -c %a "$odd")" = 600 ]
if /tmp/rejmerge --imai-workflow invalid invalid >/tmp/workflow-error 2>&1; then exit 1; fi
grep -q "invalid workflow descriptors" /tmp/workflow-error
# Only the binary is mounted: no controller script may be required at runtime.
printf old > "$root/etc/a"
printf new > "$root/var/lib/pkg/rejected/etc/a"
printf "state=(persisted)\nmore() { cat; }\nmetadata() { printf \"640 0 0\\\\n\"; }\n" > "$root/etc/rejmerge.conf"
printf u | /tmp/rejmerge -r "$root" >/tmp/output
[ "$(cat "$root/etc/a")" = new ]
[ ! -e "$root/var/lib/pkg/rejected/etc/a" ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
stat() {
    if [ "$1" = -L ]; then printf "640 0 0\n"; else command stat "$@"; fi
}
chmod() { printf "%s\n" "$1" > /tmp/chmod-override; }
chown() { printf "%s\n" "$1" > /tmp/chown-override; }
main() { copy_permissions /tmp/source /tmp/target; }
CONF
/tmp/rejmerge -r "$root" >/tmp/output
[ "$(cat /tmp/chmod-override)" = 640 ]
[ "$(cat /tmp/chown-override)" = 0:0 ]
/tmp/rejmerge --version | grep -qx "rejmerge (imai) 0.1.2"
'
printf 'PASS: native rejmerge ELF, metadata, permissions and standalone controller\n'
