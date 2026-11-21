/* test_ring.c - an ordinary unit test (a fixed-size ring buffer); it needs no QNX feature and shows
 * that plain C tests run in the guest the same way.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <string.h>
#include "check.h"

#define RING_N 8
struct ring { int v[RING_N]; unsigned head, tail; };
static int ring_put(struct ring *r, int x) { if (r->head - r->tail == RING_N) return -1; r->v[r->head++ % RING_N] = x; return 0; }
static int ring_get(struct ring *r, int *x) { if (r->head == r->tail) return -1; *x = r->v[r->tail++ % RING_N]; return 0; }

int main(void)
{
    struct ring r; memset(&r, 0, sizeof r);
    int x = 0, ok = 1;
    CHECK(ring_get(&r, &x) == -1, "empty ring: get fails");
    for (int i = 0; i < RING_N; i++) ok &= ring_put(&r, i) == 0;
    CHECK(ok, "%d puts into an empty ring succeed", RING_N);
    CHECK(ring_put(&r, 99) == -1, "put into a full ring fails");
    ok = 1;
    for (int i = 0; i < RING_N; i++) ok &= ring_get(&r, &x) == 0 && x == i;
    CHECK(ok, "gets return the values in order");
    ok = 1;
    for (int i = 0; i < 3 * RING_N; i++) ok &= ring_put(&r, i) == 0 && ring_get(&r, &x) == 0 && x == i;
    CHECK(ok, "the indexes wrap around correctly");
    return CHECK_DONE();
}
