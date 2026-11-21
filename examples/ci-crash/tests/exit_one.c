/* examples/ci-crash/tests/exit_one.c - fails without a crash: a wrong value gives exit status 1.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <stdio.h>
#include "../src/record.h"

int main(void)
{
    struct record r;
    parse_record("speed=41", &r);
    printf("expected value 42, got %d\n", r.value);
    return r.value == 42 ? 0 : 1;
}
