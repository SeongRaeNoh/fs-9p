/*
 * tests/host/p9_fuzz.c - fuzz test of the 9P2000.L reply parser in src/p9.c on a Linux host (no QNX
 * SDP; see fake_virtq.h). Every input is one reply of the fake device to one client call:
 *   byte 0      which call (version, attach, walk, lopen, lcreate, read, write, getattr, readdir,
 *               mkdir, readlink, symlink, statfs, a walk of 20 names, or the directory-entry decoder)
 *   byte 1      header flags: bit 0 keep a wrong size field, bit 1 a wrong type, bit 2 Rlerror
 *   bytes 2..   the reply body after the 7-byte header
 * The harness checks that every call returns 0, a byte count within its request, or a negative
 * errno, and that decoded directory entries stay inside their buffer. The reply buffer has exactly
 * the reply's length, so AddressSanitizer stops the run on any read past the device's bytes;
 * UndefinedBehaviorSanitizer stops it on undefined behaviour (built with -fno-sanitize-recover).
 *
 * Two ways to build it:
 *   - with the host C compiler (make host-check): main() below runs a fixed number of inputs from
 *     a seeded generator: random bodies and mutations of valid replies. Usage:
 *     p9_fuzz [-runs=N] [-seed=S]
 *   - with clang's libFuzzer (not used by the repository's scripts): define P9_LIBFUZZER and build
 *     with -fsanitize=fuzzer,address,undefined; libFuzzer then calls LLVMFuzzerTestOneInput.
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include "fake_virtq.h"
#include "../../src/p9.c"

#include <inttypes.h>

#define BUFSZ 8192

static struct virtq q;
static struct p9_client c;
static int ready;

enum { F_VERSION, F_ATTACH, F_WALK, F_LOPEN, F_LCREATE, F_READ, F_WRITE, F_GETATTR, F_READDIR,
       F_MKDIR, F_READLINK, F_SYMLINK, F_STATFS, F_WALK20, F_DIRENT, F_N };
static const char *fname[F_N] = { "version", "attach", "walk", "lopen", "lcreate", "read", "write",
    "getattr", "readdir", "mkdir", "readlink", "symlink", "statfs", "walk20", "dirent" };
static const uint8_t ftype[F_N] = { 101, 105, 111, 13, 15, 117, 119, 25, 41, 73, 23, 17, 9, 111, 0 };
static unsigned long n_ok[F_N], n_err[F_N];

static void fail(const char *what, int sel, long rc)
{
    fprintf(stderr, "p9_fuzz: invariant broken: %s (call %s, return value %ld)\n", what, fname[sel], rc);
    abort();
}

static void check_rc(int sel, long rc, long max)
{
    if (rc < -200 || rc > max) fail("return value out of range", sel, rc);
    if (rc >= 0) n_ok[sel]++; else n_err[sel]++;
}

static void check_dirents(int sel, const uint8_t *buf, size_t len)
{
    size_t pos = 0; struct p9_dirent e; int r;
    while ((r = p9_dirent_next(buf, len, &pos, &e)) == 1) {
        if (pos > len) fail("directory position past the end", sel, (long)pos);
        if ((const uint8_t *)e.name < buf || (const uint8_t *)e.name + e.namelen > buf + len)
            fail("directory entry name outside the buffer", sel, e.namelen);
    }
    if (r != 0 && r != -1) fail("p9_dirent_next returned another value", sel, r);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    static uint8_t out[BUFSZ];
    static const char *const names2[] = { "a", "b" };
    static const char *names20[20];
    if (!ready) {
        fake_init(&q, BUFSZ);
        for (int i = 0; i < 20; i++) names20[i] = "x";
        ready = 1;
    }
    if (size < 2) return 0;
    int sel = data[0] % F_N; uint8_t fl = data[1];
    const uint8_t *body = data + 2; size_t blen = size - 2;
    if (sel == F_DIRENT) { check_dirents(sel, body, blen); n_ok[sel]++; return 0; }
    if (blen > BUFSZ - 7) blen = BUFSZ - 7;

    p9_client_init(&c, &q, NULL, 0);
    c.msize = BUFSZ;
    uint8_t rep[BUFSZ];
    size_t rl = 7 + blen;
    uint32_t sz = (uint32_t)rl;
    if (fl & 1) sz = (uint32_t)(rl + (int8_t)fl / 8);        /* size field off by -16..+15 */
    uint8_t type = ftype[sel];
    if (fl & 2) type = (fl & 4) ? P9_RLERROR : (uint8_t)(fl ^ 0x5a);
    else if (fl & 4) type = P9_RLERROR;
    rep[0] = sz; rep[1] = sz >> 8; rep[2] = sz >> 16; rep[3] = sz >> 24;
    rep[4] = type; rep[5] = 0; rep[6] = 0;
    if (blen) memcpy(rep + 7, body, blen);
    fake_clear();
    if (sel == F_WALK20) {
        /* a walk of 20 names sends two Twalk messages (16 + 4 names); flag bit 3 chooses which of
         * them gets the fuzzed reply, the other gets a valid Rwalk; a Tclunk after a failed second
         * Twalk gets no answer */
        uint8_t ok[7 + 2 + 16 * 13] = { 0 };
        int nq = (fl & 8) ? 16 : 4;
        uint32_t ol = 7 + 2 + 13 * (uint32_t)nq;
        ok[0] = ol; ok[4] = 111; ok[7] = (uint8_t)nq;
        if (fl & 8) { fake_reply(ok, ol); fake_reply(rep, rl); }
        else { fake_reply(rep, rl); fake_reply(ok, ol); }
    } else {
        fake_reply(rep, rl);
    }

    struct p9_qid qid; uint32_t io; char ver[32]; struct p9_attr a; struct p9_statfs st; int nw;
    long rc;
    switch (sel) {
    case F_VERSION:  rc = p9_version(&c, BUFSZ, ver, sizeof ver); check_rc(sel, rc, 0);
                     if (rc == 0 && (c.msize < 4096 || c.msize > BUFSZ)) fail("msize outside 4096..request", sel, c.msize);
                     if (strlen(ver) >= sizeof ver) fail("version string not terminated", sel, rc);
                     break;
    case F_ATTACH:   rc = p9_attach(&c, 1, "u", "", 0, &qid); check_rc(sel, rc, 0); break;
    case F_WALK:     rc = p9_walk_ex(&c, 1, 2, 2, names2, &qid, &nw); check_rc(sel, rc, 0);
                     if (nw < 0 || nw > 2) fail("names walked outside 0..2", sel, nw);
                     break;
    case F_WALK20:   rc = p9_walk_ex(&c, 1, 2, 20, names20, &qid, &nw); check_rc(sel, rc, 0);
                     if (nw < 0 || nw > 20) fail("names walked outside 0..20", sel, nw);
                     if (rc == 0 && nw != 20) fail("walk succeeded with fewer names", sel, nw);
                     break;
    case F_LOPEN:    rc = p9_lopen(&c, 2, 0, &qid, &io); check_rc(sel, rc, 0); break;
    case F_LCREATE:  rc = p9_lcreate(&c, 2, "f", 0101, 0644, 0, &qid, &io); check_rc(sel, rc, 0); break;
    case F_READ:     rc = p9_read(&c, 2, 0, out, 1000); check_rc(sel, rc, 1000); break;
    case F_WRITE:    rc = p9_write(&c, 2, 0, "abc", 3); check_rc(sel, rc, 3); break;
    case F_GETATTR:  rc = p9_getattr(&c, 2, P9_GETATTR_BASIC, &a); check_rc(sel, rc, 0); break;
    case F_READDIR:  rc = p9_readdir(&c, 2, 0, out, 2000); check_rc(sel, rc, 2000);
                     if (rc > 0) check_dirents(sel, out, (size_t)rc);
                     break;
    case F_MKDIR:    rc = p9_mkdir(&c, 1, "d", 0755, 0, &qid); check_rc(sel, rc, 0); break;
    case F_READLINK: { char t[64]; rc = p9_readlink(&c, 2, t, sizeof t); check_rc(sel, rc, (long)sizeof t - 1);
                       if (rc >= 0 && t[rc] != 0) fail("readlink target not terminated", sel, rc);
                       break; }
    case F_SYMLINK:  rc = p9_symlink(&c, 1, "l", "t", 0, &qid); check_rc(sel, rc, 0); break;
    case F_STATFS:   rc = p9_statfs(&c, 1, &st); check_rc(sel, rc, 0); break;
    default:         break;
    }
    pthread_mutex_destroy(&c.fid_lk);
    return 0;
}

