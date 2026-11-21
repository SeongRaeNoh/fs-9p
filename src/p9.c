/*
 * p9.c - 9P2000.L codec and client calls (see p9.h).
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "p9.h"
#include "p9_errno.h"

#define LOG(c, ...) do { if ((c)->log) (c)->log(__VA_ARGS__); } while (0)

/* ---------- writer ---------- */
struct wmsg { uint8_t *b; uint32_t cap, pos; int err; uint8_t type; };

static void w8(struct wmsg *m, uint8_t v) { if (m->pos + 1 > m->cap) { m->err = 1; return; } m->b[m->pos++] = v; }
static void w16(struct wmsg *m, uint16_t v) { w8(m, v); w8(m, v >> 8); }
static void w32(struct wmsg *m, uint32_t v) { w16(m, v); w16(m, v >> 16); }
static void w64(struct wmsg *m, uint64_t v) { w32(m, v); w32(m, v >> 32); }
static void wbytes(struct wmsg *m, const void *p, uint32_t n)
{
    if (m->pos + n > m->cap) { m->err = 1; return; }
    memcpy(m->b + m->pos, p, n); m->pos += n;
}
static void wstr(struct wmsg *m, const char *s)
{
    size_t n = strlen(s);
    if (n > 0xffff) { m->err = 1; return; }
    w16(m, (uint16_t)n); wbytes(m, s, (uint32_t)n);
}
static void wbegin(struct wmsg *m, struct vq_slot *s, uint32_t cap, uint8_t type, uint16_t tag)
{
    m->b = s->req; m->cap = cap; m->pos = 4; m->err = 0; m->type = type;
    w8(m, type); w16(m, tag);
}

/* ---------- reader ---------- */
struct rmsg { const uint8_t *b; uint32_t len, pos; int err; };

static uint8_t r8(struct rmsg *r) { if (r->pos + 1 > r->len) { r->err = 1; return 0; } return r->b[r->pos++]; }
static uint16_t r16(struct rmsg *r) { uint16_t v = r8(r); return v | (uint16_t)r8(r) << 8; }
static uint32_t r32(struct rmsg *r) { uint32_t v = r16(r); return v | (uint32_t)r16(r) << 16; }
static uint64_t r64(struct rmsg *r) { uint64_t v = r32(r); return v | (uint64_t)r32(r) << 32; }
static void rqid(struct rmsg *r, struct p9_qid *q) { q->type = r8(r); q->version = r32(r); q->path = r64(r); }
static const uint8_t *rbytes(struct rmsg *r, uint32_t n)
{
    if (n > r->len - r->pos) { r->err = 1; return NULL; }   /* pos <= len always; no 32-bit wrap */
    const uint8_t *p = r->b + r->pos; r->pos += n; return p;
}

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return p[0] | p[1] << 8; }

const char *p9_type_name(int t)
{
    switch (t) {
    case 6: return "Tlerror"; case 7: return "Rlerror";
    case 8: return "Tstatfs"; case 9: return "Rstatfs";
    case 12: return "Tlopen"; case 13: return "Rlopen";
    case 14: return "Tlcreate"; case 15: return "Rlcreate";
    case 16: return "Tsymlink"; case 17: return "Rsymlink";
    case 22: return "Treadlink"; case 23: return "Rreadlink";
    case 24: return "Tgetattr"; case 25: return "Rgetattr";
    case 26: return "Tsetattr"; case 27: return "Rsetattr";
    case 40: return "Treaddir"; case 41: return "Rreaddir";
    case 50: return "Tfsync"; case 51: return "Rfsync";
    case 72: return "Tmkdir"; case 73: return "Rmkdir";
    case 74: return "Trenameat"; case 75: return "Rrenameat";
    case 76: return "Tunlinkat"; case 77: return "Runlinkat";
    case 100: return "Tversion"; case 101: return "Rversion";
    case 104: return "Tattach"; case 105: return "Rattach";
    case 110: return "Twalk"; case 111: return "Rwalk";
    case 116: return "Tread"; case 117: return "Rread";
    case 118: return "Twrite"; case 119: return "Rwrite";
    case 120: return "Tclunk"; case 121: return "Rclunk";
    default: return "?";
    }
}

