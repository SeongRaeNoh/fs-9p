/*
 * p9.h - 9P2000.L message codec and client calls over a virtqueue.
 *
 * Message formats: 9P2000.L as documented by the Linux kernel (Documentation/filesystems/9p.rst)
 * and the QEMU 9p server documentation; base 9P2000 messages from the Plan 9 manual, section 5.
 * All calls are thread-safe; each request uses one virtqueue slot, whose index is the 9P tag.
 * Errors are returned as negative QNX errno values (Linux values from Rlerror are mapped).
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#ifndef P9_H
#define P9_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <pthread.h>
#include "virtq.h"

/* message types */
#define P9_TLERROR     6
#define P9_RLERROR     7
#define P9_TSTATFS     8
#define P9_TLOPEN      12
#define P9_TLCREATE    14
#define P9_TSYMLINK    16
#define P9_TMKNOD      18
#define P9_TRENAME     20
#define P9_TREADLINK   22
#define P9_TGETATTR    24
#define P9_TSETATTR    26
#define P9_TXATTRWALK  30
#define P9_TREADDIR    40
#define P9_TFSYNC      50
#define P9_TLINK       70
#define P9_TMKDIR      72
#define P9_TRENAMEAT   74
#define P9_TUNLINKAT   76
#define P9_TVERSION    100
#define P9_TATTACH     104
#define P9_TFLUSH      108
#define P9_TWALK       110
#define P9_TREAD       116
#define P9_TWRITE      118
#define P9_TCLUNK      120

#define P9_QTSYMLINK   0x02     /* qid type bit of a symbolic link */
#define P9_NOTAG       0xffff
#define P9_NOFID       0xffffffffu
#define P9_MAXWELEM    16
#define P9_IOHDRSZ     24       /* reserve for Tread/Twrite headers */
#define P9_READDIRHDRSZ 24

/* 9P2000.L open flags (values of Linux x86) */
#define P9_DOTL_RDONLY    00000000
#define P9_DOTL_WRONLY    00000001
#define P9_DOTL_RDWR      00000002
#define P9_DOTL_CREATE    00000100
#define P9_DOTL_EXCL      00000200
#define P9_DOTL_TRUNC     00001000
#define P9_DOTL_APPEND    00002000
#define P9_DOTL_DIRECTORY 00200000

/* Linux st_mode type bits as carried in Rgetattr */
#define P9_S_IFMT   0170000
#define P9_S_IFSOCK 0140000
#define P9_S_IFLNK  0120000
#define P9_S_IFREG  0100000
#define P9_S_IFBLK  0060000
#define P9_S_IFDIR  0040000
#define P9_S_IFCHR  0020000
#define P9_S_IFIFO  0010000

#define P9_GETATTR_BASIC 0x7ffull
#define P9_AT_REMOVEDIR  0x200

struct p9_qid { uint8_t type; uint32_t version; uint64_t path; };

struct p9_attr {
    uint64_t valid;
    struct p9_qid qid;
    uint32_t mode, uid, gid;
    uint64_t nlink, rdev, size, blksize, blocks;
    uint64_t atime_sec, atime_nsec, mtime_sec, mtime_nsec, ctime_sec, ctime_nsec;
};

/* one directory entry decoded from Rreaddir data */
struct p9_dirent {
    struct p9_qid qid;
    uint64_t offset;     /* cookie for the next Treaddir after this entry */
    uint8_t type;        /* Linux DT_* value */
    uint16_t namelen;
    const char *name;    /* not NUL-terminated; points into the buffer */
};

typedef void (*p9_log_fn)(const char *fmt, ...);

struct p9_client {
    struct virtq *q;
    uint32_t msize;
    uint32_t root_fid;
    int verbose;                 /* 1: one line per message; 2: also hex dumps */
    p9_log_fn log;
    pthread_mutex_t fid_lk;
    uint32_t fid_next;
    uint32_t *fid_free; unsigned fid_nfree, fid_cap;
    int timeout_ms;
    unsigned long n_rpc, n_err;
};

int  p9_client_init(struct p9_client *c, struct virtq *q, p9_log_fn log, int verbose);
uint32_t p9_fid_alloc(struct p9_client *c);
void p9_fid_release(struct p9_client *c, uint32_t fid);   /* return a number to the pool (no Tclunk) */

