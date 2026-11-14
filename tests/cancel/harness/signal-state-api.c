#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include "cancel/cancel.h"

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
