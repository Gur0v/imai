/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _XOPEN_SOURCE 700
#include <archive.h>
#include <archive_entry.h>
#include <bzlib.h>
#include <errno.h>
#include <grp.h>
#include <inttypes.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zlib.h>

#include "archive.h"

struct target {
	const char *path;
	mode_t mode;
	size_t order;
};

static int
error(const char *command, const char *filename, const char *message)
{
	fprintf(stderr, "%s: %s: %s\n", command, filename, message);
	return 1;
}

void
package_archive_free(struct package_archive *contents)
{
	for (size_t i = 0; i < contents->count; ++i)
		archive_entry_free(contents->entries[i]);
	free(contents->entries);
	if (contents->stream)
		fclose(contents->stream);
	*contents = (struct package_archive){0};
}

/*
 * libarchive's gzip filter omits CRC/ISIZE checks; zlib verifies each member.
 * Ignore non-member trailing bytes for compatibility with pkgutils.
 */
static int
gzip_read(FILE *input, FILE *output)
{
	unsigned char in[32768], out[32768];
	z_stream stream = {0};
	int result = 1, status;
	bool member = false;

	if (inflateInit2(&stream, 15 + 16) != Z_OK)
		return 1;
	for (;;) {
		if (stream.avail_in < 2) {
			size_t left = stream.avail_in;
			if (left)
				memmove(in, stream.next_in, left);
			size_t got = feof(input)
			                 ? 0
			                 : fread(in + left, 1,
			                       sizeof(in) - left, input);
			if (ferror(input))
				break;
			stream.next_in = in;
			stream.avail_in = (uInt)(left + got);
		}
		if (member) {
			if (stream.avail_in < 2 || stream.next_in[0] != 0x1f ||
			    stream.next_in[1] != 0x8b) {
				result = 0;
				break;
			}
			if (inflateReset(&stream) != Z_OK)
				break;
			member = false;
		}
		stream.next_out = out;
		stream.avail_out = sizeof(out);
		status = inflate(&stream, Z_NO_FLUSH);
		size_t size = sizeof(out) - stream.avail_out;
		if (fwrite(out, 1, size, output) != size)
			break;
		if (status == Z_STREAM_END)
			member = true;
		else if (status != Z_OK)
			break;
	}
	inflateEnd(&stream);
	return result;
}

/* libarchive accepts an incomplete final concatenated bzip2 member. Decode
 * each recognized member explicitly so its end marker and CRC are checked. */
static int
bzip2_read(FILE *input, FILE *output)
{
	char in[32768], out[32768];
	bz_stream stream = {0};
	int result = 1;
	bool member = false;

	if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK)
		return 1;
	for (;;) {
		if (stream.avail_in < 4) {
			size_t left = stream.avail_in;
			if (left)
				memmove(in, stream.next_in, left);
			size_t got = feof(input)
			                 ? 0
			                 : fread(in + left, 1,
			                       sizeof(in) - left, input);
			if (ferror(input))
				break;
			stream.next_in = in;
			stream.avail_in = (unsigned int)(left + got);
		}
		if (member) {
			if (stream.avail_in < 3 ||
			    memcmp(stream.next_in, "BZh", 3)) {
				result = 0;
				break;
			}
			char *next = stream.next_in;
			unsigned int left = stream.avail_in;
			BZ2_bzDecompressEnd(&stream);
			stream = (bz_stream){0};
			if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK)
				return 1;
			stream.next_in = next;
			stream.avail_in = left;
			member = false;
		}
		stream.next_out = out;
		stream.avail_out = sizeof(out);
		unsigned int before = stream.avail_in;
		int status = BZ2_bzDecompress(&stream);
		size_t size = sizeof(out) - stream.avail_out;
		if (fwrite(out, 1, size, output) != size)
			break;
		if (status == BZ_STREAM_END)
			member = true;
		else if (status != BZ_OK ||
		         (before == stream.avail_in && !size))
			break;
	}
	BZ2_bzDecompressEnd(&stream);
	return result;
}

