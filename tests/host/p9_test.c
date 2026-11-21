/*
 * tests/host/p9_test.c - table tests of the 9P2000.L codec and reply parser in src/p9.c, run on a
 * Linux host (no QNX SDP; see fake_virtq.h). Built by "make host-check" with AddressSanitizer and
 * UndefinedBehaviorSanitizer.
 *
 * What is checked:
 *   1. requests: the bytes of every T-message that p9.c sends, against byte strings written from
 *      the 9P2000.L message formats (Linux Documentation/filesystems/9p.rst, the QEMU 9p
 *      documentation, Plan 9 manual section 5); little-endian fields, string = 2-byte length + bytes
 *   2. replies: the fields that p9.c decodes from valid R-messages
 *   3. malformed replies: wrong type, short reply, bad size field, counts larger than the data or
 *      than the request, Rlerror codes, no answer; each must give the stated error
 *   4. every proper prefix of every valid reply body must be rejected with -EIO
 *   5. walks of more than 16 names, msize negotiation, requests too long for msize, directory
 *      entries, the fid pool
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include "fake_virtq.h"
#include "../../src/p9.c"

#include <stdarg.h>

static int n_checks, n_fail;

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    n_checks++;
    if (!ok) n_fail++;
    printf("%s ", ok ? "ok  " : "FAIL");
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
}

/* ---------- byte strings ---------- */
#define L16(v) (uint8_t)((v) & 0xff), (uint8_t)(((v) >> 8) & 0xff)
#define L32(v) L16((v) & 0xffff), L16(((v) >> 16) & 0xffff)
#define L64(v) L32((uint64_t)(v) & 0xffffffffu), L32(((uint64_t)(v) >> 32) & 0xffffffffu)

/* message builder for replies */
struct mb { uint8_t b[16384]; size_t n; };
static void m8(struct mb *m, uint8_t v) { m->b[m->n++] = v; }
static void m16(struct mb *m, uint16_t v) { m8(m, v & 0xff); m8(m, v >> 8); }
static void m32(struct mb *m, uint32_t v) { m16(m, v & 0xffff); m16(m, v >> 16); }
static void m64(struct mb *m, uint64_t v) { m32(m, (uint32_t)v); m32(m, (uint32_t)(v >> 32)); }
static void mstr(struct mb *m, const char *s) { size_t k = strlen(s); m16(m, (uint16_t)k); memcpy(m->b + m->n, s, k); m->n += k; }
static void mqid(struct mb *m, uint8_t type, uint32_t ver, uint64_t path) { m8(m, type); m32(m, ver); m64(m, path); }
static void mbegin(struct mb *m, uint8_t type, uint16_t tag) { m->n = 0; m32(m, 0); m8(m, type); m16(m, tag); }
static void mend(struct mb *m) { uint32_t n = (uint32_t)m->n; m->b[0] = n; m->b[1] = n >> 8; m->b[2] = n >> 16; m->b[3] = n >> 24; }

static struct virtq q;
static struct p9_client c;

static void client_reset(uint32_t msize)
{
    fake_free(&q);
    fake_init(&q, 16384);
    p9_client_init(&c, &q, NULL, 0);
    c.msize = msize;
}

/* ---------- valid replies, one per call (bodies hold exactly the fields that p9.c reads) ---------- */
enum call { C_VERSION, C_ATTACH, C_WALK, C_LOPEN, C_LCREATE, C_READ, C_WRITE, C_CLUNK, C_GETATTR,
            C_SETATTR, C_READDIR, C_MKDIR, C_UNLINKAT, C_RENAMEAT, C_FSYNC, C_READLINK, C_SYMLINK,
            C_STATFS, C_NCALLS };
static const char *call_name[C_NCALLS] = { "version", "attach", "walk", "lopen", "lcreate", "read",
    "write", "clunk", "getattr", "setattr", "readdir", "mkdir", "unlinkat", "renameat", "fsync",
    "readlink", "symlink", "statfs" };
