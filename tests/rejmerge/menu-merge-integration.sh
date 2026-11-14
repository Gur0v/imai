#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
script=${1:-$PWD/build/rejmerge}
reference=${2:-$PWD/../pkgutils/rejmerge.in}
# All rejected-file and installed-file mutations occur in a disposable tmpfs.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --ro-bind "$script" /tmp/rejmerge \
    --ro-bind "$reference" /tmp/reference \
    -- /bin/dash -eu -c '
if [ "${REJMERGE_TEST_BUSYBOX:-0}" = 1 ]; then
    mkdir /tmp/applets
    busybox --install -s /tmp/applets
    for cmd in bash file diff; do
        ln -sf "$(command -v "$cmd")" "/tmp/applets/$cmd"
    done
    PATH=/tmp/applets
    export PATH
fi
# Upstream requires GNU --reference; it is checked in the native lane only.
if [ "${REJMERGE_TEST_BUSYBOX:-0}" != 1 ]; then
    for decision in k u s mi; do
        for tool in reference rejmerge; do
            d=/tmp/$tool-$decision
            mkdir -p "$d/etc" "$d/var/lib/pkg/rejected/etc"
            printf old > "$d/etc/a"
            printf new > "$d/var/lib/pkg/rejected/etc/a"
            chmod 640 "$d/etc/a" "$d/var/lib/pkg/rejected/etc/a"
            if [ "$tool" = reference ]; then
                printf %s "$decision" | bash /tmp/reference -r "$d" > /tmp/output
            else
                printf %s "$decision" | /tmp/rejmerge -r "$d" > /tmp/output
            fi
        done
        if [ "$decision" = mi ]; then
            for tool in reference rejmerge; do
                grep -q "END MERGE CONFLICT" "/tmp/$tool-$decision/etc/a"
            done
        else
            cmp "/tmp/reference-$decision/etc/a" "/tmp/rejmerge-$decision/etc/a"
        fi
        [ "$(stat -c %a "/tmp/reference-$decision/etc/a")" = \
          "$(stat -c %a "/tmp/rejmerge-$decision/etc/a")" ]
        if [ "$decision" = s ]; then
            cmp "/tmp/reference-$decision/var/lib/pkg/rejected/etc/a" \
                "/tmp/rejmerge-$decision/var/lib/pkg/rejected/etc/a"
        else
            [ ! -e "/tmp/reference-$decision/var/lib/pkg/rejected/etc/a" ]
            [ ! -e "/tmp/rejmerge-$decision/var/lib/pkg/rejected/etc/a" ]
        fi
    done
