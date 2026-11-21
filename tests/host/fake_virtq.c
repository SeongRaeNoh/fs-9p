/*
 * tests/host/fake_virtq.c - the fake device of fake_virtq.h (host tests only).
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fake_virtq.h"

static struct { uint8_t *b; size_t n; } queue[FAKE_QUEUE];
static unsigned q_head, q_len;
unsigned fake_nreq;
uint8_t fake_last_req[65536];
uint32_t fake_last_req_len;

void fake_init(struct virtq *q, uint32_t bufsize)
{
    memset(q, 0, sizeof *q);
    q->bufsize = bufsize;
    q->slot.index = 0;
    q->slot.req = malloc(bufsize);
    q->slot.rsp = NULL;
    if (!q->slot.req) { perror("malloc"); exit(2); }
}

void fake_free(struct virtq *q)
{
    free(q->slot.req); free(q->slot.rsp);
    q->slot.req = q->slot.rsp = NULL;
    fake_clear();
}

void fake_clear(void)
{
    for (unsigned i = 0; i < q_len; i++) free(queue[(q_head + i) % FAKE_QUEUE].b);
    q_head = q_len = 0;
    fake_nreq = 0;
    fake_last_req_len = 0;
}

void fake_reply(const uint8_t *b, size_t n)
{
    if (q_len == FAKE_QUEUE) { fprintf(stderr, "fake_reply: queue full\n"); exit(2); }
    unsigned k = (q_head + q_len) % FAKE_QUEUE;
    queue[k].n = n;
    queue[k].b = NULL;
    if (n != FAKE_TIMEOUT) {
        queue[k].b = malloc(n ? n : 1);
        if (!queue[k].b) { perror("malloc"); exit(2); }
        if (n) memcpy(queue[k].b, b, n);
    }
    q_len++;
}

struct vq_slot *vq_get(struct virtq *q) { return &q->slot; }

void vq_put(struct virtq *q, struct vq_slot *s) { (void)q; (void)s; }

int vq_submit_wait(struct virtq *q, struct vq_slot *s, uint32_t reqlen, int timeout_ms)
{
    (void)timeout_ms;
    if (reqlen > q->bufsize) { fprintf(stderr, "vq_submit_wait: request of %u bytes > bufsize %u\n", reqlen, q->bufsize); abort(); }
    fake_nreq++;
    fake_last_req_len = reqlen < sizeof fake_last_req ? reqlen : sizeof fake_last_req;
    memcpy(fake_last_req, s->req, fake_last_req_len);
    if (q_len == 0) return -1;                  /* nothing queued: no answer */
    unsigned k = q_head; q_head = (q_head + 1) % FAKE_QUEUE; q_len--;
    free(s->rsp); s->rsp = NULL;
    if (queue[k].n == FAKE_TIMEOUT) return -1;
    /* the reply buffer holds exactly the bytes the device wrote */
    s->rsp = queue[k].b;
    if (queue[k].n > q->bufsize) { fprintf(stderr, "vq_submit_wait: reply longer than bufsize\n"); abort(); }
    return (int)queue[k].n;
}
