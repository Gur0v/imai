#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/cancel.c" <<'EOF'
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include "cancel.h"

int
main(void)
{
	struct sigaction before, after;
	if (sigaction(SIGTERM, NULL, &before) < 0 || cancel_begin() < 0)
		return 1;
	if (cancel_begin() == 0 || errno != EBUSY)
		return 1;
	if (raise(SIGHUP) != 0 || raise(SIGQUIT) != 0 ||
	    raise(SIGTERM) != 0 || raise(SIGINT) != 0)
		return 1;
	puts("finalized");
	if (cancel_end("pkgrm") < 0 ||
	    sigaction(SIGTERM, NULL, &after) < 0 ||
	    before.sa_handler != after.sa_handler)
		return 1;
	if (cancel_end("pkgrm") == 0 || errno != EINVAL ||
	    cancel_begin() < 0 || cancel_end("pkgrm") < 0)
		return 1;
	return 0;
}
EOF
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -iquote src "$work/cancel.c" src/cancel.c -o "$work/cancel"
"$work/cancel" >"$work/out" 2>"$work/err"
printf 'finalized\n' >"$work/expected"
cmp "$work/expected" "$work/out"
printf 'pkgrm: termination request deferred until operation completion\n' >"$work/expected"
cmp "$work/expected" "$work/err"
printf 'PASS: deferred termination and restored signal disposition\n'
