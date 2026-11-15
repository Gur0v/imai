/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "../../../src/commands/pkgmk/pkgmk-workflow.c"

static int attempts;
static const char *scenario;
int __real_umount2(const char *, int);
int __real_statx(int, const char *, int, unsigned int, struct statx *);

int
__wrap_umount2(const char *path, int flags)
{
	if (flags != 0)
		abort();
	attempts++;
	if (!strcmp(scenario, "transient") && attempts > 1)
		return __real_umount2(path, flags);
	errno = !strcmp(scenario, "denied") ? EPERM : EBUSY;
	return -1;
}

int
__wrap_statx(
    int fd, const char *path, int flags, unsigned int mask, struct statx *st)
{
	int result = __real_statx(fd, path, flags, mask, st);
	if (result == 0 && attempts && !strcmp(scenario, "identity"))
		st->stx_mnt_id++;
	return result;
}

int
main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	scenario = argv[1];
	if (work_acquire(scenario, false) < 0)
		return 3;
	struct timespec start, end;
	if (clock_gettime(CLOCK_MONOTONIC, &start) < 0)
		return 4;
	int result = work_release();
	int saved = errno;
	if (clock_gettime(CLOCK_MONOTONIC, &end) < 0)
		return 5;
	double elapsed =
	    end.tv_sec - start.tv_sec + (end.tv_nsec - start.tv_nsec) / 1e9;
	printf("%s result=%d errno=%d attempts=%d seconds=%.3f\n", scenario,
	    result, saved, attempts, elapsed);
	if (!strcmp(scenario, "transient"))
		return result != 0 || attempts != 2 || managed_name != NULL;
	if (result == 0 || !managed_name)
		return 6;
	if (!strcmp(scenario, "busy"))
		return saved != EBUSY || attempts < 2 || elapsed < .9 ||
		       elapsed > 2;
	return attempts != 1 ||
	       saved != (!strcmp(scenario, "identity") ? ESTALE : EPERM);
}
