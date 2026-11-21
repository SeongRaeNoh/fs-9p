/*
 * virtq.c - split virtqueue with tagged slots and an interrupt thread (see virtq.h).
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <sched.h>
#include <unistd.h>
#include <sys/neutrino.h>
#include "virtq.h"

#define VRING_DESC_F_NEXT        1
#define VRING_DESC_F_WRITE       2
#define VRING_AVAIL_F_NO_INTERRUPT 1

#define LOG(q, ...) do { if ((q)->dev->log) (q)->dev->log(__VA_ARGS__); } while (0)

uint64_t vq_now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static inline uint16_t used_idx(struct virtq *q) { return *(volatile uint16_t *)(q->used + 2); }

/* Collect all new used-ring entries. Called with q->lk held. */
static void reap_locked(struct virtq *q)
{
    uint16_t ui = used_idx(q);
    __sync_synchronize();
    while (q->last_used != ui) {
        volatile uint32_t *ue = (volatile uint32_t *)(q->used + 4 + 8 * (q->last_used % q->qsz));
        uint32_t id = ue[0], len = ue[1];
        q->last_used++;
        q->n_reaped++;
        unsigned si = id / 2;
        if (si >= q->nslots) { LOG(q, "VQ: used entry with bad descriptor id %u\n", id); continue; }
        struct vq_slot *s = &q->slots[si];
        s->rsp_len = len;
        if (q->inflight) q->inflight--;
        if (s->state == VQS_LOST) {             /* the owner stopped waiting earlier */
            if (s->lost_released) {             /* and has given the slot back: free it now */
                s->lost_released = 0;
                s->state = VQS_FREE;
                pthread_cond_signal(&q->free_cv);
            } else {
                s->lost_completed = 1;          /* vq_put() frees it */
            }
        } else if (s->state == VQS_INFLIGHT) {
            s->state = VQS_DONE;
            pthread_cond_signal(&s->cv);
        }
    }
}

/* Priority following. Set the interrupt thread to prio; called with q->lk held. On failure (EPERM:
 * prio is above the maximum for unprivileged processes and the process lacks the priority ability)
 * the thread keeps its priority and the failure is counted. */
static void irq_set_prio_locked(struct virtq *q, int prio)
{
    if (prio == q->irq_cur) return;
    int rc = pthread_setschedprio(q->irq_tid, prio);
    if (rc != EOK) { q->n_prio_fail++; q->prio_errno = rc; return; }
    if (prio > q->irq_cur) q->n_prio_raise++;
    if (prio < q->irq_prio) q->n_prio_below++;
    q->irq_cur = prio;
    if (prio > q->max_irq_prio) q->max_irq_prio = prio;
    if (prio < q->min_irq_prio) q->min_irq_prio = prio;
}

/* Priority the interrupt thread should have now: the highest priority among the requests in
 * flight and the threads that wait for a free slot (with slot_pi; such a thread waits for a
 * completion of the slot's owner), above or below the base priority; a request whose priority is
 * not known counts as the base. With neither: the base priority if the thread is above it, else
 * its current priority (a stream of requests from a client below the base then needs no change per
 * request). q->lk held. */
static int want_prio_locked(struct virtq *q)
{
    int want = 0;
    for (unsigned i = 0; i < q->nslots; i++)
        if (q->slots[i].state == VQS_INFLIGHT) {
            int p = q->slots[i].prio > 0 ? q->slots[i].prio : q->irq_prio;
            if (p > want) want = p;
        }
    if (q->nwaiters)
        for (int p = 255; p > want; p--)
            if (q->nwait_at[p]) { want = p; break; }
    if (want > 0) return want;
    return q->irq_cur < q->irq_prio ? q->irq_cur : q->irq_prio;
}

