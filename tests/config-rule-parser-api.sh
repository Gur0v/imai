#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/config.c" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include "config.h"

int
main(int argc, char **argv)
{
	struct config config = {0};
	if (argc != 3)
		return 2;
	if (getenv("CONFIG_FD")) {
		int fd = open(argv[1], O_RDONLY);
		if (fd < 0 || config_read_fd(&config, fd, argv[1]) < 0)
			return 1;
		if (fcntl(fd, F_GETFD) >= 0 || errno != EBADF)
			return 1;
	} else if (config_read(&config, argv[1]) < 0)
		return 1;
	bool action;
	int result = config_action(&config, CONFIG_INSTALL, argv[2], &action);
	if (!result)
		printf("install %s\n", action ? "yes" : "no");
	if (!result) {
		result = config_action(&config, CONFIG_UPGRADE, argv[2], &action);
		if (!result)
			printf("upgrade %s\n", action ? "yes" : "no");
	}
	config_free(&config);
	return result < 0;
}
EOF
set -f
# shellcheck disable=SC2086
${CC:-cc} ${CONFIG_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src "$work/config.c" src/config.c \
    -o "$work/config"
printf 'install yes\nupgrade yes\n' >"$work/default"
"$work/config" "$work/missing" etc/file >"$work/out" 2>"$work/err"
cmp "$work/default" "$work/out"
[ ! -s "$work/err" ]
mkdir "$work/directory"
status=0
"$work/config" "$work/directory" etc/file >"$work/out" 2>"$work/err" || status=$?
[ "$status" -eq 1 ]
grep -F 'could not read configuration' "$work/err" >/dev/null
printf '# comment\nINSTALL [ NO\nINSTALL .* YES\nINSTALL ^etc/ NO\nUPGRADE .* NO\nUPGRADE ^etc/file$ YES\n' >"$work/rules"
"$work/config" "$work/rules" etc/file >"$work/out"
printf 'install no\nupgrade yes\n' >"$work/expected"
cmp "$work/expected" "$work/out"
CONFIG_FD=1 "$work/config" "$work/rules" etc/file >"$work/out"
cmp "$work/expected" "$work/out"
"$work/config" "$work/rules" usr/file >"$work/out"
printf 'install yes\nupgrade no\n' >"$work/expected"
cmp "$work/expected" "$work/out"
for bad in blank comment extra event action regex long; do
    case $bad in
    blank) printf '   \n' >"$work/rules"; message='wrong number of arguments' ;;
    comment) printf ' # comment\n' >"$work/rules"; message='wrong number of arguments' ;;
    extra) printf 'INSTALL .* YES extra\n' >"$work/rules"; message='wrong number of arguments' ;;
    event) printf 'install .* YES\n' >"$work/rules"; message="unknown event" ;;
    action) printf 'INSTALL .* yes\n' >"$work/rules"; message="unknown action" ;;
    regex) printf 'INSTALL [ NO\n' >"$work/rules"; message='error compiling regular expression' ;;
    long) printf '%01024d\n' 0 >"$work/rules"; message='line too long' ;;
    esac
    status=0
    "$work/config" "$work/rules" etc/file >"$work/out" 2>"$work/err" || status=$?
    [ "$status" -eq 1 ]
    grep -F "$message" "$work/err" >/dev/null
done
printf 'PASS: configuration parsing, lazy regexes, and last-match precedence\n'
