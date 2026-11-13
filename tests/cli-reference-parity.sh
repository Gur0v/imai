#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
candidate=${1:-$PWD/build}
reference=${2:-$PWD/build/reference}
only=${3:-all}
case $candidate in /*) ;; *) candidate=$PWD/$candidate ;; esac
case $reference in /*) ;; *) reference=$PWD/$reference ;; esac
# All command invocations, including unexpected successful parses, stay isolated.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp -- /bin/dash -eu -c '
candidate=$1
reference=$2
only=$3
mkdir -p /tmp/root/var/lib/pkg /tmp/root/etc
: >/tmp/root/var/lib/pkg/db
: >/tmp/not-directory
failures=0
checks=0
compare()
{
    command=$1
    shift
    old_status=0
    new_status=0
    # The reference empty archive filename reads stdin; supply deterministic EOF.
    "$reference/$command" "$@" </dev/null >/tmp/old.out 2>/tmp/old.err || old_status=$?
    "$candidate/$command" "$@" </dev/null >/tmp/new.out 2>/tmp/new.err || new_status=$?
    checks=$((checks + 1))
    if [ "$old_status" -ne "$new_status" ] ||
        ! cmp -s /tmp/old.out /tmp/new.out ||
        ! cmp -s /tmp/old.err /tmp/new.err; then
        failures=$((failures + 1))
        printf "FAIL: %s" "$command"
        for argument do printf " <%s>" "$argument"; done
        printf " (reference=%s candidate=%s)\n" "$old_status" "$new_status"
        diff -u /tmp/old.out /tmp/new.out || :
        diff -u /tmp/old.err /tmp/new.err || :
    fi
}
for command in pkgadd pkgrm pkginfo; do
    [ "$only" = all ] || [ "$only" = "$command" ] || continue
    compare "$command"
    compare "$command" --bad --help
    compare "$command" -r --help
    compare "$command" --root --help
    compare "$command" -r
    compare "$command" --root
    compare "$command" --
    compare "$command" -r /tmp/root --bad
    if [ "$command" = pkginfo ]; then
        compare "$command" -r /tmp/root -i
        compare "$command" -r /tmp/root -i -i
        compare "$command" -r /tmp/root -l missing -o "["
        compare "$command" -r /tmp/absent -o "["
        compare "$command" -r /tmp/root -o "["
        compare "$command" -r /tmp/root -l
        compare "$command" -r /tmp/root -l missing extra
        compare "$command" -r /tmp/absent -f /tmp/no-package
        compare "$command" -r /tmp/root -f ""
        compare "$command" -r /tmp/root -f -i
    else
        compare "$command" -r /tmp/root ""
        compare "$command" -r /tmp/root "" ""
        compare "$command" -r /tmp/root "" missing
        compare "$command" -r /tmp/root "" "" missing
        compare "$command" -r /tmp/root "" missing -r
        compare "$command" -r /tmp/root missing extra
        compare "$command" -r /tmp/root missing --bad
        compare "$command" -r /tmp/absent missing
        compare "$command" -r /tmp//absent/// missing
        compare "$command" -r /tmp/not-directory missing
        compare "$command" -r /tmp/root missing -r relative-missing
        compare "$command" -r /tmp/root missing -r -i
        if [ "$command" = pkgadd ]; then
            compare "$command" -r /tmp/root -c
            compare "$command" -r /tmp/root -c --help
            compare "$command" -r /tmp/root --config
        fi
    fi
    old_status=0
    new_status=0
    bash -c '\''exec -a "$1" "$2" --help'\'' sh "/fake/$command/" \
        "$reference/$command" >/tmp/old.out 2>/tmp/old.err || old_status=$?
    bash -c '\''exec -a "$1" "$2" --help'\'' sh "/fake/$command/" \
        "$candidate/$command" >/tmp/new.out 2>/tmp/new.err || new_status=$?
    checks=$((checks + 1))
    if [ "$old_status" -ne "$new_status" ] ||
        ! cmp -s /tmp/old.out /tmp/new.out ||
        ! cmp -s /tmp/old.err /tmp/new.err; then
        failures=$((failures + 1))
        printf "FAIL: trailing-slash argv[0] for %s (reference=%s candidate=%s)\n" \
            "$command" "$old_status" "$new_status"
        diff -u /tmp/old.out /tmp/new.out || :
        diff -u /tmp/old.err /tmp/new.err || :
    fi
done
printf "CLI differential: %s checks, %s mismatches\n" "$checks" "$failures"
[ "$failures" -eq 0 ]
' sh "$candidate" "$reference" "$only"