static void *irq_main(void *arg)
{
    struct virtq *q = arg;
    vtp_io_priv();
    struct sigevent ev;
    SIGEV_INTR_INIT(&ev);
    int id = InterruptAttachEvent(q->dev->irq, &ev, _NTO_INTR_FLAGS_TRK_MSK);
    if (id == -1) { LOG(q, "FAIL: InterruptAttachEvent(%d): %s\n", q->dev->irq, strerror(errno)); q->irq_ready = -1; return NULL; }
    q->intr_id = id;
    q->irq_ready = 1;
    for (;;) {
        if (InterruptWait(0, NULL) == -1) {
            if (errno == EINTR) continue;
            LOG(q, "FAIL: InterruptWait: %s\n", strerror(errno));
            break;
        }
        q->n_irq++;
        uint8_t isr = vtp_read_isr(q->dev);     /* reading the ISR deasserts INTx */
        if (isr & 1) {
            q->n_irq_ours++;
            pthread_mutex_lock(&q->lk);
            reap_locked(q);
            pthread_mutex_unlock(&q->lk);
        }
        InterruptUnmask(q->dev->irq, id);
        /* A completion that arrives while the interrupt is masked asserts INTx again. If the interrupt
         * controller treats the line as edge-triggered, that edge can be lost and the line stays
         * asserted, so no further interrupt would arrive. Read the ISR once more after the unmask:
         * a set bit means such a completion; the read deasserts the line and the reap handles it. */
        isr = vtp_read_isr(q->dev);
        if (isr & 1) {
            q->n_irq_late++;
            pthread_mutex_lock(&q->lk);
            reap_locked(q);
            pthread_mutex_unlock(&q->lk);
        }
    }
    return NULL;
}

