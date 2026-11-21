/* kvclient.c - client functions of kvstore: each call is one QNX message to the server thread. */
#include <errno.h>
#include <string.h>
#include <sys/neutrino.h>
#include "kv.h"
#include "kv_proto.h"

static int fill(struct kv_hdr *h, uint16_t type, const char *key)
{
    size_t n = strlen(key);
    if (n == 0) { errno = EINVAL; return -1; }
    if (n >= KV_KEY_MAX) { errno = ENAMETOOLONG; return -1; }
    memset(h, 0, sizeof *h);
    h->type = type;
    memcpy(h->key, key, n + 1);
    return 0;
}

int kv_connect(const struct kv_server *s)
{
    return ConnectAttach(0, 0, s->chid, _NTO_SIDE_CHANNEL, 0);
}

void kv_close(int coid)
{
    ConnectDetach(coid);
}

int kv_put(int coid, const char *key, const void *value, size_t len)
{
    struct kv_hdr h;
    if (fill(&h, KV_PUT, key) == -1) return -1;
    iov_t iov[2];
    iov[0].iov_base = &h;
    iov[0].iov_len = sizeof h;
    iov[1].iov_base = (void *)value;
    iov[1].iov_len = len;
    return MsgSendvs(coid, iov, 2, NULL, 0) == -1 ? -1 : 0;
}

long kv_get(int coid, const char *key, void *buf, size_t size)
{
    struct kv_hdr h;
    if (fill(&h, KV_GET, key) == -1) return -1;
    return MsgSend(coid, &h, sizeof h, buf, size);
}

int kv_del(int coid, const char *key)
{
    struct kv_hdr h;
    if (fill(&h, KV_DEL, key) == -1) return -1;
    return MsgSend(coid, &h, sizeof h, NULL, 0) == -1 ? -1 : 0;
}

long kv_count(int coid)
{
    uint16_t type = KV_COUNT;
    return MsgSend(coid, &type, sizeof type, NULL, 0);
}
