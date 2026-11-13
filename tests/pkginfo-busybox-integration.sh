#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires BusyBox with --install, dash, and the applets used by query tests.
set -eu
busybox=${BUSYBOX:-/usr/bin/busybox}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
"$busybox" --install -s "$work"
# Do not append the host PATH: a missing applet must fail, not fall back.
PATH="$work" /bin/dash tests/cli-common-options.sh "${1:-./build}"
PATH="$work" /bin/dash tests/pkginfo-database-queries.sh "${1:-./build}"
PATH="$work" /bin/dash tests/pkginfo-database-locks.sh "${1:-./build}/pkginfo"
PATH="$work" /bin/dash tests/pkginfo-query-reference-parity.sh "${1:-./build}/pkginfo"