int vq_init(struct virtq *q, struct vtp_dev *d, unsigned nslots, uint32_t bufsize, int use_irq, int irq_prio, int follow)
{
    memset(q, 0, sizeof *q);
    q->dev = d;
    q->intr_id = -1;
    q->qsz = vtp_queue_size(d, 0);
    LOG(q, "VIRTIO: queue 0 size %u\n", q->qsz);
    if (q->qsz == 0) { LOG(q, "FAIL: queue 0 not available\n"); return -1; }
    if (nslots > VQ_MAX_SLOTS) nslots = VQ_MAX_SLOTS;
    if (nslots > q->qsz / 2u) nslots = q->qsz / 2u;
    if (nslots < 1) nslots = 1;
    q->nslots = nslots;
    q->bufsize = bufsize;

    /* split ring; used ring 4096-aligned (legacy requirement, also valid for modern) */
    size_t desc_sz = 16u * q->qsz, avail_sz = 6u + 2u * q->qsz;
    size_t used_off = (desc_sz + avail_sz + 4095) & ~(size_t)4095;
    size_t used_sz = 6u + 8u * q->qsz;
    q->ring_len = (used_off + used_sz + 4095) & ~(size_t)4095;
    uint64_t ring_bus;
    q->ring_mem = vtp_dma_alloc(d, q->ring_len, &ring_bus);
    if (!q->ring_mem) return -1;
    q->desc = q->ring_mem;
    q->avail = (volatile uint16_t *)((uint8_t *)q->ring_mem + desc_sz);
    q->used = (uint8_t *)q->ring_mem + used_off;

    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    /* PTHREAD_PRIO_INHERIT is the default protocol of a QNX mutex (pthread_mutexattr_init());
     * set here because the slot mutexes depend on it. */
    pthread_mutexattr_t ma;
    pthread_mutexattr_init(&ma);
    pthread_mutexattr_setprotocol(&ma, PTHREAD_PRIO_INHERIT);
    pthread_mutex_init(&q->lk, &ma);
    q->slot_pi = (follow & VQ_FOLLOW_SLOTS) != 0;
    pthread_cond_init(&q->free_cv, &ca);
    for (unsigned i = 0; i < nslots; i++) {
        struct vq_slot *s = &q->slots[i];
        uint64_t bus;
        q->buf_mem[i] = vtp_dma_alloc(d, 2u * (size_t)bufsize, &bus);
        if (!q->buf_mem[i]) return -1;
        s->index = i;
        s->req = q->buf_mem[i]; s->req_bus = bus;
        s->rsp = s->req + bufsize; s->rsp_bus = bus + bufsize;
        s->state = VQS_FREE;
        pthread_cond_init(&s->cv, &ca);
        pthread_mutex_init(&s->own, &ma);
        q->desc[2 * i].addr = s->req_bus;     q->desc[2 * i].len = 0;
        q->desc[2 * i].flags = VRING_DESC_F_NEXT; q->desc[2 * i].next = 2 * i + 1;
        q->desc[2 * i + 1].addr = s->rsp_bus; q->desc[2 * i + 1].len = bufsize;
        q->desc[2 * i + 1].flags = VRING_DESC_F_WRITE; q->desc[2 * i + 1].next = 0;
    }
    q->use_irq = use_irq && d->irq >= 0;
    q->avail[0] = q->use_irq ? 0 : VRING_AVAIL_F_NO_INTERRUPT;

    if (vtp_queue_enable(d, 0, ring_bus, ring_bus + desc_sz, ring_bus + used_off) != 0) return -1;

    if (q->use_irq) {
        /* The thread pool's threads take the priority of the client they serve (QNX message passing:
         * "The threads that receive messages within the server inherit the priorities of the sending
         * threads", System Architecture guide, "Priority inheritance and messages"). A client then
         * waits for the interrupt thread, which receives no message and inherits nothing. With a fixed
         * priority below the client's, any CPU-bound program between the two priorities would delay
         * the completion (priority inversion). So the thread starts at the base priority irq_prio and,
         * with VQ_FOLLOW_IRQ, vq_submit_wait() and vq_get() set it with pthread_setschedprio() to the
         * highest priority among the waiting threads, also below the base: work for a client at priority 10
         * then never preempts a program at 11-20 (the use that the pthread_setschedprio() page names:
         * a thread's own strategy to bound priority inversion). */
        pthread_attr_t ta;
        pthread_attr_init(&ta);
        if (irq_prio > 0) {
            struct sched_param sp;
            memset(&sp, 0, sizeof sp);
            sp.sched_priority = irq_prio;
            pthread_attr_setinheritsched(&ta, PTHREAD_EXPLICIT_SCHED);
            pthread_attr_setschedpolicy(&ta, SCHED_FIFO);
            pthread_attr_setschedparam(&ta, &sp);
        }
        int prc = pthread_create(&q->irq_tid, &ta, irq_main, q);
        pthread_attr_destroy(&ta);
        if (prc != 0) { LOG(q, "FAIL: interrupt thread (priority %d): %s\n", irq_prio, strerror(prc)); return -1; }
        for (int i = 0; i < 1000 && q->irq_ready == 0; i++) usleep(1000);
        if (q->irq_ready != 1) return -1;
        int pol; struct sched_param cur;
        if (pthread_getschedparam(q->irq_tid, &pol, &cur) == EOK) q->irq_prio = cur.sched_priority;
        else q->irq_prio = irq_prio;
        q->irq_cur = q->max_irq_prio = q->min_irq_prio = q->irq_prio;
        q->irq_follow = (follow & VQ_FOLLOW_IRQ) != 0;
        LOG(q, "IRQ: interrupt thread attached to interrupt %d (id %d, SIGEV_INTR, priority %d, %s)\n", d->irq, q->intr_id,
            q->irq_prio, q->irq_follow ? "set to the highest waiting priority" : "fixed");
    } else if (use_irq) {
        LOG(q, "IRQ: no interrupt available; polling\n");
    }
    LOG(q, "VQ: %u slots, %u bytes per buffer, %s, %s\n", q->nslots, q->bufsize, q->use_irq ? "interrupt-driven" : "polling",
        q->slot_pi ? "a thread that waits for a slot raises the slot's owner (priority-inheritance mutex per slot)"
                   : "no priority inheritance through the slots");
    return vtp_driver_ok(d);
}

/* Priority the calling thread runs at now, or 0 if not known. sched_curpriority includes the priority
 * inherited from the client or through a mutex (public page "sched_param"); sched_priority would
 * leave that out. */
static int self_prio(void)
{
    int pol; struct sched_param sp;
    return pthread_getschedparam(pthread_self(), &pol, &sp) == EOK ? sp.sched_curpriority : 0;
}

/* Slot-wait bookkeeping (slot_pi): the waiting thread's priority counts for the interrupt thread,
 * which must deliver the completion that lets the slot's owner give the slot back. q->lk held. */
