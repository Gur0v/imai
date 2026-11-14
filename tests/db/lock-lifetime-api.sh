#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$work/root/var/lib/pkg"
printf 'sample\n1\nusr/file\n\n' >"$work/root/var/lib/pkg/db"
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -iquote src "$harness/lock-lifetime-api.c" src/db/db.c -o "$work/lock"
"$work/lock" "$work/root" "$work/root/var/lib/pkg"
