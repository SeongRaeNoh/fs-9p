/* check.h - minimal checks: one "ok N" or "not ok N" line per check and a summary line.
 * A test's exit status is 0 if every check passed, 1 otherwise. */
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