static void slot_wait_begin_locked(struct virtq *q, int wp)
{
    q->nwait_at[wp]++; q->nwaiters++;
    if (q->irq_follow) irq_set_prio_locked(q, want_prio_locked(q));
}
static void slot_wait_end_locked(struct virtq *q, int wp)
{
    q->nwait_at[wp]--; q->nwaiters--;
    if (q->irq_follow) irq_set_prio_locked(q, want_prio_locked(q));
}

/* The owned slot to wait for: one whose completion has arrived, else the request in flight that
 * was submitted first, else one that its owner is filling or reading, else one being handed over.
 * NULL if every slot is lost (or free). q->lk held. */
static struct vq_slot *pick_target_locked(struct virtq *q)
{
    static const int rank[] = { [VQS_FREE] = 0, [VQS_LOST] = 0, [VQS_HANDOFF] = 1, [VQS_OWNED] = 2,
                                [VQS_INFLIGHT] = 3, [VQS_DONE] = 4 };
    struct vq_slot *best = NULL;
    for (unsigned i = 0; i < q->nslots; i++) {
        struct vq_slot *s = &q->slots[i];
        int r = rank[s->state];
        if (r == 0) continue;
        if (!best || r > rank[best->state] ||
            (r == rank[best->state] && s->state == VQS_INFLIGHT && s->t_submit_ns < best->t_submit_ns)) best = s;
    }
    return best;
}

struct vq_slot *vq_get(struct virtq *q)
{
    int prio = self_prio(), counted = 0, wp = 0;
    pthread_mutex_lock(&q->lk);
    for (;;) {
        struct vq_slot *s = NULL;
        for (unsigned i = 0; i < q->nslots; i++)
            if (q->slots[i].state == VQS_FREE) { s = &q->slots[i]; break; }
        if (s) {
            s->state = VQS_OWNED;
            s->owner_prio = prio;
            if (wp) slot_wait_end_locked(q, wp);
            pthread_mutex_unlock(&q->lk);
            /* The mutex of a free slot is unlocked, or held for a moment by a waiter that will see
             * below that the slot is now owned, and unlock it. */
            if (q->slot_pi) pthread_mutex_lock(&s->own);
            return s;
        }
        if (!counted) {     /* no free slot: statistics once per call */
            counted = 1;
            q->n_slot_wait++;
            if (prio > q->max_slot_wait_prio) q->max_slot_wait_prio = prio;
            int top = -1;
            for (unsigned i = 0; i < q->nslots; i++)
                if (q->slots[i].state != VQS_LOST && q->slots[i].owner_prio > top) top = q->slots[i].owner_prio;
            if (top >= 0 && prio > top) q->n_slot_wait_above++;
            if (q->slot_pi) {
                wp = prio > 255 ? 255 : prio > 0 ? prio : q->irq_prio > 0 ? q->irq_prio : 1;
                slot_wait_begin_locked(q, wp);
            }
        }
        struct vq_slot *t = q->slot_pi ? pick_target_locked(q) : NULL;
        if (!t) { pthread_cond_wait(&q->free_cv, &q->lk); continue; }
        /* Block on the owner's mutex: the kernel raises the owner to this thread's priority until it
         * unlocks the mutex in vq_put(), which then hands the slot to the highest-priority thread
         * blocked here (that thread becomes the mutex's owner). */
        t->nwait++;
        pthread_mutex_unlock(&q->lk);
        pthread_mutex_lock(&t->own);
        pthread_mutex_lock(&q->lk);
        t->nwait--;
        if (t->state == VQS_HANDOFF || t->state == VQS_FREE) {
            t->state = VQS_OWNED;
            t->owner_prio = prio;
            slot_wait_end_locked(q, wp);
            pthread_mutex_unlock(&q->lk);
            return t;                       /* the caller holds t->own */
        }
        pthread_mutex_unlock(&t->own);      /* lost, or taken by a thread that found it free: look again */
    }
}

