/* examples/ci-crash/tests/parse_ok.c - passes: "speed=42" gives name "speed" and value 42.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <stdio.h>
#include <string.h>
#include "../src/record.h"

int main(void)
{
    struct record r;
    parse_record("speed=42", &r);
    printf("name %s, value %d\n", r.name, r.value);
    return strcmp(r.name, "speed") == 0 && r.value == 42 ? 0 : 1;
}