int p9_version(struct p9_client *c, uint32_t msize, char *ver_out, size_t ver_len);
int p9_attach(struct p9_client *c, uint32_t fid, const char *uname, const char *aname, uint32_t n_uname, struct p9_qid *qid);
/* Walk n names from fid to newfid; any n (split into Twalk messages of at most 16 names).
 * On failure newfid is not valid. qid of the last element (or of fid for n == 0) in *last. */
int p9_walk(struct p9_client *c, uint32_t fid, uint32_t newfid, int n, const char *const *names, struct p9_qid *last);
/* As p9_walk; also on failure *nwalked = number of names walked before the failing one, and *last =
 * qid of the last walked name (valid if *nwalked > 0). A server that does not follow symbolic links
 * (QEMU) stops after a link that is not the last name, so the caller can find the link. */
int p9_walk_ex(struct p9_client *c, uint32_t fid, uint32_t newfid, int n, const char *const *names, struct p9_qid *last, int *nwalked);
int p9_getattr(struct p9_client *c, uint32_t fid, uint64_t mask, struct p9_attr *a);
int p9_lopen(struct p9_client *c, uint32_t fid, uint32_t flags, struct p9_qid *qid, uint32_t *iounit);
int p9_clunk(struct p9_client *c, uint32_t fid);
/* Read up to count bytes (count <= msize - P9_IOHDRSZ). Returns bytes read or -errno. */
ssize_t p9_read(struct p9_client *c, uint32_t fid, uint64_t offset, void *buf, uint32_t count);
/* Raw Rreaddir data into buf (count <= msize - P9_READDIRHDRSZ). Returns bytes or -errno. */
ssize_t p9_readdir(struct p9_client *c, uint32_t fid, uint64_t offset, void *buf, uint32_t count);
/* Decode the entry at *pos of raw readdir data of length len. Returns 1, 0 at end, -1 if malformed. */
int p9_dirent_next(const uint8_t *buf, size_t len, size_t *pos, struct p9_dirent *e);

/* write operations */
int p9_lcreate(struct p9_client *c, uint32_t fid, const char *name, uint32_t flags, uint32_t mode, uint32_t gid, struct p9_qid *qid, uint32_t *iounit);
ssize_t p9_write(struct p9_client *c, uint32_t fid, uint64_t offset, const void *buf, uint32_t count);
int p9_mkdir(struct p9_client *c, uint32_t dfid, const char *name, uint32_t mode, uint32_t gid, struct p9_qid *qid);
int p9_unlinkat(struct p9_client *c, uint32_t dfid, const char *name, uint32_t flags);
int p9_renameat(struct p9_client *c, uint32_t olddfid, const char *oldname, uint32_t newdfid, const char *newname);
int p9_fsync(struct p9_client *c, uint32_t fid);
/* symbolic links: Treadlink copies the target into buf (NUL-terminated); returns its length or -errno */
ssize_t p9_readlink(struct p9_client *c, uint32_t fid, char *buf, size_t len);
int p9_symlink(struct p9_client *c, uint32_t dfid, const char *name, const char *target, uint32_t gid, struct p9_qid *qid);
/* Tstatfs: file-system statistics of the host folder (Linux statfs fields) */
struct p9_statfs {
    uint32_t type, bsize;
    uint64_t blocks, bfree, bavail, files, ffree, fsid;
    uint32_t namelen;
};
int p9_statfs(struct p9_client *c, uint32_t fid, struct p9_statfs *st);

/* Tsetattr: valid bits (Linux P9_ATTR_* values) say which fields apply. ATIME or MTIME without the
 * matching *_SET bit sets that time to the server's current time. uid or gid (uint32_t)-1: unchanged. */
#define P9_SETATTR_MODE      0x001u
#define P9_SETATTR_UID       0x002u
#define P9_SETATTR_GID       0x004u
#define P9_SETATTR_SIZE      0x008u
#define P9_SETATTR_ATIME     0x010u
#define P9_SETATTR_MTIME     0x020u
#define P9_SETATTR_CTIME     0x040u
#define P9_SETATTR_ATIME_SET 0x080u
#define P9_SETATTR_MTIME_SET 0x100u
struct p9_setattr {
    uint32_t valid, mode, uid, gid;
    uint64_t size, atime_sec, atime_nsec, mtime_sec, mtime_nsec;
};
int p9_setattr(struct p9_client *c, uint32_t fid, const struct p9_setattr *a);

const char *p9_type_name(int type);

#endif
