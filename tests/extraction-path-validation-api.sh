#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
cat >"$work/paths.c" <<'EOF'
#include <archive_entry.h>
#include <errno.h>
#include <string.h>
#include "archive.h"
#include "install.h"

int
main(void)
{
	struct archive_entry *entries[2] = {
	    archive_entry_new(), archive_entry_new()};
	if (!entries[0] || !entries[1])
		return 1;
	struct package_archive package = {.entries = entries, .count = 2};
	archive_entry_set_pathname(entries[0], "./real//./file");
	archive_entry_set_pathname(entries[1], "alias");
	archive_entry_set_symlink(entries[1], "../../outside");
	if (install_paths_check(&package) < 0)
		return 1;
	archive_entry_set_symlink(entries[1], "/proc/self/mounts");
	if (install_paths_check(&package) < 0)
		return 1;
	archive_entry_set_symlink(entries[1], NULL);
	archive_entry_set_hardlink(entries[1], "./real//./file");
	if (install_paths_check(&package) < 0 ||
	    strcmp(archive_entry_pathname(entries[0]), "./real//./file"))
		return 1;
	const char *unsafe[] = {"", "/etc/passwd", "../file", "a/../file"};
	for (size_t i = 0; i < sizeof(unsafe) / sizeof(*unsafe); i++) {
		archive_entry_set_hardlink(entries[1], unsafe[i]);
		if (install_paths_check(&package) == 0 || errno != EINVAL)
			return 1;
		archive_entry_set_hardlink(entries[1], NULL);
		archive_entry_set_pathname(entries[1], unsafe[i]);
		if (install_paths_check(&package) == 0 || errno != EINVAL)
			return 1;
		archive_entry_set_pathname(entries[1], "alias");
	}
	if (install_metadata_check(&package) < 0)
		return 1;
	archive_entry_set_uid(entries[1], 4294967295LL);
	if (install_metadata_check(&package) == 0 || errno != EOVERFLOW)
		return 1;
	archive_entry_set_uid(entries[1], 4294967296LL);
	if (install_metadata_check(&package) == 0 || errno != EOVERFLOW)
		return 1;
	archive_entry_set_uid(entries[1], 0);
	archive_entry_set_gid(entries[1], 4294967295LL);
	if (install_metadata_check(&package) == 0 || errno != EOVERFLOW)
		return 1;
	archive_entry_set_gid(entries[1], 0);
	if (install_metadata_check(&package) < 0)
		return 1;
	for (size_t i = 0; i < 2; i++)
		archive_entry_free(entries[i]);
	return 0;
}
EOF
set -f
# shellcheck disable=SC2046,SC2086
${CC:-cc} ${INSTALL_TEST_CFLAGS:-} -std=c23 -D_POSIX_C_SOURCE=200809L \
    -Wall -Wextra -Werror -iquote src $(pkg-config --cflags libarchive) \
    "$work/paths.c" src/install.c src/fs.c $(pkg-config --libs libarchive) \
    -o "$work/paths"
"$work/paths"
printf 'PASS: all-header destination and hardlink path checks\n'
