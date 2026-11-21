/*
 * virtq.h - one split virtqueue with several requests in flight.
 *
 * Each request uses a "slot": a fixed pair of descriptors (request buffer, device-readable;
 * response buffer, device-writable) and its own DMA buffers. The slot index is also the 9P tag.
 * Completions are collected by an interrupt thread (InterruptAttachEvent with SIGEV_INTR, then
 * InterruptWait) or, in polling mode, by the waiting thread itself.
 *
 * Priority following (default with the interrupt thread): a thread-pool thread runs at the priority
 * of the client it serves (QNX message passing), and then waits for the interrupt thread. Before a
 * request goes to the device, the interrupt thread is set to the highest priority among the
 * requests in flight and the threads that wait for a free slot, above or below its base priority
 * (-i). When no request is left, a thread above the base goes back to the base; a thread below the
 * base stays until the next request.
 *
 * Priority inheritance through the slots (default, VQ_FOLLOW_SLOTS): the thread that owns a slot
 * holds the slot's mutex (protocol PTHREAD_PRIO_INHERIT) from vq_get() to vq_put(). A thread that
 * finds no free slot blocks on the mutex of an owned slot, so the kernel raises that slot's owner to
 * the waiter's priority until it unlocks the mutex (System Architecture guide, "Mutexes: mutual
 * exclusion locks"). vq_put() then hands the slot to the highest-priority thread blocked on its mutex
 * (pthread_mutex_unlock(): that thread "becomes the next owner of the mutex"). So a client waits for
 * no thread that runs below its own priority, neither for the interrupt thread nor for the owner of
 * the slot it needs; work done for a low-priority client runs above that client's priority only
 * while a higher-priority client waits for its slot.
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 * Ring layout: OASIS virtio specification 1.2, section 2.7.
 */
#ifndef VIRTQ_H
#define VIRTQ_H

#include <stdint.h>
#include <pthread.h>
#include "virtio_pci.h"

#define VQ_MAX_SLOTS 64

/* VQS_HANDOFF: the owner gave the slot back while threads were blocked on its mutex; the thread
 * that gets the mutex next owns the slot. VQS_LOST: the owner stopped waiting (timeout); the slot is
 * free again only after the device has completed it and the owner has called vq_put(). */
enum vq_slot_state { VQS_FREE, VQS_OWNED, VQS_INFLIGHT, VQS_DONE, VQS_LOST, VQS_HANDOFF };

struct vq_slot {
    uint16_t index;             /* slot number = 9P tag */
    uint8_t *req, *rsp;         /* request / response buffers, bufsize bytes each */
    uint64_t req_bus, rsp_bus;
    uint32_t rsp_len;           /* bytes written by the device */
    enum vq_slot_state state;
    pthread_cond_t cv;
    pthread_mutex_t own;        /* held by the slot's owner (VQ_FOLLOW_SLOTS); priority inheritance */
    unsigned nwait;             /* threads blocked (or about to block) on own */
    int owner_prio;             /* priority of the owner when it took the slot */
    uint8_t lost_completed;     /* VQS_LOST: the device has completed the request */
    uint8_t lost_released;      /* VQS_LOST: the owner has called vq_put() */
    uint64_t t_submit_ns;       /* submit time; the waiter's 30 s limit counts from here */
    int prio;                   /* priority of the waiting thread (= its client's), 0 = not known */
};

#define VQ_FOLLOW_IRQ   1       /* the interrupt thread runs at the highest waiting priority */
#define VQ_FOLLOW_SLOTS 2       /* priority inheritance through the slots (see above) */

struct virtq {
    struct vtp_dev *dev;
    uint16_t qsz;
    uint16_t last_used;
    volatile struct vring_desc { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; } *desc;
    volatile uint16_t *avail;   /* flags, idx, ring[] */
    volatile uint8_t *used;     /* flags(2) idx(2) ring[]{id u32, len u32} */
    void *ring_mem; size_t ring_len;
    uint32_t bufsize;
    unsigned nslots;
    struct vq_slot slots[VQ_MAX_SLOTS];
    void *buf_mem[VQ_MAX_SLOTS];
    pthread_mutex_t lk;
    pthread_cond_t free_cv;
    int use_irq;
    int irq_prio;               /* base priority of the interrupt thread (-i); 0 = inherited */
    int irq_follow;             /* 1: raise the interrupt thread to the highest waiting priority */
    int slot_pi;                /* 1: priority inheritance through the slots (VQ_FOLLOW_SLOTS) */
    int irq_cur;                /* priority the interrupt thread has now */
    unsigned nwaiters;          /* threads that wait for a free slot (slot_pi) */
    uint16_t nwait_at[256];     /* the same, by priority */
    pthread_t irq_tid;
    int intr_id;
    volatile int irq_ready;     /* 1 attached, -1 failed */
    /* statistics */
    unsigned long n_irq, n_irq_ours, n_irq_late, n_reaped, n_reaped_by_waiter, n_lost;   /* n_irq_late: completions found by the ISR read after the unmask */
    unsigned inflight, max_inflight;
    unsigned long n_prio_raise, n_prio_fail;    /* raises of the interrupt thread; failed priority changes */
    unsigned long n_prio_below;                 /* changes to a priority below the base */
    int max_client_prio, max_irq_prio;          /* highest waiting priority seen; highest priority set */
    int min_irq_prio;                           /* lowest priority set */
    int prio_errno;                             /* errno of the last failed priority change */
    unsigned long n_slot_wait;                  /* vq_get() calls that found no free slot */
    unsigned long n_slot_wait_above;            /* ... by a thread above the priority of every slot owner */
    unsigned long n_handoff;                    /* slots handed by vq_put() to a thread blocked on the mutex */
    int max_slot_wait_prio;                     /* highest priority of a thread that waited for a slot */
};

/* Set up queue 0 of an initialised device (vtp_init done) and set DRIVER_OK.
 * use_irq: 1 = interrupt thread, 0 = polling. irq_prio: base priority of the interrupt thread
 * (SCHED_FIFO), or 0 to inherit the caller's priority. follow: VQ_FOLLOW_IRQ = set the interrupt
 * thread to the highest priority among the waiting threads, also below irq_prio (else it stays at
 * irq_prio); VQ_FOLLOW_SLOTS = priority inheritance through the slots (see above); 0 = neither.
 * Returns 0 or -1. */
int vq_init(struct virtq *q, struct vtp_dev *d, unsigned nslots, uint32_t bufsize, int use_irq, int irq_prio, int follow);

/* vq_get() blocks until the caller owns a slot; the same thread must call vq_put() for it (with
 * VQ_FOLLOW_SLOTS the owner holds the slot's mutex). */
struct vq_slot *vq_get(struct virtq *q);
void vq_put(struct virtq *q, struct vq_slot *s);

/* Submit req[0..reqlen) of slot s and wait for the response. Returns the number of bytes the
 * device wrote into s->rsp, or -1 after timeout_ms (the slot is then kept until the device
 * completes it; the caller must still call vq_put()). */
int vq_submit_wait(struct virtq *q, struct vq_slot *s, uint32_t reqlen, int timeout_ms);

uint64_t vq_now_ns(void);

/* Slots by state, for the statistics at unmount: free; in use (owned, in flight, completed or
 * being handed over); lost (the wait timed out and the device has not completed the request yet).
 * Also the number of requests in flight. */
void vq_slot_counts(struct virtq *q, unsigned *nfree, unsigned *nbusy, unsigned *nlost, unsigned *ninflight);

#endif