static void hexdump(struct p9_client *c, const char *pfx, const uint8_t *p, size_t n)
{
    char line[160]; size_t lim = n > 96 ? 96 : n, k = 0;
    LOG(c, "%s (%zu bytes):", pfx, n);
    for (size_t i = 0; i < lim; i++) {
        if (i % 32 == 0) { if (k) LOG(c, "%s", line); k = (size_t)snprintf(line, sizeof line, "\n    %02x", p[i]); }
        else k += (size_t)snprintf(line + k, sizeof line - k, " %02x", p[i]);
    }
    if (k) LOG(c, "%s", line);
    LOG(c, "%s\n", n > lim ? " ..." : "");
}

/* Send the message built in slot s, wait, check the reply. On success *r covers the reply body. */
static int rpc(struct p9_client *c, struct vq_slot *s, struct wmsg *m, struct rmsg *r)
{
    if (m->err) return -ENAMETOOLONG;     /* request does not fit into msize */
    uint32_t len = m->pos;
    m->b[0] = len; m->b[1] = len >> 8; m->b[2] = len >> 16; m->b[3] = len >> 24;
    const char *name = p9_type_name(m->type);
    if (c->verbose >= 2) hexdump(c, name, m->b, len);
    __atomic_add_fetch(&c->n_rpc, 1, __ATOMIC_RELAXED);
    int n = vq_submit_wait(c->q, s, len, c->timeout_ms);
    if (n < 0) { LOG(c, "9P: %s: no reply after %d ms\n", name, c->timeout_ms); return -EIO; }
    if (n < 7) { LOG(c, "9P: %s: short reply (%d bytes)\n", name, n); return -EIO; }
    uint32_t size = le32(s->rsp); uint8_t type = s->rsp[4]; uint16_t tag = le16(s->rsp + 5);
    if (c->verbose >= 1)
        LOG(c, "9P: %-9s -> %s size=%u tag=0x%04x used.len=%d\n", name, p9_type_name(type), size, tag, n);
    if (c->verbose >= 2) hexdump(c, "    reply", s->rsp, size < (uint32_t)n ? size : (uint32_t)n);
    if (size < 7 || size > (uint32_t)n) { LOG(c, "9P: %s: bad reply size %u (device wrote %d)\n", name, size, n); return -EIO; }
    r->b = s->rsp + 7; r->len = size - 7; r->pos = 0; r->err = 0;
    if (type == P9_RLERROR) {
        uint32_t ecode = r32(r);
        if (r->err) { LOG(c, "9P: %s: Rlerror without its 4-byte code\n", name); return -EIO; }
        __atomic_add_fetch(&c->n_err, 1, __ATOMIC_RELAXED);
        int e = p9_errno_to_qnx(ecode);
        if (c->verbose >= 1) LOG(c, "    Rlerror ecode=%u (Linux) -> QNX errno %d (%s)\n", ecode, e, strerror(e));
        return -e;
    }
    if (type != m->type + 1) { LOG(c, "9P: %s: unexpected reply type %u\n", name, type); return -EIO; }
    return 0;
}

int p9_client_init(struct p9_client *c, struct virtq *q, p9_log_fn log, int verbose)
{
    memset(c, 0, sizeof *c);
    c->q = q; c->log = log; c->verbose = verbose;
    c->msize = q->bufsize;
    c->root_fid = 0;
    c->fid_next = 1;
    c->timeout_ms = 30000;
    pthread_mutex_init(&c->fid_lk, NULL);
    return 0;
}

uint32_t p9_fid_alloc(struct p9_client *c)
{
    pthread_mutex_lock(&c->fid_lk);
    uint32_t f = c->fid_nfree ? c->fid_free[--c->fid_nfree] : c->fid_next++;
    pthread_mutex_unlock(&c->fid_lk);
    return f;
}