#ifndef P9_LIBFUZZER
/* ---------- seeded generator (host gcc build) ---------- */
static uint64_t rs;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 11); }

static size_t put32(uint8_t *b, size_t n, uint32_t v) { b[n] = v; b[n + 1] = v >> 8; b[n + 2] = v >> 16; b[n + 3] = v >> 24; return n + 4; }
static size_t put64(uint8_t *b, size_t n, uint64_t v) { n = put32(b, n, (uint32_t)v); return put32(b, n, (uint32_t)(v >> 32)); }
static size_t put16(uint8_t *b, size_t n, uint16_t v) { b[n] = v; b[n + 1] = v >> 8; return n + 2; }
static size_t putqid(uint8_t *b, size_t n) { b[n++] = 0; n = put32(b, n, 0); return put64(b, n, 1); }
static size_t putstr(uint8_t *b, size_t n, const char *s) { size_t k = strlen(s); n = put16(b, n, (uint16_t)k); memcpy(b + n, s, k); return n + k; }

/* a valid reply body for call sel (the starting point of mutations) */
static size_t seed_body(int sel, uint8_t *b)
{
    size_t n = 0;
    switch (sel) {
    case F_VERSION:  n = put32(b, n, 8192); n = putstr(b, n, "9P2000.L"); break;
    case F_ATTACH: case F_MKDIR: case F_SYMLINK: n = putqid(b, n); break;
    case F_WALK:     n = put16(b, n, 2); n = putqid(b, n); n = putqid(b, n); break;
    case F_WALK20:   /* the fuzzed reply answers the first Twalk (16 names) or the second (4) */
        n = put16(b, n, 16);
        for (int i = 0; i < 16; i++) n = putqid(b, n);
        break;
    case F_LOPEN: case F_LCREATE: n = putqid(b, n); n = put32(b, n, 0); break;
    case F_READ:     n = put32(b, n, 5); memcpy(b + n, "hello", 5); n += 5; break;
    case F_WRITE:    n = put32(b, n, 3); break;
    case F_GETATTR:
        n = put64(b, n, 0x7ff); n = putqid(b, n);
        for (int i = 0; i < 3; i++) n = put32(b, n, i);
        for (int i = 0; i < 11; i++) n = put64(b, n, i);
        break;
    case F_READDIR: case F_DIRENT: {
        size_t c0 = n; if (sel == F_READDIR) n = put32(b, n, 0);
        size_t s = n;
        for (int i = 0; i < 3; i++) { n = putqid(b, n); n = put64(b, n, i + 1); b[n++] = 8; n = putstr(b, n, i ? "name" : "."); }
        if (sel == F_READDIR) put32(b, c0, (uint32_t)(n - s));
        break; }
    case F_READLINK: n = putstr(b, n, "target"); break;
    case F_STATFS:
        for (int i = 0; i < 2; i++) n = put32(b, n, 4096);
        for (int i = 0; i < 6; i++) n = put64(b, n, i);
        n = put32(b, n, 255);
        break;
    default: break;
    }
    return n;
}

