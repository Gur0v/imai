#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
binary=${1:-$root/build/rejmerge}
# Python supplies a real controlling terminal; all file changes stay in tmpfs.
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --ro-bind "$harness/terminal-signal-regressions.py" /tmp/test-harness.py --chdir /tmp \
    --ro-bind "$binary" /tmp/rejmerge \
    -- python3 -I "/tmp/test-harness.py"
