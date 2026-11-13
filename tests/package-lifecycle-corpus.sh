#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires Python 3 (tarfile xz support), bubblewrap, and static pkgutils binaries.
set -eu
here=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
exec python3 -I "$here/package-lifecycle-corpus.py" "$@"