static int
stream_filter(FILE *input)
{
	struct archive *a = archive_read_new();
	int filter = -1;
	if (!a)
		return -1;
	/* WARN permits external decoders; accept only native registration. */
	if (archive_read_support_filter_gzip(a) == ARCHIVE_OK &&
	    archive_read_support_filter_bzip2(a) == ARCHIVE_OK &&
	    archive_read_support_filter_xz(a) == ARCHIVE_OK &&
	    archive_read_support_filter_lzip(a) == ARCHIVE_OK &&
	    archive_read_support_filter_zstd(a) == ARCHIVE_OK &&
	    archive_read_support_format_raw(a) == ARCHIVE_OK &&
	    archive_read_open_FILE(a, input) == ARCHIVE_OK) {
		int count = archive_filter_count(a);
		filter = archive_filter_code(a, count > 1 ? count - 2 : 0);
	}
	archive_read_free(a);
	if (fseeko(input, 0, SEEK_SET) < 0)
		return -1;
	return filter;
}

/*
 * Decode beyond tar EOF to validate compression trailers. Anonymous streams
 * ensure tar parsing reads the validated bytes without reopening the path.
 */
static FILE *
package_stream(const char *filename, const char *command)
{
	/* Match libarchive's EILSEQ for an empty pathname. */
	FILE *input = *filename ? fopen(filename, "rb") : NULL;
	if (!input) {
		int saved = *filename ? errno : EILSEQ;
		fprintf(stderr, "%s: could not open %s: %s\n", command,
		    filename, strerror(saved));
		return NULL;
	}
	FILE *captured = tmpfile();
	if (!captured)
		goto io_error;
	char buffer[32768];
	size_t got;
	while (!feof(input) && !ferror(input) &&
	       (got = fread(buffer, 1, sizeof(buffer), input)) != 0) {
		if (fwrite(buffer, 1, got, captured) != got) {
			fclose(captured);
			goto io_error;
		}
	}
	int failed = ferror(input);
	if (fclose(input) != 0)
		failed = 1;
	input = captured;
	if (failed || fflush(input) != 0 || fseeko(input, 0, SEEK_SET) < 0)
		goto io_error;
	for (;;) {
		int filter = stream_filter(input);
		if (filter < 0) {
			error(command, filename,
			    "could not identify native compression stream");
			fclose(input);
			return NULL;
		}
		if (filter == ARCHIVE_FILTER_NONE)
			return input;
		FILE *output = tmpfile();
		if (!output)
			goto io_error;
		int failed = 1;
		if (filter == ARCHIVE_FILTER_GZIP) {
			failed = gzip_read(input, output);
		} else if (filter == ARCHIVE_FILTER_BZIP2) {
			failed = bzip2_read(input, output);
		} else {
			struct archive *a = archive_read_new();
			struct archive_entry *entry;
			if (a &&
			    archive_read_support_format_raw(a) == ARCHIVE_OK &&
			    archive_read_append_filter(a, filter) ==
			        ARCHIVE_OK &&
			    archive_read_open_FILE(a, input) == ARCHIVE_OK &&
			    archive_read_next_header(a, &entry) ==
			        ARCHIVE_OK) {
				char buffer[32768];
				la_ssize_t got;
				while ((got = archive_read_data(
				            a, buffer, sizeof(buffer))) > 0)
					if (fwrite(buffer, 1, (size_t)got,
					        output) != (size_t)got)
						break;
				failed = got != 0;
				if (archive_read_close(a) != ARCHIVE_OK)
					failed = 1;
			}
			if (a)
				archive_read_free(a);
		}
		if (fclose(input) != 0)
			failed = 1;
		input = output;
		if (failed) {
			error(command, filename,
			    "invalid compressed stream or "
			    "temporary I/O failure");
			fclose(input);
			return NULL;
		}
		if (fflush(input) != 0 || fseeko(input, 0, SEEK_SET) < 0)
			goto io_error;
	}
io_error:
	error(command, filename, strerror(errno));
	fclose(input);
	return NULL;
}

int
package_archive_open(const char *filename, struct package_archive *contents)
{
	return package_archive_open_command(filename, contents, "pkginfo");
}

