/* kvserver.c - the kvstore server thread: receives requests on its channel and replies. */
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/neutrino.h>
#include "kv.h"
#include "kv_proto.h"

struct kv_entry {
    int used;
    char key[KV_KEY_MAX];
    size_t vlen;
    unsigned char value[KV_VALUE_MAX];
};

struct kv_store {
    struct kv_entry e[KV_SLOTS];
};

union kv_recv {
    uint16_t type;
    struct _pulse pulse;
    struct kv_hdr hdr;
    unsigned char raw[KV_RECV_BYTES];
};

static struct kv_entry *lookup(struct kv_store *st, const char *key, int add)
{
    struct kv_entry *free_slot = NULL;
    for (int i = 0; i < KV_SLOTS; i++) {
        struct kv_entry *e = &st->e[i];
        if (e->used && strcmp(e->key, key) == 0) return e;
        if (!e->used && !free_slot) free_slot = e;
    }
    if (!add || !free_slot) return NULL;
    free_slot->used = 1;
    strcpy(free_slot->key, key);
    free_slot->vlen = 0;
    return free_slot;
}

static int key_ok(const struct kv_hdr *h)
{
    return memchr(h->key, '\0', sizeof h->key) != NULL && h->key[0] != '\0';
}

/* KV_PUT: the value is everything after the header. The first value bytes arrived with the header
 * in the receive buffer; the rest is read from the client with MsgRead(). */
static int do_put(struct kv_store *st, int rcvid, const struct _msg_info *info, const union kv_recv *m)
{
    size_t msg_bytes = info->msglen;            /* length of the client's message */
    if (msg_bytes < sizeof(struct kv_hdr)) return EBADMSG;
    size_t vlen = msg_bytes - sizeof(struct kv_hdr);
    if (vlen > KV_VALUE_MAX) return E2BIG;
    struct kv_entry *e = lookup(st, m->hdr.key, 1);
    if (!e) return ENOSPC;
    size_t have = sizeof(*m) - sizeof(struct kv_hdr);     /* value bytes in the receive buffer */
    if (have > vlen) have = vlen;
    memcpy(e->value, m->raw + sizeof(struct kv_hdr), have);
    if (vlen > have) {
        long n = MsgRead(rcvid, e->value + have, vlen - have, sizeof(struct kv_hdr) + have);
        if (n != (long)(vlen - have)) return EFAULT;
    }
    e->vlen = vlen;
    return EOK;
}

static void *server_main(void *arg)
{
    struct kv_server *s = arg;
    struct kv_store *st = s->store;
    union kv_recv m;
    for (;;) {
        struct _msg_info info;
        int rcvid = MsgReceive(s->chid, &m, sizeof m, &info);
        if (rcvid == -1) {
            if (errno == EINTR) continue;
            break;
        }
        if (rcvid == 0) {                       /* a pulse */
            if (m.pulse.code == KV_PULSE_STOP) break;
            continue;                           /* other pulse codes are ignored */
        }
        if (info.msglen < (ssize_t)sizeof m.type) { MsgError(rcvid, EBADMSG); continue; }
        if (m.type == KV_COUNT) {
            long n = 0;
            for (int i = 0; i < KV_SLOTS; i++) n += st->e[i].used;
            MsgReply(rcvid, n, NULL, 0);
            continue;
        }
        if (info.msglen < (ssize_t)sizeof(struct kv_hdr) || !key_ok(&m.hdr)) { MsgError(rcvid, EINVAL); continue; }
        struct kv_entry *e;
        int rc;
        switch (m.type) {
        case KV_PUT:
            rc = do_put(st, rcvid, &info, &m);
            if (rc == EOK) MsgReply(rcvid, 0, NULL, 0);
            else MsgError(rcvid, rc);
            break;
        case KV_GET:
            e = lookup(st, m.hdr.key, 0);
            if (e) MsgReply(rcvid, (long)e->vlen, e->value, e->vlen);
            else MsgError(rcvid, ENOENT);
            break;
        case KV_DEL:
            e = lookup(st, m.hdr.key, 0);
            if (e) { e->used = 0; MsgReply(rcvid, 0, NULL, 0); }
            else MsgError(rcvid, ENOENT);
            break;
        default:
            MsgError(rcvid, ENOSYS);
            break;
        }
    }
    return NULL;
}

int kv_server_start(struct kv_server *s)
{
    s->store = calloc(1, sizeof *s->store);
    if (!s->store) return -1;
    s->chid = ChannelCreate(0);
    if (s->chid == -1) { free(s->store); return -1; }
    int rc = pthread_create(&s->tid, NULL, server_main, s);
    if (rc != EOK) { ChannelDestroy(s->chid); free(s->store); errno = rc; return -1; }
    return 0;
}

int kv_server_stop(struct kv_server *s)
{
    int coid = kv_connect(s);
    if (coid == -1) return -1;
    struct sched_param sp;
    int pol;
    pthread_getschedparam(pthread_self(), &pol, &sp);
    int rc = MsgSendPulse(coid, sp.sched_priority, KV_PULSE_STOP, 0);
    kv_close(coid);
    if (rc == -1) return -1;
    rc = pthread_join(s->tid, NULL);
    if (rc != EOK) { errno = rc; return -1; }
    ChannelDestroy(s->chid);
    free(s->store);
    s->store = NULL;
    return 0;
}
