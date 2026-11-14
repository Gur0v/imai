#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2086
${CC:-cc} ${CONFIG_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$harness/rule-parser-api.c" src/config/config.c \
    -o "$work/config"
printf 'install yes\nupgrade yes\n' >"$work/default"
"$work/config" "$work/missing" etc/file >"$work/out" 2>"$work/err"
cmp "$work/default" "$work/out"
[ ! -s "$work/err" ]
mkdir "$work/directory"
status=0
"$work/config" "$work/directory" etc/file >"$work/out" 2>"$work/err" || status=$?
[ "$status" -eq 1 ]
grep -F 'could not read configuration' "$work/err" >/dev/null
printf '# comment\nINSTALL [ NO\nINSTALL .* YES\nINSTALL ^etc/ NO\nUPGRADE .* NO\nUPGRADE ^etc/file$ YES\n' >"$work/rules"
"$work/config" "$work/rules" etc/file >"$work/out"
printf 'install no\nupgrade yes\n' >"$work/expected"
cmp "$work/expected" "$work/out"
CONFIG_FD=1 "$work/config" "$work/rules" etc/file >"$work/out"
cmp "$work/expected" "$work/out"
"$work/config" "$work/rules" usr/file >"$work/out"
printf 'install yes\nupgrade no\n' >"$work/expected"
cmp "$work/expected" "$work/out"
for bad in blank comment extra event action regex long; do
    case $bad in
    blank) printf '   \n' >"$work/rules"; message='wrong number of arguments' ;;
    comment) printf ' # comment\n' >"$work/rules"; message='wrong number of arguments' ;;
    extra) printf 'INSTALL .* YES extra\n' >"$work/rules"; message='wrong number of arguments' ;;
    event) printf 'install .* YES\n' >"$work/rules"; message="unknown event" ;;
    action) printf 'INSTALL .* yes\n' >"$work/rules"; message="unknown action" ;;
    regex) printf 'INSTALL [ NO\n' >"$work/rules"; message='error compiling regular expression' ;;
    long) printf '%01024d\n' 0 >"$work/rules"; message='line too long' ;;
    esac
    status=0
    "$work/config" "$work/rules" etc/file >"$work/out" 2>"$work/err" || status=$?
    [ "$status" -eq 1 ]
    grep -F "$message" "$work/err" >/dev/null
done
printf 'PASS: configuration parsing, lazy regexes, and last-match precedence\n'