void p9_fid_release(struct p9_client *c, uint32_t fid)
{
    if (fid == P9_NOFID) return;
    pthread_mutex_lock(&c->fid_lk);
    if (c->fid_nfree == c->fid_cap) {
        unsigned ncap = c->fid_cap ? 2 * c->fid_cap : 256;
        uint32_t *n = realloc(c->fid_free, ncap * sizeof *n);
        if (!n) { pthread_mutex_unlock(&c->fid_lk); return; }   /* number is lost; harmless */
        c->fid_free = n; c->fid_cap = ncap;
    }
    c->fid_free[c->fid_nfree++] = fid;
    pthread_mutex_unlock(&c->fid_lk);
}

#define BEGIN(type) \
    struct vq_slot *s = vq_get(c->q); struct wmsg m; struct rmsg r; int rc; \
    wbegin(&m, s, c->msize, (type), s->index)
#define END() vq_put(c->q, s); return rc

int p9_version(struct p9_client *c, uint32_t msize, char *ver_out, size_t ver_len)
{
    struct vq_slot *s = vq_get(c->q); struct wmsg m; struct rmsg r; int rc;
    if (msize > c->q->bufsize) msize = c->q->bufsize;
    wbegin(&m, s, c->q->bufsize, P9_TVERSION, P9_NOTAG);
    w32(&m, msize); wstr(&m, "9P2000.L");
    rc = rpc(c, s, &m, &r);
    if (rc == 0) {
        uint32_t sm = r32(&r); uint16_t vl = r16(&r); const uint8_t *v = rbytes(&r, vl);
        if (r.err) rc = -EIO;
        else {
            if (ver_out && ver_len) { size_t k = vl < ver_len - 1 ? vl : ver_len - 1; memcpy(ver_out, v, k); ver_out[k] = 0; }
            if (vl != 8 || memcmp(v, "9P2000.L", 8) != 0) rc = -EPROTO;
            if (sm < 4096) rc = -EPROTO;
            c->msize = sm < msize ? sm : msize;
        }
    }
    END();
}

int p9_attach(struct p9_client *c, uint32_t fid, const char *uname, const char *aname, uint32_t n_uname, struct p9_qid *qid)
{
    BEGIN(P9_TATTACH);
    w32(&m, fid); w32(&m, P9_NOFID); wstr(&m, uname); wstr(&m, aname); w32(&m, n_uname);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) { struct p9_qid q; rqid(&r, &q); if (r.err) rc = -EIO; else { if (qid) *qid = q; c->root_fid = fid; } }
    END();
}

/* one Twalk of at most 16 names; *nq receives nwqid */
static int walk1(struct p9_client *c, uint32_t fid, uint32_t newfid, int n, const char *const *names, int *nq, struct p9_qid *last)
{
    BEGIN(P9_TWALK);
    w32(&m, fid); w32(&m, newfid); w16(&m, (uint16_t)n);
    for (int i = 0; i < n; i++) wstr(&m, names[i]);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) {
        *nq = r16(&r);
        struct p9_qid q = {0};
        for (int i = 0; i < *nq; i++) rqid(&r, &q);
        if (r.err || *nq > n) rc = -EIO;
        else if (*nq > 0 && last) *last = q;
    }
    END();
}

int p9_walk_ex(struct p9_client *c, uint32_t fid, uint32_t newfid, int n, const char *const *names, struct p9_qid *last, int *nwalked)
{
    int done = 0, created = 0; uint32_t from = fid;
    struct p9_qid q = {0};
    if (nwalked) *nwalked = 0;
    do {
        int k = n - done > P9_MAXWELEM ? P9_MAXWELEM : n - done, nq = 0;
        int rc = walk1(c, from, newfid, k, names + done, &nq, &q);
        if (rc == 0) {                          /* a well-formed Rwalk: nq <= k */
            if (last) *last = q;
            if (nwalked) *nwalked = done + nq;
            if (nq < k) rc = -ENOENT;           /* element nq does not exist (Rwalk partial) */
        }
        if (rc < 0) { if (created) p9_clunk(c, newfid); return rc; }
        created = 1; from = newfid; done += k;
    } while (done < n);
    return 0;
}

int p9_walk(struct p9_client *c, uint32_t fid, uint32_t newfid, int n, const char *const *names, struct p9_qid *last)
{
    return p9_walk_ex(c, fid, newfid, n, names, last, NULL);
}

