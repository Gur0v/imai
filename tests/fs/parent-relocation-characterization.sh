#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Demonstrate why scoped parent lookup alone cannot confine later unlinkat.
# All namespace mutations occur in disposable bubblewrap tmpfs.
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
${CC:-cc} -std=c23 -O2 -Wall -Wextra -Werror \
    "$harness/parent-relocation-characterization.c" -o "$work/relocation"
bwrap --unshare-all --die-with-parent --ro-bind / / --tmpfs /tmp \
    --ro-bind "$work/relocation" /tmp/relocation -- /bin/dash -eu -c '
mkdir -p /tmp/root/writable/parent /tmp/outside
printf "victim\n" >/tmp/root/writable/parent/victim
printf "sentinel\n" >/tmp/outside/sentinel
/tmp/relocation
[ -d /tmp/outside/moved/parent ]
[ ! -e /tmp/outside/moved/parent/victim ]
[ ! -e /tmp/root/writable ]
printf "sentinel\n" >/tmp/expected
cmp /tmp/expected /tmp/outside/sentinel
'
printf 'PASS: reproduced post-lookup parent relocation outside selected root\n'
