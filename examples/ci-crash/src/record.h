/* examples/ci-crash/src/record.h - parse "name=value" lines (example code with a deliberate bug).
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#ifndef RECORD_H
#define RECORD_H
struct record { char name[32]; int value; };
/* Parse "name=value" (value: decimal digits). The bug: a line without '=' is not rejected. */
int parse_record(const char *line, struct record *r);
#endif