int p9_getattr(struct p9_client *c, uint32_t fid, uint64_t mask, struct p9_attr *a)
{
    BEGIN(P9_TGETATTR);
    w32(&m, fid); w64(&m, mask);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) {
        a->valid = r64(&r); rqid(&r, &a->qid);
        a->mode = r32(&r); a->uid = r32(&r); a->gid = r32(&r);
        a->nlink = r64(&r); a->rdev = r64(&r); a->size = r64(&r); a->blksize = r64(&r); a->blocks = r64(&r);
        a->atime_sec = r64(&r); a->atime_nsec = r64(&r);
        a->mtime_sec = r64(&r); a->mtime_nsec = r64(&r);
        a->ctime_sec = r64(&r); a->ctime_nsec = r64(&r);
        if (r.err) rc = -EIO;
    }
    END();
}

int p9_lopen(struct p9_client *c, uint32_t fid, uint32_t flags, struct p9_qid *qid, uint32_t *iounit)
{
    BEGIN(P9_TLOPEN);
    w32(&m, fid); w32(&m, flags);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) {
        struct p9_qid q; rqid(&r, &q); uint32_t io = r32(&r);
        if (r.err) rc = -EIO; else { if (qid) *qid = q; if (iounit) *iounit = io; }
    }
    END();
}

int p9_clunk(struct p9_client *c, uint32_t fid)
{
    BEGIN(P9_TCLUNK);
    w32(&m, fid);
    rc = rpc(c, s, &m, &r);
    END();
}

ssize_t p9_read(struct p9_client *c, uint32_t fid, uint64_t offset, void *buf, uint32_t count)
{
    if (count > c->msize - P9_IOHDRSZ) count = c->msize - P9_IOHDRSZ;
    BEGIN(P9_TREAD);
    w32(&m, fid); w64(&m, offset); w32(&m, count);
    rc = rpc(c, s, &m, &r);
    ssize_t ret = rc;
    if (rc == 0) {
        uint32_t n = r32(&r); const uint8_t *d = rbytes(&r, n);
        if (r.err || n > count) ret = -EIO; else { memcpy(buf, d, n); ret = n; }
    }
    vq_put(c->q, s);
    return ret;
}

ssize_t p9_readdir(struct p9_client *c, uint32_t fid, uint64_t offset, void *buf, uint32_t count)
{
    if (count > c->msize - P9_READDIRHDRSZ) count = c->msize - P9_READDIRHDRSZ;
    BEGIN(P9_TREADDIR);
    w32(&m, fid); w64(&m, offset); w32(&m, count);
    rc = rpc(c, s, &m, &r);
    ssize_t ret = rc;
    if (rc == 0) {
        uint32_t n = r32(&r); const uint8_t *d = rbytes(&r, n);
        if (r.err || n > count) ret = -EIO; else { memcpy(buf, d, n); ret = n; }
    }
    vq_put(c->q, s);
    return ret;
}

int p9_dirent_next(const uint8_t *buf, size_t len, size_t *pos, struct p9_dirent *e)
{
    if (*pos >= len) return 0;
    struct rmsg r = { buf, (uint32_t)len, (uint32_t)*pos, 0 };
    rqid(&r, &e->qid); e->offset = r64(&r); e->type = r8(&r); e->namelen = r16(&r);
    e->name = (const char *)rbytes(&r, e->namelen);
    if (r.err) return -1;
    *pos = r.pos;
    return 1;
}

int p9_lcreate(struct p9_client *c, uint32_t fid, const char *name, uint32_t flags, uint32_t mode, uint32_t gid, struct p9_qid *qid, uint32_t *iounit)
{
    BEGIN(P9_TLCREATE);
    w32(&m, fid); wstr(&m, name); w32(&m, flags); w32(&m, mode); w32(&m, gid);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) {
        struct p9_qid q; rqid(&r, &q); uint32_t io = r32(&r);
        if (r.err) rc = -EIO; else { if (qid) *qid = q; if (iounit) *iounit = io; }
    }
    END();
}