static const uint8_t rtype[C_NCALLS] = { 101, 105, 111, 13, 15, 117, 119, 121, 25, 27, 41, 73, 77, 75,
    51, 23, 17, 9 };

static void valid_reply(enum call k, struct mb *m)
{
    mbegin(m, rtype[k], k == C_VERSION ? 0xffff : 0);
    switch (k) {
    case C_VERSION:  m32(m, 8192); mstr(m, "9P2000.L"); break;
    case C_ATTACH:   mqid(m, 0x80, 1, 0x100); break;
    case C_WALK:     m16(m, 2); mqid(m, 0x80, 0, 0x200); mqid(m, 0x00, 7, 0x201); break;
    case C_LOPEN:    mqid(m, 0x00, 7, 0x201); m32(m, 4096); break;
    case C_LCREATE:  mqid(m, 0x00, 1, 0x300); m32(m, 0); break;
    case C_READ:     m32(m, 5); memcpy(m->b + m->n, "hello", 5); m->n += 5; break;
    case C_WRITE:    m32(m, 3); break;
    case C_GETATTR:
        m64(m, 0x7ff); mqid(m, 0x00, 7, 0x201); m32(m, 0100644); m32(m, 1000); m32(m, 100);
        m64(m, 1); m64(m, 0); m64(m, 12345); m64(m, 4096); m64(m, 32);
        m64(m, 1700000001); m64(m, 11); m64(m, 1700000002); m64(m, 22); m64(m, 1700000003); m64(m, 33);
        break;
    case C_READDIR:
        m32(m, 2 * (13 + 8 + 1 + 2) + 1 + 2);
        mqid(m, 0x80, 0, 0x10); m64(m, 1); m8(m, 4); mstr(m, ".");
        mqid(m, 0x00, 0, 0x11); m64(m, 2); m8(m, 8); mstr(m, "ab");
        break;
    case C_MKDIR:    mqid(m, 0x80, 0, 0x400); break;
    case C_READLINK: mstr(m, "target"); break;
    case C_SYMLINK:  mqid(m, 0x02, 0, 0x500); break;
    case C_STATFS:
        m32(m, 0xef53); m32(m, 4096); m64(m, 1000); m64(m, 600); m64(m, 500); m64(m, 64);
        m64(m, 32); m64(m, 0x1234); m32(m, 255);
        break;
    default: break;      /* Rclunk, Rsetattr, Runlinkat, Rrenameat, Rfsync: empty body */
    }
    mend(m);
}

/* call k with fixed arguments; returns the call's return value; outputs in the statics below */
static struct p9_qid o_qid; static uint32_t o_iounit; static char o_ver[32]; static char o_buf[256];
static struct p9_attr o_attr; static struct p9_statfs o_st; static int o_nwalked;

