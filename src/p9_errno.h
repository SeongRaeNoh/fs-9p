/*
 * p9_errno.h - map Linux errno values (carried by 9P2000.L Rlerror) to QNX errno values.
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#ifndef P9_ERRNO_H
#define P9_ERRNO_H

struct p9_errno_entry { int linux_errno; int qnx_errno; const char *name; };

extern const struct p9_errno_entry p9_errno_table[];
extern const unsigned p9_errno_table_len;

/* QNX errno for a Linux errno value; EIO for values not in the table. */
int p9_errno_to_qnx(unsigned linux_errno);

#endif