fi
root=/tmp/root
rej=$root/var/lib/pkg/rejected
mkdir -p "$rej/etc" "$root/etc"
run() {
    status=0
    /tmp/rejmerge -r "$root" || status=$?
    mkdir -p "$rej/etc"
    return "$status"
}
run > /tmp/out
grep -qx "Nothing to merge" /tmp/out
mkdir -p "$rej/etc"
printf same > "$root/etc/a"
printf same > "$rej/etc/a"
printf orphan > "$rej/etc/orphan"
run > /tmp/out
[ ! -e "$rej/etc/a" ]
[ ! -e "$rej/etc/orphan" ]
printf old > "$root/etc/a"
mkdir -p "$rej/etc"
printf new > "$rej/etc/a"
printf k | run > /tmp/out
[ "$(cat "$root/etc/a")" = old ]
[ ! -e "$rej/etc/a" ]
printf new > "$rej/etc/a"
chmod 640 "$rej/etc/a"
printf uu | run > /tmp/out
[ "$(cat "$root/etc/a")" = new ]
[ "$(stat -c %a "$root/etc/a")" = 640 ]
printf old > "$root/etc/a"
printf new > "$rej/etc/a"
chmod 640 "$rej/etc/a"
printf s | run > /tmp/out
[ -e "$rej/etc/a" ]
printf mi | run > /tmp/out
[ ! -e "$rej/etc/a" ]
grep -q "MERGE CONFLICT" "$root/etc/a"
[ "$(stat -c %a "$root/etc/a")" = 640 ]
printf old > "$root/etc/a b"
printf new > "$rej/etc/a b"
printf u | run > /tmp/out
[ "$(cat "$root/etc/a b")" = new ]
ln -s a "$root/etc/link"
ln -s missing "$rej/etc/link"
printf u | run > /tmp/out
[ "$(readlink "$root/etc/link")" = missing ]
printf target > "$root/etc/target"
chmod 600 "$root/etc/target"
ln -s target "$root/etc/source-link"
printf new > "$rej/etc/source-link"
chmod 644 "$rej/etc/source-link"
printf ku | run > /tmp/out
[ "$(stat -c %a "$root/etc/source-link")" = 600 ]
[ "$(cat "$root/etc/target")" = target ]
printf old > "$root/etc/a"
printf new > "$rej/etc/a"
if run </dev/null >/tmp/out; then exit 1; fi
[ -e "$rej/etc/a" ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
counter=0
labels=(first second)
rejmerge_diff() {
    counter=$((counter + 1))
    printf "%s:%s\n" "${labels[0]}" "$counter" > "$3"
}
rejmerge_merge() {
    printf "merged:%s\n" "$counter" > "$3"
    REJMERGE_MERGE_INFO="custom merge"
}
EDITOR="/bin/sh /tmp/editor"
CONF
printf "printf edited > \"\$1\"\n" > /tmp/editor
chmod 640 "$rej/etc/a"
printf mei | run > /tmp/out
[ "$(cat "$root/etc/a")" = edited ]
grep -q "custom merge" /tmp/out
cat > "$root/etc/rejmerge.conf" <<"CONF"
REJMERGE_ROOT=/tmp/root
state=(original)
rejmerge_diff() {
    state[0]=changed
    printf custom > "$3"
}
diff_menu() {
    rejmerge_diff "$1" "$2" "$TMPFILE"
    [ "${state[0]}" = changed ] || exit 9
    rm -f "$2"
}
CONF
printf old > "$root/etc/a"
printf new > "$rej/etc/a"
chmod 640 "$rej/etc/a"
run </dev/null >/tmp/out
[ ! -e "$rej/etc/a" ]
printf "exit 7\n" > "$root/etc/rejmerge.conf"
if run </dev/null >/tmp/out 2>/tmp/err; then exit 1; fi
printf "false\n" > "$root/etc/rejmerge.conf"
run </dev/null >/tmp/out 2>/tmp/err
cat > "$root/etc/rejmerge.conf" <<"CONF"
set -e
false
touch /tmp/errexit-marker
CONF
if run </dev/null >/tmp/out 2>/tmp/err; then exit 1; fi
[ ! -e /tmp/errexit-marker ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
TMPFILE=/tmp/configured-temp
CONF
printf old > "$root/etc/a"
printf new > "$rej/etc/a"
chmod 640 "$rej/etc/a"
printf s | run > /tmp/out
[ ! -e /tmp/configured-temp ]
printf old > "$root/etc/a"
printf new > "$rej/etc/a"
cat > "$root/etc/rejmerge.conf" <<"CONF"
REJMERGE_ROOT=/tmp/root
REJECTED_DIR=/tmp/root/var/lib/pkg/rejected
rejmerge_diff() { printf overridden > "$3"; }
CONF
chmod 640 "$rej/etc/a"
printf u | run > /tmp/out
[ "$(cat "$root/etc/a")" = new ]
cat > "$root/etc/rejmerge.conf" <<"CONF"
main() { key; printf "%s" "$CMD" >/tmp/key-byte; }
CONF
for byte in " " "
" "\\"; do
    printf "%s" "$byte" >/tmp/key-input
    run </tmp/key-input >/tmp/out
    cmp /tmp/key-input /tmp/key-byte
done
'
printf 'PASS: rejmerge keep/upgrade/merge/skip, metadata, links, whitespace and EOF\n'