static long do_call(enum call k)
{
    static const char *const names2[] = { "a", "bc" };
    struct p9_setattr sa = { P9_SETATTR_MODE | P9_SETATTR_SIZE, 0600, (uint32_t)-1, (uint32_t)-1, 10, 0, 0, 0, 0 };
    memset(&o_qid, 0, sizeof o_qid); o_iounit = 0; memset(o_ver, 0, sizeof o_ver); memset(o_buf, 0, sizeof o_buf);
    memset(&o_attr, 0, sizeof o_attr); memset(&o_st, 0, sizeof o_st); o_nwalked = -1;
    switch (k) {
    case C_VERSION:  return p9_version(&c, 8192, o_ver, sizeof o_ver);
    case C_ATTACH:   return p9_attach(&c, 1, "u", "", 1000, &o_qid);
    case C_WALK:     return p9_walk_ex(&c, 1, 2, 2, names2, &o_qid, &o_nwalked);
    case C_LOPEN:    return p9_lopen(&c, 2, 2, &o_qid, &o_iounit);
    case C_LCREATE:  return p9_lcreate(&c, 2, "f", 0101, 0644, 100, &o_qid, &o_iounit);
    case C_READ:     return p9_read(&c, 2, 0x1122334455667788ull, o_buf, 100);
    case C_WRITE:    return p9_write(&c, 2, 5, "xyz", 3);
    case C_CLUNK:    return p9_clunk(&c, 2);
    case C_GETATTR:  return p9_getattr(&c, 2, P9_GETATTR_BASIC, &o_attr);
    case C_SETATTR:  return p9_setattr(&c, 2, &sa);
    case C_READDIR:  return p9_readdir(&c, 2, 7, o_buf, 200);
    case C_MKDIR:    return p9_mkdir(&c, 1, "d", 0755, 100, &o_qid);
    case C_UNLINKAT: return p9_unlinkat(&c, 1, "d", P9_AT_REMOVEDIR);
    case C_RENAMEAT: return p9_renameat(&c, 1, "a", 3, "b");
    case C_FSYNC:    return p9_fsync(&c, 2);
    case C_READLINK: return p9_readlink(&c, 2, o_buf, sizeof o_buf);
    case C_SYMLINK:  return p9_symlink(&c, 1, "l", "t", 100, &o_qid);
    case C_STATFS:   return p9_statfs(&c, 1, &o_st);
    default:         return -9999;
    }
}

/* ---------- 1. requests ---------- */
static const uint8_t e_version[]  = { 100, L16(0xffff), L32(8192), L16(8), '9','P','2','0','0','0','.','L' };
static const uint8_t e_attach[]   = { 104, L16(0), L32(1), L32(0xffffffffu), L16(1), 'u', L16(0), L32(1000) };
static const uint8_t e_walk[]     = { 110, L16(0), L32(1), L32(2), L16(2), L16(1), 'a', L16(2), 'b', 'c' };
static const uint8_t e_lopen[]    = { 12, L16(0), L32(2), L32(2) };
static const uint8_t e_lcreate[]  = { 14, L16(0), L32(2), L16(1), 'f', L32(0101), L32(0644), L32(100) };
static const uint8_t e_read[]     = { 116, L16(0), L32(2), L64(0x1122334455667788ull), L32(100) };
static const uint8_t e_write[]    = { 118, L16(0), L32(2), L64(5), L32(3), 'x', 'y', 'z' };
static const uint8_t e_clunk[]    = { 120, L16(0), L32(2) };
static const uint8_t e_getattr[]  = { 24, L16(0), L32(2), L64(0x7ff) };
static const uint8_t e_setattr[]  = { 26, L16(0), L32(2), L32(9), L32(0600), L32(0xffffffffu), L32(0xffffffffu),
                                      L64(10), L64(0), L64(0), L64(0), L64(0) };
static const uint8_t e_readdir[]  = { 40, L16(0), L32(2), L64(7), L32(200) };
static const uint8_t e_mkdir[]    = { 72, L16(0), L32(1), L16(1), 'd', L32(0755), L32(100) };
static const uint8_t e_unlinkat[] = { 76, L16(0), L32(1), L16(1), 'd', L32(0x200) };
static const uint8_t e_renameat[] = { 74, L16(0), L32(1), L16(1), 'a', L32(3), L16(1), 'b' };
static const uint8_t e_fsync[]    = { 50, L16(0), L32(2), L32(0) };
static const uint8_t e_readlink[] = { 22, L16(0), L32(2) };
static const uint8_t e_symlink[]  = { 16, L16(0), L32(1), L16(1), 'l', L16(1), 't', L32(100) };
static const uint8_t e_statfs[]   = { 8, L16(0), L32(1) };
#define E(x) { x, sizeof x }
static const struct { const uint8_t *b; size_t n; } expect_req[C_NCALLS] = {
    E(e_version), E(e_attach), E(e_walk), E(e_lopen), E(e_lcreate), E(e_read), E(e_write), E(e_clunk),
    E(e_getattr), E(e_setattr), E(e_readdir), E(e_mkdir), E(e_unlinkat), E(e_renameat), E(e_fsync),
    E(e_readlink), E(e_symlink), E(e_statfs) };

