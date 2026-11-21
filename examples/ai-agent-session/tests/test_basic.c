/* test_basic.c - put, get, overwrite, delete and count with short values. */
#include <errno.h>
#include <string.h>
#include "kv.h"
#include "check.h"

int main(void)
{
    struct kv_server s;
    char buf[KV_VALUE_MAX];
    if (kv_server_start(&s) == -1) { perror("kv_server_start"); return 1; }
    int coid = kv_connect(&s);
    CHECK(coid != -1, "connect to the server's channel");

    CHECK(kv_put(coid, "apple", "red", 3) == 0, "put apple=red");
    long n = kv_get(coid, "apple", buf, sizeof buf);
    CHECK(n == 3 && memcmp(buf, "red", 3) == 0, "get apple returns its 3 bytes (got %ld)", n);

    CHECK(kv_put(coid, "apple", "green", 5) == 0, "overwrite apple=green");
    n = kv_get(coid, "apple", buf, sizeof buf);
    CHECK(n == 5 && memcmp(buf, "green", 5) == 0, "get apple returns the new value (got %ld bytes)", n);

    char v[200];
    for (size_t i = 0; i < sizeof v; i++) v[i] = (char)('a' + i % 26);
    CHECK(kv_put(coid, "kiwi", v, sizeof v) == 0, "put a 200-byte value");
    n = kv_get(coid, "kiwi", buf, sizeof buf);
    CHECK(n == (long)sizeof v && memcmp(buf, v, sizeof v) == 0, "get returns the 200 bytes (got %ld)", n);

    CHECK(kv_put(coid, "empty", "", 0) == 0, "put an empty value");
    n = kv_get(coid, "empty", buf, sizeof buf);
    CHECK(n == 0, "get of the empty value returns 0 bytes (got %ld)", n);

    CHECK(kv_count(coid) == 3, "count is 3");
    CHECK(kv_del(coid, "apple") == 0, "delete apple");
    errno = 0;
    n = kv_get(coid, "apple", buf, sizeof buf);
    CHECK(n == -1 && errno == ENOENT, "get of a deleted key fails with ENOENT");
    errno = 0;
    CHECK(kv_del(coid, "nokey") == -1 && errno == ENOENT, "delete of a missing key fails with ENOENT");
    CHECK(kv_count(coid) == 2, "count is 2 after the delete");
    errno = 0;
    CHECK(kv_put(coid, "a_key_that_is_much_too_long_for_kv", "x", 1) == -1 && errno == ENAMETOOLONG,
          "a key of 34 characters is refused with ENAMETOOLONG");

    kv_close(coid);
    CHECK(kv_server_stop(&s) == 0, "stop the server");
    return CHECK_DONE();
}