ssize_t p9_write(struct p9_client *c, uint32_t fid, uint64_t offset, const void *buf, uint32_t count)
{
    if (count > c->msize - P9_IOHDRSZ) count = c->msize - P9_IOHDRSZ;
    BEGIN(P9_TWRITE);
    w32(&m, fid); w64(&m, offset); w32(&m, count); wbytes(&m, buf, count);
    rc = rpc(c, s, &m, &r);
    ssize_t ret = rc;
    if (rc == 0) { uint32_t n = r32(&r); ret = (r.err || n > count) ? -EIO : (ssize_t)n; }
    vq_put(c->q, s);
    return ret;
}

int p9_mkdir(struct p9_client *c, uint32_t dfid, const char *name, uint32_t mode, uint32_t gid, struct p9_qid *qid)
{
    BEGIN(P9_TMKDIR);
    w32(&m, dfid); wstr(&m, name); w32(&m, mode); w32(&m, gid);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) { struct p9_qid q; rqid(&r, &q); if (r.err) rc = -EIO; else if (qid) *qid = q; }
    END();
}

int p9_unlinkat(struct p9_client *c, uint32_t dfid, const char *name, uint32_t flags)
{
    BEGIN(P9_TUNLINKAT);
    w32(&m, dfid); wstr(&m, name); w32(&m, flags);
    rc = rpc(c, s, &m, &r);
    END();
}

int p9_renameat(struct p9_client *c, uint32_t olddfid, const char *oldname, uint32_t newdfid, const char *newname)
{
    BEGIN(P9_TRENAMEAT);
    w32(&m, olddfid); wstr(&m, oldname); w32(&m, newdfid); wstr(&m, newname);
    rc = rpc(c, s, &m, &r);
    END();
}

int p9_fsync(struct p9_client *c, uint32_t fid)
{
    BEGIN(P9_TFSYNC);
    w32(&m, fid); w32(&m, 0);
    rc = rpc(c, s, &m, &r);
    END();
}

int p9_setattr(struct p9_client *c, uint32_t fid, const struct p9_setattr *a)
{
    BEGIN(P9_TSETATTR);
    w32(&m, fid); w32(&m, a->valid); w32(&m, a->mode); w32(&m, a->uid); w32(&m, a->gid); w64(&m, a->size);
    w64(&m, a->atime_sec); w64(&m, a->atime_nsec); w64(&m, a->mtime_sec); w64(&m, a->mtime_nsec);
    rc = rpc(c, s, &m, &r);
    END();
}

ssize_t p9_readlink(struct p9_client *c, uint32_t fid, char *buf, size_t len)
{
    BEGIN(P9_TREADLINK);
    w32(&m, fid);
    rc = rpc(c, s, &m, &r);
    ssize_t ret = rc;
    if (rc == 0) {
        uint16_t n = r16(&r); const uint8_t *t = rbytes(&r, n);
        if (r.err) ret = -EIO;
        else if ((size_t)n >= len) ret = -ENAMETOOLONG;
        else { memcpy(buf, t, n); buf[n] = 0; ret = n; }
    }
    vq_put(c->q, s);
    return ret;
}

int p9_symlink(struct p9_client *c, uint32_t dfid, const char *name, const char *target, uint32_t gid, struct p9_qid *qid)
{
    BEGIN(P9_TSYMLINK);
    w32(&m, dfid); wstr(&m, name); wstr(&m, target); w32(&m, gid);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) { struct p9_qid q; rqid(&r, &q); if (r.err) rc = -EIO; else if (qid) *qid = q; }
    END();
}

int p9_statfs(struct p9_client *c, uint32_t fid, struct p9_statfs *st)
{
    BEGIN(P9_TSTATFS);
    w32(&m, fid);
    rc = rpc(c, s, &m, &r);
    if (rc == 0) {
        st->type = r32(&r); st->bsize = r32(&r);
        st->blocks = r64(&r); st->bfree = r64(&r); st->bavail = r64(&r);
        st->files = r64(&r); st->ffree = r64(&r); st->fsid = r64(&r);
        st->namelen = r32(&r);
        if (r.err) rc = -EIO;
    }
    END();
}
