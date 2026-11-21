/* examples/ci-crash/src/record.c - parse "name=value" lines (example code with a deliberate bug).
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <string.h>
#include "record.h"

static int read_value(const char *eq)
{
    int v = 0;
    for (const char *p = eq + 1; *p >= '0' && *p <= '9'; p++)   /* eq == NULL: reads address 1 */
        v = 10 * v + (*p - '0');
    return v;
}

int parse_record(const char *line, struct record *r)
{
    const char *eq = strchr(line, '=');          /* NULL for a line without '=' (not checked) */
    size_t n = eq ? (size_t)(eq - line) : strlen(line);
    if (n >= sizeof r->name) n = sizeof r->name - 1;
    memcpy(r->name, line, n);
    r->name[n] = 0;
    r->value = read_value(eq);
    return 0;
}