int
package_archive_open_command(const char *filename,
    struct package_archive *contents, const char *command)
{
	struct archive *a = archive_read_new();
	struct archive_entry *entry;
	size_t capacity = 0;
	int status, result = 1;

	if (!a)
		return error(command, filename, "out of memory");
	FILE *input = package_stream(filename, command);
	if (!input) {
		archive_read_free(a);
		return 1;
	}
	/* Compression was fully validated above; do not auto-decode here. */
	if (archive_read_support_format_tar(a) != ARCHIVE_OK) {
		error(command, filename,
		    "required native archive support unavailable");
		goto out;
	}
	if (archive_read_open_FILE(a, input) != ARCHIVE_OK)
		goto archive_error;
	while ((status = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
		if (!archive_entry_pathname(entry)) {
			error(command, filename,
			    "archive entry has no pathname");
			goto out;
		}
		if (contents->count == capacity) {
			size_t next = capacity ? capacity * 2 : 32;
			if (next < capacity ||
			    next > SIZE_MAX / sizeof(*contents->entries)) {
				error(command, filename,
				    "archive inventory too large");
				goto out;
			}
			void *p = realloc(contents->entries,
			    next * sizeof(*contents->entries));
			if (!p) {
				error(command, filename, "out of memory");
				goto out;
			}
			contents->entries = p;
			capacity = next;
		}
		struct archive_entry *copy = archive_entry_clone(entry);
		if (!copy) {
			error(command, filename, "out of memory");
			goto out;
		}
		contents->entries[contents->count++] = copy;
		/* Skipping can seek past truncated payloads without detecting
		 * them. */
		const void *buffer;
		size_t size;
		la_int64_t offset;
		while ((status = archive_read_data_block(
		            a, &buffer, &size, &offset)) == ARCHIVE_OK)
			;
		if (status != ARCHIVE_EOF)
			goto archive_error;
	}
	if (status != ARCHIVE_EOF)
		goto archive_error;
	if (!contents->count) {
		error(command, filename, "empty package");
		goto out;
	}
	if (archive_read_close(a) != ARCHIVE_OK)
		goto archive_error;
	result = 0;
	goto out;
archive_error:
	error(command, filename,
	    archive_error_string(a) ? archive_error_string(a)
	                            : "could not read archive");
out:
	archive_read_free(a);
	if (!result) {
		if (fseeko(input, 0, SEEK_SET) != 0)
			result = error(command, filename,
			    "could not rewind package stream");
		else
			contents->stream = input;
	}
	if (result) {
		fclose(input);
		package_archive_free(contents);
	}
	return result;
}

static int
path_compare(const void *left, const void *right)
{
	struct archive_entry *const *a = left, *const *b = right;
	return strcmp(archive_entry_pathname(*a), archive_entry_pathname(*b));
}

static int
target_compare(const void *left, const void *right)
{
	const struct target *a = left, *b = right;
	int result = strcmp(a->path, b->path);
	return result ? result : (a->order > b->order) - (a->order < b->order);
}

static int
valid_name(const char *filename)
{
	const char *base = strrchr(filename, '/');
	base = base ? base + 1 : filename;
	const char *delimiter = strchr(base, '#');
	const char *extension = NULL, *p = base;
	while ((p = strstr(p, ".pkg.tar."))) {
		extension = p;
		++p;
	}
	const char *end = extension ? extension : base + strlen(base);
	if (!delimiter || delimiter == base || delimiter >= end ||
	    delimiter + 1 == end) {
		fprintf(stderr,
		    "pkginfo: could not determine name and/or "
		    "version of %s: Invalid package name\n",
		    base);
		return 0;
	}
	return 1;
}

int
package_list(const char *filename)
{
	struct package_archive contents = {0};
	int result = 1;

	if (!valid_name(filename) || package_archive_open(filename, &contents))
		goto out;
	qsort(contents.entries, contents.count, sizeof(*contents.entries),
	    path_compare);
	const char *previous = NULL;
	for (size_t i = 0; i < contents.count; ++i) {
		const char *path = archive_entry_pathname(contents.entries[i]);
		if (!previous || strcmp(previous, path))
			puts(path);
		previous = path;
	}
	result = (fflush(stdout) || ferror(stdout))
	             ? error("pkginfo", filename, "could not write output")
	             : 0;
out:
	package_archive_free(&contents);
	return result;
}

static void
mode_string(mode_t mode, char text[11])
{
	const mode_t types[] = {
	    S_IFREG, S_IFDIR, S_IFLNK, S_IFCHR, S_IFBLK, S_IFSOCK, S_IFIFO};
	const char letters[] = "-dlcbsp";
	text[0] = '?';
	for (size_t i = 0; i < sizeof(types) / sizeof(*types); ++i)
		if ((mode & S_IFMT) == types[i])
			text[0] = letters[i];
	for (int i = 0; i < 9; ++i)
		text[i + 1] = (mode & (0400 >> i)) ? "rwx"[i % 3] : '-';
	if (mode & S_ISUID)
		text[3] = (mode & S_IXUSR) ? 's' : 'S';
	if (mode & S_ISGID)
		text[6] = (mode & S_IXGRP) ? 's' : 'S';
	if (mode & S_ISVTX)
		text[9] = (mode & S_IXOTH) ? 't' : 'T';
	text[10] = '\0';
}

int
package_footprint(const char *filename)
{
	struct package_archive contents = {0};
	int result = 1;

	if (package_archive_open(filename, &contents))
		goto out;
	/* Duplicate hardlink targets use the last header's mode. */
	if (contents.count > SIZE_MAX / sizeof(struct target)) {
		error("pkginfo", filename, "archive inventory too large");
		goto out;
	}
	struct target *targets = malloc(contents.count * sizeof(*targets));
	if (!targets) {
		error("pkginfo", filename, "out of memory");
		goto out;
	}
	size_t count = 0;
	for (size_t i = 0; i < contents.count; ++i) {
		struct archive_entry *entry = contents.entries[i];
		if (!archive_entry_hardlink(entry))
			targets[count++] =
			    (struct target){archive_entry_pathname(entry),
			        archive_entry_mode(entry), i};
	}
	qsort(targets, count, sizeof(*targets), target_compare);
	for (size_t i = 0; i < contents.count; ++i) {
		struct archive_entry *entry = contents.entries[i];
		mode_t mode = archive_entry_mode(entry), printed_mode = mode;
		const char *link = archive_entry_hardlink(entry);
		char text[11];
		if (link) {
			printed_mode = 0;
			size_t low = 0, high = count;
			while (low < high) {
				size_t middle = low + (high - low) / 2;
				if (strcmp(targets[middle].path, link) <= 0)
					low = middle + 1;
				else
					high = middle;
			}
			if (low && !strcmp(targets[low - 1].path, link))
				printed_mode = targets[low - 1].mode;
		}
		mode_string(printed_mode, text);
		printf("%s\t", S_ISLNK(mode) ? "lrwxrwxrwx" : text);
		uid_t uid = (uid_t)archive_entry_uid(entry);
		gid_t gid = (gid_t)archive_entry_gid(entry);
		struct passwd *pw = getpwuid(uid);
		if (pw)
			printf("%s", pw->pw_name);
		else
			printf("%ju", (uintmax_t)uid);
		putchar('/');
		struct group *gr = getgrgid(gid);
		if (gr)
			printf("%s", gr->gr_name);
		else
			printf("%ju", (uintmax_t)gid);
		printf("\t%s", archive_entry_pathname(entry));
		if (S_ISLNK(mode))
			printf(" -> %s", archive_entry_symlink(entry));
		else if (S_ISCHR(mode) || S_ISBLK(mode))
			printf(" (%jd, %jd)",
			    (intmax_t)archive_entry_rdevmajor(entry),
			    (intmax_t)archive_entry_rdevminor(entry));
		else if (S_ISREG(mode) && archive_entry_size(entry) == 0)
			printf(" (EMPTY)");
		putchar('\n');
	}
	free(targets);
	result = (fflush(stdout) || ferror(stdout))
	             ? error("pkginfo", filename, "could not write output")
	             : 0;
out:
	package_archive_free(&contents);
	return result;
}
