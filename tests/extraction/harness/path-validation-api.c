#include <archive_entry.h>
#include <errno.h>
#include <string.h>
#include "archive/archive.h"
#include "extraction/install.h"

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
