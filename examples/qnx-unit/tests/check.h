/* check.h - minimal checks for the qnx-unit example; prints one "ok N" or "not ok N" line per check
 * (TAP style) and a summary. Exit status of a test: 0 if every check passed, 1 otherwise.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#ifndef CHECK_H
#define CHECK_H
#include <stdio.h>
static int check_count, check_failed;
#define CHECK(cond, ...) do { \
    check_count++; \
    if (cond) printf("ok %d - ", check_count); else { printf("not ok %d - ", check_count); check_failed++; } \
    printf(__VA_ARGS__); printf("\n"); fflush(stdout); \
} while (0)
#define CHECK_DONE() (printf("%d of %d checks passed\n", check_count - check_failed, check_count), check_failed ? 1 : 0)
#endif