int main(int argc, char **argv)
{
    unsigned long runs = 100000; uint64_t seed = 1;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "-runs=", 6) == 0) runs = strtoul(argv[i] + 6, NULL, 10);
        else if (strncmp(argv[i], "-seed=", 6) == 0) seed = strtoull(argv[i] + 6, NULL, 10);
        else { fprintf(stderr, "usage: p9_fuzz [-runs=N] [-seed=S]\n"); return 2; }
    }
    rs = seed * 0x9e3779b97f4a7c15ull + 1;
    static uint8_t in[4096];
    unsigned long n_mut = 0, n_rand = 0;
    for (unsigned long r = 0; r < runs; r++) {
        int sel = rnd() % F_N;
        in[0] = (uint8_t)sel;
        in[1] = (rnd() % 4 == 0) ? (uint8_t)rnd() : (uint8_t)(rnd() & 8);   /* 3 of 4: a valid header */
        size_t n;
        if (rnd() % 4 != 0) {                                     /* 3 of 4: a mutated valid body */
            n = seed_body(sel, in + 2);
            if (sel == F_WALK20 && (in[1] & 8)) {                /* the reply to the second Twalk */
                n = put16(in + 2, 0, 4);
                for (int i = 0; i < 4; i++) n = putqid(in + 2, n);
            }
            int k = 1 + rnd() % 4;
            for (int j = 0; j < k; j++) {
                switch (rnd() % 6) {
                case 0: if (n) in[2 + rnd() % n] ^= (uint8_t)(1u << (rnd() % 8)); break;   /* flip a bit */
                case 1: if (n) in[2 + rnd() % n] = (rnd() & 1) ? 0xff : 0x00; break;       /* 0x00 or 0xff */
                case 2: if (n) n = rnd() % n; break;                                       /* cut */
                case 3: { size_t a = 1 + rnd() % 16; for (size_t t = 0; t < a && n < sizeof in - 2; t++) in[2 + n++] = (uint8_t)rnd(); break; }
                case 4: if (n >= 4) { size_t p = rnd() % (n - 3); put32(in + 2, p, rnd() % 3 == 0 ? 0xffffffffu - rnd() % 8 : rnd()); } break;
                case 5: if (n >= 2) { size_t p = rnd() % (n - 1); put16(in + 2, p, (uint16_t)rnd()); } break;
                }
            }
            n_mut++;
        } else {                                                  /* random bytes */
            n = rnd() % 300;
            for (size_t t = 0; t < n; t++) in[2 + t] = (uint8_t)rnd();
            n_rand++;
        }
        LLVMFuzzerTestOneInput(in, n + 2);
    }
    printf("p9_fuzz: %lu inputs (seed %" PRIu64 "): %lu mutated valid replies, %lu random bodies; built with AddressSanitizer and UndefinedBehaviorSanitizer\n",
           runs, seed, n_mut, n_rand);
    printf("call       accepted   rejected\n");
    for (int i = 0; i < F_N; i++) printf("%-9s %9lu  %9lu\n", fname[i], n_ok[i], n_err[i]);
    fake_free(&q);
    printf("RESULT: fuzz run passed (no sanitizer report, no broken invariant)\n");
    return 0;
}
#endif
