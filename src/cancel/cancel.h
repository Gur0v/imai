/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IMAI_CANCEL_H
#define IMAI_CANCEL_H

int cancel_begin(void);
/* Restore exec inheritance in a forked child without reporting parent
 * requests. */
int cancel_child(void);
int cancel_end(const char *command);

#endif
