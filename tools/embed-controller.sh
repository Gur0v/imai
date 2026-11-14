#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
[ "$#" = 1 ] || [ "$#" = 2 ] || exit 1
[ -f "$1" ] && [ -r "$1" ] || exit 1
symbol=${2:-pkgmk_controller}
case $symbol in pkgmk_controller|rejmerge_controller) ;; *) exit 1 ;; esac
LC_ALL=C od -An -v -tu1 "$1" | awk -v symbol="$symbol" '
BEGIN { print "/* Generated compatibility controller; do not edit. */"; print "static const char " symbol "[] = {" }
{ for (i = 1; i <= NF; i++) printf "%s,", $i; print "" }
END { print "0\n};" }
'
