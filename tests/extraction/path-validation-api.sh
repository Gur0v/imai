#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${INSTALL_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src $(pkg-config --cflags libarchive) \
    "$harness/path-validation-api.c" src/extraction/install.c src/fs/fs.c $(pkg-config --libs libarchive) \
    -o "$work/paths"
"$work/paths"
printf 'PASS: all-header destination and hardlink path checks\n'
