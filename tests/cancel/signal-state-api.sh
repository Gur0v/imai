#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -iquote src "$harness/signal-state-api.c" src/cancel/cancel.c -o "$work/cancel"
"$work/cancel" >"$work/out" 2>"$work/err"
printf 'finalized\n' >"$work/expected"
cmp "$work/expected" "$work/out"
printf 'pkgrm: termination request deferred until operation completion\n' >"$work/expected"
cmp "$work/expected" "$work/err"
printf 'PASS: deferred termination and restored signal disposition\n'