static void test_requests(void)
{
    struct mb m;
    for (int k = 0; k < C_NCALLS; k++) {
        client_reset(8192);
        valid_reply(k, &m); fake_reply(m.b, m.n);
        long rc = do_call(k);
        uint32_t size = le32(fake_last_req);
        int same = fake_last_req_len == 4 + expect_req[k].n && memcmp(fake_last_req + 4, expect_req[k].b, expect_req[k].n) == 0;
        check(rc >= 0 && fake_nreq == 1 && size == fake_last_req_len && same,
              "T%-8s request bytes as specified (%u bytes, size field %u, call returned %ld)", call_name[k], fake_last_req_len, size, rc);
    }
}

/* ---------- 2. valid replies ---------- */
static void test_valid_replies(void)
{
    struct mb m;
    long rc;
#define RUN(k) (client_reset(8192), valid_reply(k, &m), fake_reply(m.b, m.n), do_call(k))
    rc = RUN(C_VERSION);
    check(rc == 0 && strcmp(o_ver, "9P2000.L") == 0 && c.msize == 8192, "Rversion: 9P2000.L, msize 8192");
    rc = RUN(C_ATTACH);
    check(rc == 0 && o_qid.type == 0x80 && o_qid.version == 1 && o_qid.path == 0x100 && c.root_fid == 1, "Rattach: qid (dir, 1, 0x100), root fid 1");
    rc = RUN(C_WALK);
    check(rc == 0 && o_qid.path == 0x201 && o_qid.version == 7 && o_nwalked == 2, "Rwalk: 2 qids, last qid path 0x201, 2 names walked");
    rc = RUN(C_LOPEN);
    check(rc == 0 && o_qid.path == 0x201 && o_iounit == 4096, "Rlopen: qid path 0x201, iounit 4096");
    rc = RUN(C_LCREATE);
    check(rc == 0 && o_qid.path == 0x300 && o_iounit == 0, "Rlcreate: qid path 0x300, iounit 0");
    rc = RUN(C_READ);
    check(rc == 5 && memcmp(o_buf, "hello", 5) == 0, "Rread: 5 bytes \"hello\"");
    rc = RUN(C_WRITE);
    check(rc == 3, "Rwrite: count 3");
    rc = RUN(C_GETATTR);
    check(rc == 0 && o_attr.valid == 0x7ff && o_attr.qid.path == 0x201 && o_attr.mode == 0100644 && o_attr.uid == 1000 &&
          o_attr.gid == 100 && o_attr.nlink == 1 && o_attr.size == 12345 && o_attr.blksize == 4096 && o_attr.blocks == 32 &&
          o_attr.atime_sec == 1700000001 && o_attr.atime_nsec == 11 && o_attr.mtime_sec == 1700000002 &&
          o_attr.mtime_nsec == 22 && o_attr.ctime_sec == 1700000003 && o_attr.ctime_nsec == 33,
          "Rgetattr: all 16 decoded fields");
    /* Linux and QEMU also send btime, gen and data_version after ctime: accepted, not decoded */
    client_reset(8192); valid_reply(C_GETATTR, &m); m64(&m, 1); m64(&m, 2); m64(&m, 3); m64(&m, 4); mend(&m);
    fake_reply(m.b, m.n); rc = do_call(C_GETATTR);
    check(rc == 0 && o_attr.size == 12345, "Rgetattr with btime, gen, data_version after ctime: accepted");
    rc = RUN(C_READDIR);
    check(rc == 51, "Rreaddir: 51 bytes of entries");
    {
        size_t pos = 0; struct p9_dirent e; int r1, r2, r3;
        r1 = p9_dirent_next((uint8_t *)o_buf, 51, &pos, &e);
        int ok1 = r1 == 1 && e.namelen == 1 && e.name[0] == '.' && e.type == 4 && e.offset == 1 && e.qid.path == 0x10;
        r2 = p9_dirent_next((uint8_t *)o_buf, 51, &pos, &e);
        int ok2 = r2 == 1 && e.namelen == 2 && memcmp(e.name, "ab", 2) == 0 && e.type == 8 && e.offset == 2;
        r3 = p9_dirent_next((uint8_t *)o_buf, 51, &pos, &e);
        check(ok1 && ok2 && r3 == 0 && pos == 51, "Rreaddir data: entries \".\" (dir, offset 1) and \"ab\" (file, offset 2), then end");
    }
    rc = RUN(C_MKDIR);
    check(rc == 0 && o_qid.path == 0x400, "Rmkdir: qid path 0x400");
    rc = RUN(C_READLINK);
    check(rc == 6 && strcmp(o_buf, "target") == 0, "Rreadlink: \"target\", NUL-terminated");
    rc = RUN(C_SYMLINK);
    check(rc == 0 && o_qid.type == 0x02 && o_qid.path == 0x500, "Rsymlink: qid type symlink, path 0x500");
    rc = RUN(C_STATFS);
    check(rc == 0 && o_st.type == 0xef53 && o_st.bsize == 4096 && o_st.blocks == 1000 && o_st.bfree == 600 &&
          o_st.bavail == 500 && o_st.files == 64 && o_st.ffree == 32 && o_st.fsid == 0x1234 && o_st.namelen == 255,
          "Rstatfs: all 9 fields");
    const enum call empty[] = { C_CLUNK, C_SETATTR, C_UNLINKAT, C_RENAMEAT, C_FSYNC };
    for (unsigned i = 0; i < sizeof empty / sizeof empty[0]; i++) {
        rc = RUN(empty[i]);
        check(rc == 0, "R%s (empty body): accepted", call_name[empty[i]]);
    }
#undef RUN
}

