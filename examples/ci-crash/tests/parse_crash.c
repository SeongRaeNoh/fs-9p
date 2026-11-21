/* examples/ci-crash/tests/parse_crash.c - crashes on purpose: the line has no '=', and
 * parse_record() passes the null result of strchr() on (SIGSEGV in read_value()).
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <stdio.h>
#include "../src/record.h"

int main(void)
{
    struct record r;
    printf("parsing \"speed 42\"\n");
    fflush(stdout);
    parse_record("speed 42", &r);
    printf("name %s, value %d\n", r.name, r.value);
    return 0;
}
