/* test_large.c - values that do not fit into one receive buffer of the server. */
#include <errno.h>
#include <string.h>
#include "kv.h"
#include "check.h"

static unsigned char val[KV_VALUE_MAX + 1], buf[KV_VALUE_MAX];

static void pattern(size_t len, unsigned seed)
{
    for (size_t i = 0; i < len; i++) val[i] = (unsigned char)((i * 7 + seed) & 0xff);
}

int main(void)
{
    struct kv_server s;
    if (kv_server_start(&s) == -1) { perror("kv_server_start"); return 1; }
    int coid = kv_connect(&s);
    CHECK(coid != -1, "connect to the server's channel");

    pattern(1000, 1);
    CHECK(kv_put(coid, "blob", val, 1000) == 0, "put a 1000-byte value");
    long n = kv_get(coid, "blob", buf, sizeof buf);
    CHECK(n == 1000, "get returns 1000 bytes (got %ld)", n);
    CHECK(n > 0 && memcmp(buf, val, (size_t)n) == 0, "the bytes are the bytes that were put");

    pattern(KV_VALUE_MAX, 5);
    CHECK(kv_put(coid, "max", val, KV_VALUE_MAX) == 0, "put a value of KV_VALUE_MAX (%d) bytes", KV_VALUE_MAX);
    n = kv_get(coid, "max", buf, sizeof buf);
    CHECK(n == KV_VALUE_MAX && memcmp(buf, val, KV_VALUE_MAX) == 0,
          "get returns the %d bytes (got %ld)", KV_VALUE_MAX, n);

    errno = 0;
    int rc = kv_put(coid, "toolong", val, KV_VALUE_MAX + 1);
    CHECK(rc == -1 && errno == E2BIG, "a value of %d bytes is refused with E2BIG (rc %d, errno %d)",
          KV_VALUE_MAX + 1, rc, errno);
    CHECK(kv_count(coid) == 2, "count is 2");

    kv_close(coid);
    CHECK(kv_server_stop(&s) == 0, "stop the server");
    return CHECK_DONE();
}
