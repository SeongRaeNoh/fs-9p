/*
 * tests/host/fake_virtq.h - a stand-in for src/virtq.h, so that src/p9.c builds and runs on a Linux
 * host with the host C compiler, without the QNX SDP (src/virtq.h includes src/virtio_pci.h, which
 * needs the QNX PCI headers). Include this file before src/p9.c: it defines the include guards of
 * src/virtq.h and src/virtio_pci.h, so that p9.h does not include them, and declares the three
 * virtqueue calls that p9.c makes.
 *
 * The fake device answers each request with the next reply from a queue that the test fills. For
 * each answer it allocates a reply buffer of exactly the reply's length, so that AddressSanitizer
 * reports any read past the end of the bytes that the "device" wrote. The request buffer is
 * bufsize bytes, as in src/virtq.c.
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#ifndef FAKE_VIRTQ_H
#define FAKE_VIRTQ_H

#define VIRTQ_H         /* src/virtq.h is not used on the host */
#define VIRTIO_PCI_H    /* nor src/virtio_pci.h */

#include <stdint.h>
#include <stddef.h>

struct vq_slot {
    uint16_t index;         /* slot number = 9P tag */
    uint8_t *req, *rsp;     /* request buffer (bufsize bytes); reply buffer (reply length) */
};

struct virtq {
    uint32_t bufsize;
    struct vq_slot slot;
};

struct vq_slot *vq_get(struct virtq *q);
void vq_put(struct virtq *q, struct vq_slot *s);
int vq_submit_wait(struct virtq *q, struct vq_slot *s, uint32_t reqlen, int timeout_ms);

/* the fake device */
#define FAKE_QUEUE 8
#define FAKE_TIMEOUT ((size_t)-1)   /* as a reply length: the device does not answer */

void fake_init(struct virtq *q, uint32_t bufsize);
void fake_free(struct virtq *q);
/* queue a reply (copied); n = FAKE_TIMEOUT queues "no answer" */
void fake_reply(const uint8_t *b, size_t n);
void fake_clear(void);
/* requests seen since fake_clear(): number, and a copy of the last one */
extern unsigned fake_nreq;
extern uint8_t fake_last_req[65536];
extern uint32_t fake_last_req_len;

#endif
