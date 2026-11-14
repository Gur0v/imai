#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
command=${1:-$root/build/pkgmk}
case $command in /*) ;; *) command=$PWD/$command ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
# shellcheck disable=SC2086
${CC:-cc} ${CPPFLAGS:-} ${CFLAGS:--std=c23} -I"$root/build" \
    -o "$work/runner" "$root/tests/pkgmk/harness/download-runner.c" \
    "$root/src/commands/pkgmk/pkgmk-workflow.c" ${LDFLAGS:-} \
    -Wl,--wrap=fork -lcrypto
bwrap --unshare-all --die-with-parent --ro-bind / / --dev /dev --proc /proc \
    --tmpfs /tmp --ro-bind "$work/runner" /tmp/runner -- /tmp/runner
bwrap --unshare-all --die-with-parent --ro-bind / / --dev /dev --proc /proc \
    --tmpfs /tmp --ro-bind "$command" /tmp/pkgmk \
    --ro-bind "$root/tests/pkgmk/harness/download-cancellation.py" /tmp/cancellation.py \
    --chdir /tmp -- python3 -I /tmp/cancellation.py /tmp/pkgmk