void vq_put(struct virtq *q, struct vq_slot *s)
{
    pthread_mutex_lock(&q->lk);
    int give = 1;
    if (s->state == VQS_LOST) {             /* the wait timed out */
        if (s->lost_completed) s->lost_completed = 0;           /* and the device has completed it since */
        else { s->lost_released = 1; give = 0; }                /* reap_locked() frees it */
    }
    if (give) {
        if (q->slot_pi && s->nwait > 0) { s->state = VQS_HANDOFF; q->n_handoff++; }
        else { s->state = VQS_FREE; pthread_cond_signal(&q->free_cv); }
    }
    pthread_mutex_unlock(&q->lk);
    if (q->slot_pi) pthread_mutex_unlock(&s->own);   /* ends the raise; a blocked waiter becomes the owner */
}

void vq_slot_counts(struct virtq *q, unsigned *nfree, unsigned *nbusy, unsigned *nlost, unsigned *ninflight)
{
    unsigned f = 0, b = 0, l = 0;
    pthread_mutex_lock(&q->lk);
    for (unsigned i = 0; i < q->nslots; i++) {
        if (q->slots[i].state == VQS_FREE) f++;
        else if (q->slots[i].state == VQS_LOST) l++;
        else b++;
    }
    *ninflight = q->inflight;
    pthread_mutex_unlock(&q->lk);
    *nfree = f; *nbusy = b; *nlost = l;
}

int vq_submit_wait(struct virtq *q, struct vq_slot *s, uint32_t reqlen, int timeout_ms)
{
    unsigned i = s->index;
    s->prio = 0;
    if (q->use_irq) {
        s->prio = self_prio();          /* includes a raise by a thread waiting for this slot */
    }
    pthread_mutex_lock(&q->lk);
    if (s->prio > q->max_client_prio) q->max_client_prio = s->prio;
    q->desc[2 * i].len = reqlen;
    s->state = VQS_INFLIGHT;
    if (q->irq_follow) irq_set_prio_locked(q, want_prio_locked(q));   /* before the device can complete it */
    s->rsp_len = 0;
    if (++q->inflight > q->max_inflight) q->max_inflight = q->inflight;
    uint16_t aidx = q->avail[1];
    q->avail[2 + (aidx % q->qsz)] = 2 * i;   /* head descriptor */
    __sync_synchronize();
    q->avail[1] = aidx + 1;
    __sync_synchronize();
    s->t_submit_ns = vq_now_ns();
    pthread_mutex_unlock(&q->lk);
    vtp_notify(q->dev, 0);

    uint64_t deadline = s->t_submit_ns + (uint64_t)timeout_ms * 1000000ull;
    pthread_mutex_lock(&q->lk);
    unsigned spins = 0;
    while (s->state == VQS_INFLIGHT) {
        uint64_t now = vq_now_ns();
        if (now >= deadline) break;
        if (q->use_irq) {
            /* Wait for the interrupt thread; every 200 ms look at the ring ourselves in case an
             * interrupt was missed. */
            uint64_t until = now + 200000000ull;
            if (until > deadline) until = deadline;
            struct timespec ts = { (time_t)(until / 1000000000ull), (long)(until % 1000000000ull) };
            if (pthread_cond_timedwait(&s->cv, &q->lk, &ts) == ETIMEDOUT) {
                unsigned long before = q->n_reaped;
                (void)vtp_read_isr(q->dev);     /* release an INTx line left asserted (see irq_main) */
                reap_locked(q);
                if (q->n_reaped != before) q->n_reaped_by_waiter++;
            }
        } else {
            reap_locked(q);
            if (s->state != VQS_INFLIGHT) break;
            pthread_mutex_unlock(&q->lk);
            if (++spins < 2000) sched_yield();
            else { struct timespec ts = { 0, 100000 }; nanosleep(&ts, NULL); }
            pthread_mutex_lock(&q->lk);
        }
    }
    int ret;
    if (s->state == VQS_DONE) { s->state = VQS_OWNED; ret = (int)s->rsp_len; }
    else { s->state = VQS_LOST; s->lost_completed = s->lost_released = 0; q->n_lost++; ret = -1; }
    if (q->irq_follow)
        irq_set_prio_locked(q, want_prio_locked(q));                /* the next waiter's priority; idle: not above the base */
    pthread_mutex_unlock(&q->lk);
    return ret;
}
