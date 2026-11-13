/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <errno.h>
#include <signal.h>
#include <stdio.h>

#include "cancel.h"

static const int signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM};
static struct sigaction previous[sizeof(signals) / sizeof(*signals)];
static volatile sig_atomic_t requested;
static bool active;

static void
record_request(int signal)
{
	requested = signal;
}

int
cancel_begin(void)
{
	if (active) {
		errno = EBUSY;
		return -1;
	}
	struct sigaction action = {
	    .sa_handler = record_request, .sa_flags = SA_RESTART};
	if (sigemptyset(&action.sa_mask) < 0)
		return -1;
	requested = 0;
	for (size_t i = 0; i < sizeof(signals) / sizeof(*signals); i++) {
		if (sigaction(signals[i], &action, &previous[i]) < 0) {
			int saved = errno;
			while (i) {
				i--;
				if (sigaction(signals[i], &previous[i], NULL) <
				    0)
					return -1;
			}
			errno = saved;
			return -1;
		}
	}
	active = true;
	return 0;
}

int
cancel_child(void)
{
	if (!active) {
		errno = EINVAL;
		return -1;
	}
	for (size_t i = 0; i < sizeof(signals) / sizeof(*signals); i++) {
		if (sigaction(signals[i], &previous[i], NULL) < 0)
			return -1;
	}
	active = false;
	return 0;
}

int
cancel_end(const char *command)
{
	if (!active) {
		errno = EINVAL;
		return -1;
	}
	int result = 0, saved = 0;
	for (size_t i = 0; i < sizeof(signals) / sizeof(*signals); i++) {
		if (sigaction(signals[i], &previous[i], NULL) < 0) {
			if (!saved)
				saved = errno;
			result = -1;
		}
	}
	active = false;
	if (requested)
		fprintf(stderr,
		    "%s: termination request deferred until "
		    "operation completion\n",
		    command);
	if (result < 0)
		errno = saved;
	return result;
}
