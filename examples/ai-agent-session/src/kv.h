/* kv.h - kvstore: a small key-value store served by its own thread over QNX message passing.
 *
 * A program starts the server thread with kv_server_start(), opens connections to its channel with
 * kv_connect(), and calls kv_put(), kv_get(), kv_del() and kv_count() on a connection. Keys are
 * strings shorter than KV_KEY_MAX bytes; values are 0 to KV_VALUE_MAX bytes. kv_server_stop() sends
 * the stop pulse and waits for the server thread to end.
 */
#ifndef KV_H
#define KV_H
#include <pthread.h>
#include <stddef.h>

#define KV_KEY_MAX   32
#define KV_VALUE_MAX 4096
#define KV_SLOTS     64

struct kv_store;

struct kv_server {
    int chid;                   /* channel of the server thread */
    pthread_t tid;
    struct kv_store *store;
};

int  kv_server_start(struct kv_server *s);    /* 0, or -1 with errno */
int  kv_server_stop(struct kv_server *s);     /* 0, or -1 with errno */
int  kv_connect(const struct kv_server *s);   /* connection id, or -1 with errno */
void kv_close(int coid);

int  kv_put(int coid, const char *key, const void *value, size_t len);   /* 0, or -1 with errno */
long kv_get(int coid, const char *key, void *buf, size_t size);          /* value length, or -1 */
int  kv_del(int coid, const char *key);                                  /* 0, or -1 with errno */
long kv_count(int coid);                                                 /* number of keys, or -1 */

#endif
