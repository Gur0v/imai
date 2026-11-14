#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
binary=${1:-$PWD/build/rejmerge}
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --ro-bind "$binary" /tmp/rejmerge \
    -- /bin/dash -eu -c '
root=/tmp/root
mkdir -p "$root/etc" "$root/var/lib/pkg/rejected/etc"
cat > "$root/etc/rejmerge.conf" <<"CONF"
main() {
    local marker=dynamic
    local CMD=before
    key
    [ "$CMD" = s ] || exit 8
    printf "parent-output\n"
    cd /tmp
    REJMERGE_ROOT=root
    REJECTED_DIR=root/var/lib/pkg/rejected
    walk "$REJECTED_DIR"
}
info_n() { marker=changed; printf "%s" "$1"; }
process_file() {
    [ "$entry" = "$1" ] || exit 10
    printf "%s\n" "$1" >> /tmp/entries
    metadata "$1" > /tmp/metadata
    cd /tmp
}
CONF
printf payload > "$root/var/lib/pkg/rejected/etc/a
back\\slash"
printf s | /tmp/rejmerge -r "$root" > /tmp/output
# key itself has no prompt, so dynamic locals persist across nested callbacks
# in the explicit menu invocation below instead.
grep -qx parent-output /tmp/output
[ "$(wc -l < /tmp/metadata)" = 1 ]
printf "root/var/lib/pkg/rejected/etc/a\nback\\\\slash\n" > /tmp/expected-entries
cmp /tmp/expected-entries /tmp/entries
cat > "$root/etc/rejmerge.conf" <<"CONF"
main() {
    local marker=dynamic
    permissions_menu /tmp/a /tmp/b
    [ "$marker" = changed ] || exit 11
}
info_n() { marker=changed; printf "%s" "$1"; }
stat() { printf "display\n"; }
CONF
printf s | /tmp/rejmerge -r "$root" > /tmp/output
cat > "$root/etc/rejmerge.conf" <<"CONF"
main() { permissions_menu /tmp/a /tmp/b; }
stat() { kill -TERM "$$"; }
CONF
status=0
/tmp/rejmerge -r "$root" >/tmp/output || status=$?
[ "$status" = 1 ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
set -e
files_regular() { false; printf predicate > /tmp/predicate; return 1; }
file_menu() { [ "$#" = 2 ] || exit 21; printf special > /tmp/special; }
main() { process_file "$REJECTED_DIR/etc/plain"; }
CONF
printf old > "$root/etc/plain"
printf new > "$root/var/lib/pkg/rejected/etc/plain"
/tmp/rejmerge -r "$root" >/tmp/output
[ "$(cat /tmp/predicate)" = predicate ]
[ "$(cat /tmp/special)" = special ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
set -e
main() { process_file "$REJECTED_DIR/etc/plain"; }
more() { cat; }
CONF
printf s | /tmp/rejmerge -r "$root" >/tmp/output
cat > "$root/etc/rejmerge.conf" <<"CONF"
GLOBIGNORE="$REJECTED_DIR/etc/plain"
main() { walk "$REJECTED_DIR/etc"; }
process_file() { printf "%s\n" "$1" >> /tmp/glob-entries; }
CONF
/tmp/rejmerge -r "$root" >/tmp/output
if grep -q /plain /tmp/glob-entries; then exit 22; fi
cat > "$root/etc/rejmerge.conf" <<"CONF"
more() { cat; }
file_menu() { exit 23; }
main() {
    diff_menu /tmp/source /tmp/rejected
    [ ! -s "$TMPFILE" ] || exit 24
    merge_menu /tmp/source /tmp/rejected
    [ ! -s "$TMPFILE" ] || exit 25
}
CONF
printf old > /tmp/source
printf new > /tmp/rejected
printf ss | /tmp/rejmerge -r "$root" >/tmp/output
cat > "$root/etc/rejmerge.conf" <<"CONF"
set -e
info() { false; touch /tmp/incorrect-errexit; }
main() { permissions_menu /tmp/source /tmp/rejected; }
CONF
status=0
/tmp/rejmerge -r "$root" >/tmp/output || status=$?
[ "$status" = 1 ]
[ ! -e /tmp/incorrect-errexit ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
permissions_menu() {
    [ "$INSTALLED_FILE" = "$REJMERGE_ROOT/etc/plain" ] || exit 31
    [ "$REJECTED_FILE" = "$REJECTED_DIR/etc/plain" ] || exit 32
    [ "$REJECTED_FILES_FOUND" = yes ] || exit 33
    INSTALLED_FILE=/tmp/alternate
    REJECTED_FILE=/tmp/alternate-rejected
}
files_regular() {
    [ "$1" = /tmp/alternate ] && [ "$2" = /tmp/alternate-rejected ] || exit 34
    INSTALLED_FILE=/tmp/final
    REJECTED_FILE=/tmp/final-rejected
    return 0
}
diff_menu() { exit 35; }
atexit() {
    [ "$INSTALLED_FILE" = /tmp/final ] || exit 36
    [ "$REJECTED_FILE" = /tmp/final-rejected ] || exit 37
    [ "$REJECTED_FILES_FOUND" = yes ] || exit 38
}
CONF
chmod 600 "$root/etc/plain"
chmod 644 "$root/var/lib/pkg/rejected/etc/plain"
printf same > /tmp/final
printf same > /tmp/final-rejected
/tmp/rejmerge -r "$root" >/tmp/output
[ ! -e /tmp/final-rejected ]
[ -e "$root/var/lib/pkg/rejected/etc/plain" ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
info_n() { printf "custom:<%s>" "$1"; }
main() { info message; }
CONF
/tmp/rejmerge -r "$root" >/tmp/output
printf "custom:<message>\n" > /tmp/expected-info
cmp /tmp/expected-info /tmp/output
cat > "$root/etc/rejmerge.conf" <<"CONF"
files_regular() {
    [ "$REJECTED_FILES_FOUND" = yes ] || exit 39
    REJECTED_FILES_FOUND=no
    return 1
}
permissions_menu() { :; }
file_menu() { REJECTED_FILES_FOUND=no; }
CONF
/tmp/rejmerge -r "$root" >/tmp/output
grep -qx "Nothing to merge" /tmp/output
printf "exit 7\n" > "$root/etc/rejmerge.conf"
status=0
/tmp/rejmerge -r "$root" >/tmp/output || status=$?
[ "$status" = 7 ]
mkdir /tmp/fail-bin
cat > /tmp/fail-bin/mktemp <<"SH"
#!/bin/sh
mkdir /tmp/failed-work /tmp/failed-work/merge
printf "%s\n" /tmp/failed-work
SH
chmod 755 /tmp/fail-bin/mktemp
status=0
PATH=/tmp/fail-bin:$PATH /tmp/rejmerge -r "$root" >/tmp/output 2>/tmp/error || status=$?
[ "$status" = 1 ]
[ ! -e /tmp/failed-work ]
'
printf 'PASS: native workflow nested callbacks, dynamic locals, cwd and filename bytes\n'
