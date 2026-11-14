#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/openat2.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int
main(void)
{
	int root = open("/tmp/root", O_PATH | O_DIRECTORY | O_CLOEXEC);
	if (root < 0)
		return 1;
	struct open_how how = {
		.flags = O_PATH | O_DIRECTORY | O_CLOEXEC,
		.resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
	};
	int parent = syscall(SYS_openat2, root, "writable/parent", &how,
	    sizeof(how));
	if (parent < 0) {
		perror("required openat2 protections unavailable");
		return 1;
	}
	/* Deterministic adversarial schedule: relocation after scoped lookup. */
	if (rename("/tmp/root/writable", "/tmp/outside/moved") < 0 ||
	    unlinkat(parent, "victim", 0) < 0)
		return 1;
	if (close(parent) < 0 || close(root) < 0)
		return 1;
	return 0;
}