/* ---------- 3. malformed replies ---------- */
static long reply_raw(enum call k, const uint8_t *b, size_t n)
{
    client_reset(8192);
    fake_reply(b, n);
    return do_call(k);
}

static void test_malformed(void)
{
    struct mb m;
    long rc;
    /* transport level (rpc) */
    client_reset(8192); fake_reply(NULL, FAKE_TIMEOUT); rc = do_call(C_CLUNK);
    check(rc == -EIO, "no answer from the device: -EIO (got %ld)", rc);
    { uint8_t b[] = { L32(7), 121, L16(0) }; rc = reply_raw(C_CLUNK, b, 6);
      check(rc == -EIO, "reply of 6 bytes (less than the 7-byte header): -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(8), 121, L16(0) }; rc = reply_raw(C_CLUNK, b, 7);
      check(rc == -EIO, "size field 8 > 7 bytes written: -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(6), 121, L16(0) }; rc = reply_raw(C_CLUNK, b, 7);
      check(rc == -EIO, "size field 6 < header size 7: -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(7), 121, L16(0), 0xee, 0xee }; rc = reply_raw(C_CLUNK, b, 9);
      check(rc == 0, "device wrote 2 bytes after the message (size 7): accepted, extra bytes ignored (got %ld)", rc); }
    { uint8_t b[] = { L32(7), 25, L16(0) }; rc = reply_raw(C_CLUNK, b, 7);
      check(rc == -EIO, "Rgetattr type in answer to Tclunk: -EIO (got %ld)", rc); }
    /* Rlerror */
    { uint8_t b[] = { L32(11), 7, L16(0), L32(2) }; rc = reply_raw(C_LOPEN, b, 11);
      check(rc == -ENOENT, "Rlerror 2 (Linux ENOENT): -ENOENT (got %ld)", rc); }
    { uint8_t b[] = { L32(11), 7, L16(0), L32(13) }; rc = reply_raw(C_LOPEN, b, 11);
      check(rc == -EACCES, "Rlerror 13 (Linux EACCES): -EACCES (got %ld)", rc); }
    { uint8_t b[] = { L32(11), 7, L16(0), L32(9999) }; rc = reply_raw(C_LOPEN, b, 11);
      check(rc == -EIO, "Rlerror 9999 (not a Linux errno): -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(9), 7, L16(0), L16(2) }; rc = reply_raw(C_LOPEN, b, 9);
      check(rc == -EIO, "Rlerror with a 2-byte body (ecode needs 4): -EIO (got %ld)", rc); }
    /* counts and lengths */
    { uint8_t b[] = { L32(16), 117, L16(0), L32(5), 'h', 'e', 'l', 'l', 'o' }; client_reset(8192); fake_reply(b, 16);
      rc = p9_read(&c, 2, 0, o_buf, 4);
      check(rc == -EIO, "Rread count 5 for a Tread of 4 bytes: -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(14), 117, L16(0), L32(5), 'h', 'e', 'l' }; rc = reply_raw(C_READ, b, 14);
      check(rc == -EIO, "Rread count 5 with 3 data bytes: -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(11), 117, L16(0), L32(0xfffffffcu) }; rc = reply_raw(C_READ, b, 11);
      check(rc == -EIO, "Rread count 0xfffffffc (offset + count wraps in 32 bits): -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(11), 41, L16(0), L32(0xffffffffu) }; rc = reply_raw(C_READDIR, b, 11);
      check(rc == -EIO, "Rreaddir count 0xffffffff with no data: -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(11), 119, L16(0), L32(4) }; rc = reply_raw(C_WRITE, b, 11);
      check(rc == -EIO, "Rwrite count 4 for a Twrite of 3 bytes: -EIO (got %ld)", rc); }
    { uint8_t b[] = { L32(9), 117, L16(0), L16(0) }; rc = reply_raw(C_READ, b, 9);
      check(rc == -EIO, "Rread with a 2-byte body (count needs 4): -EIO (got %ld)", rc); }
    /* walk */
    mbegin(&m, 111, 0); m16(&m, 3); for (int i = 0; i < 3; i++) mqid(&m, 0, 0, i); mend(&m);
    rc = reply_raw(C_WALK, m.b, m.n);
    check(rc == -EIO && o_nwalked == 0, "Rwalk with 3 qids for 2 names: -EIO, 0 names reported as walked (got %ld, %d)", rc, o_nwalked);
    mbegin(&m, 111, 0); m16(&m, 1); mqid(&m, 0x80, 0, 0x200); mend(&m);
    rc = reply_raw(C_WALK, m.b, m.n);
    check(rc == -ENOENT && o_nwalked == 1 && o_qid.path == 0x200, "Rwalk with 1 qid for 2 names: -ENOENT, 1 name walked, qid of the first (got %ld, %d)", rc, o_nwalked);
    mbegin(&m, 111, 0); m16(&m, 0); mend(&m);
    rc = reply_raw(C_WALK, m.b, m.n);
    check(rc == -ENOENT && o_nwalked == 0, "Rwalk with 0 qids for 2 names: -ENOENT, 0 names walked (got %ld)", rc);
    /* version */
    mbegin(&m, 101, 0xffff); m32(&m, 8192); mstr(&m, "9P2000"); mend(&m);
    rc = reply_raw(C_VERSION, m.b, m.n);
    check(rc == -EPROTO, "Rversion \"9P2000\" (not 9P2000.L): -EPROTO (got %ld)", rc);
    mbegin(&m, 101, 0xffff); m32(&m, 4095); mstr(&m, "9P2000.L"); mend(&m);
    rc = reply_raw(C_VERSION, m.b, m.n);
    check(rc == -EPROTO, "Rversion msize 4095 (< 4096): -EPROTO (got %ld)", rc);
    /* readlink */
    mbegin(&m, 23, 0); mstr(&m, "target"); mend(&m);
    client_reset(8192); fake_reply(m.b, m.n); rc = p9_readlink(&c, 2, o_buf, 6);
    check(rc == -ENAMETOOLONG, "Rreadlink of 6 bytes into a 6-byte buffer (no room for NUL): -ENAMETOOLONG (got %ld)", rc);
    client_reset(8192); fake_reply(m.b, m.n); rc = p9_readlink(&c, 2, o_buf, 7);
    check(rc == 6 && strcmp(o_buf, "target") == 0, "Rreadlink of 6 bytes into a 7-byte buffer: 6 (got %ld)", rc);
    /* directory entries */
    {
        uint8_t d[] = { 0, L32(0), L64(1), L64(1), 8, L16(5), 'a', 'b' };   /* name length 5, 2 bytes left */
        size_t pos = 0; struct p9_dirent e;
        check(p9_dirent_next(d, sizeof d, &pos, &e) == -1 && pos == 0, "directory entry whose name length passes the end: -1, position unchanged");
        uint8_t d2[] = { 0, L32(0), L64(1) };                                /* entry cut inside the offset */
        pos = 0;
        check(p9_dirent_next(d2, sizeof d2, &pos, &e) == -1, "directory entry cut after 13 bytes: -1");
        pos = 0;
        check(p9_dirent_next(d2, 0, &pos, &e) == 0, "empty directory data: 0 (end)");
    }
}

/* ---------- 4. every proper prefix of a valid reply body is rejected ---------- */
static void test_prefixes(void)
{
    struct mb m, t;
    for (int k = 0; k < C_NCALLS; k++) {
        valid_reply(k, &m);
        size_t body = m.n - 7;
        if (body == 0) continue;
        int bad = 0; size_t first_bad = 0; long bad_rc = 0;
        for (size_t cut = 0; cut < body; cut++) {
            memcpy(t.b, m.b, 7 + cut); t.n = 7 + cut; mend(&t);
            long rc = reply_raw(k, t.b, t.n);
            if (rc != -EIO) { if (!bad) { first_bad = cut; bad_rc = rc; } bad++; }
        }
        check(bad == 0, "R%-8s every proper prefix of the %zu-byte body (%zu prefixes) gives -EIO", call_name[k], body, body);
        if (bad) printf("     %d prefixes accepted; first: %zu bytes, return value %ld\n", bad, first_bad, bad_rc);
    }
}

/* ---------- 5. walks, msize, long requests, fid pool ---------- */
static void test_misc(void)
{
    struct mb m;
    long rc;
    /* a walk of 20 names: Twalk of 16 names, then Twalk of 4 names from newfid */
    const char *names[20]; char nb[20][16];
    for (int i = 0; i < 20; i++) { snprintf(nb[i], sizeof nb[i], "n%d", i); names[i] = nb[i]; }
    client_reset(8192);
    mbegin(&m, 111, 0); m16(&m, 16); for (int i = 0; i < 16; i++) mqid(&m, 0x80, 0, 100 + i); mend(&m); fake_reply(m.b, m.n);
    mbegin(&m, 111, 0); m16(&m, 4); for (int i = 0; i < 4; i++) mqid(&m, 0, 0, 200 + i); mend(&m); fake_reply(m.b, m.n);
    struct p9_qid last; int nw = -1;
    rc = p9_walk_ex(&c, 1, 2, 20, names, &last, &nw);
    uint32_t fid2 = le32(fake_last_req + 7), newfid2 = le32(fake_last_req + 11);
    uint16_t nwname2 = le16(fake_last_req + 15);
    check(rc == 0 && fake_nreq == 2 && nw == 20 && last.path == 203 && fid2 == 2 && newfid2 == 2 && nwname2 == 4,
          "walk of 20 names: 2 Twalk messages (16 + 4), the second from newfid to newfid; last qid path 203");
    /* the second Twalk fails: newfid is clunked */
    client_reset(8192);
    mbegin(&m, 111, 0); m16(&m, 16); for (int i = 0; i < 16; i++) mqid(&m, 0x80, 0, 100 + i); mend(&m); fake_reply(m.b, m.n);
    mbegin(&m, 111, 0); m16(&m, 2); for (int i = 0; i < 2; i++) mqid(&m, 0, 0, 200 + i); mend(&m); fake_reply(m.b, m.n);
    mbegin(&m, 121, 0); mend(&m); fake_reply(m.b, m.n);
    nw = -1;
    rc = p9_walk_ex(&c, 1, 2, 20, names, &last, &nw);
    check(rc == -ENOENT && nw == 18 && fake_nreq == 3 && fake_last_req[4] == P9_TCLUNK && le32(fake_last_req + 7) == 2,
          "walk of 20 names, second Twalk stops after 2: -ENOENT, 18 walked, then Tclunk of newfid 2");
    /* msize negotiation */
    client_reset(8192);
    mbegin(&m, 101, 0xffff); m32(&m, 65536); mstr(&m, "9P2000.L"); mend(&m); fake_reply(m.b, m.n);
    rc = p9_version(&c, 8192, o_ver, sizeof o_ver);
    check(rc == 0 && c.msize == 8192, "Rversion msize 65536 for a request of 8192: msize 8192 (got %u)", c.msize);
    client_reset(8192);
    mbegin(&m, 101, 0xffff); m32(&m, 4096); mstr(&m, "9P2000.L"); mend(&m); fake_reply(m.b, m.n);
    rc = p9_version(&c, 8192, o_ver, sizeof o_ver);
    check(rc == 0 && c.msize == 4096, "Rversion msize 4096 for a request of 8192: msize 4096 (got %u)", c.msize);
    /* Tread count is limited to msize - 24 */
    client_reset(4096);
    mbegin(&m, 117, 0); m32(&m, 0); mend(&m); fake_reply(m.b, m.n);
    rc = p9_read(&c, 2, 0, o_buf, 100000);
    check(rc == 0 && le32(fake_last_req + 19) == 4096 - P9_IOHDRSZ, "Tread of 100000 bytes with msize 4096: count field %u", le32(fake_last_req + 19));
    /* a request that does not fit into msize is not sent */
    client_reset(64);
    char longname[201]; memset(longname, 'x', 200); longname[200] = 0;
    rc = p9_mkdir(&c, 1, longname, 0755, 100, NULL);
    check(rc == -ENAMETOOLONG && fake_nreq == 0, "Tmkdir with a 200-byte name and msize 64: -ENAMETOOLONG, nothing sent (got %ld)", rc);
    /* fid pool */
    client_reset(8192);
    uint32_t f1 = p9_fid_alloc(&c), f2 = p9_fid_alloc(&c), f3 = p9_fid_alloc(&c);
    p9_fid_release(&c, f2);
    uint32_t f4 = p9_fid_alloc(&c), f5 = p9_fid_alloc(&c);
    p9_fid_release(&c, P9_NOFID);
    check(f1 == 1 && f2 == 2 && f3 == 3 && f4 == 2 && f5 == 4 && c.fid_nfree == 0,
          "fid pool: 1, 2, 3; 2 released and given out again; then 4; P9_NOFID is not taken back");
    free(c.fid_free); c.fid_free = NULL;
}

int main(void)
{
    fake_init(&q, 16384);
    printf("== 1. requests: bytes of each T-message\n");          test_requests();
    printf("== 2. valid replies: decoded fields\n");               test_valid_replies();
    printf("== 3. malformed replies\n");                           test_malformed();
    printf("== 4. truncated replies: every proper prefix of each valid body\n"); test_prefixes();
    printf("== 5. walks of more than 16 names, msize, long requests, fid pool\n"); test_misc();
    fake_free(&q);
    free(c.fid_free);
    printf("p9_test: %d checks, %d failures\n", n_checks, n_fail);
    printf("RESULT: 9P codec table test %s\n", n_fail ? "FAILED" : "passed");
    return n_fail ? 1 : 0;
}
