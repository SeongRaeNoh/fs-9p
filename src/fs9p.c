/*
 * fs9p.c - fs-9p: a QNX 8.0 resource manager that mounts a QEMU host folder (virtio-9p PCI device,
 * protocol 9P2000.L) at a path in the QNX namespace (default /mnt/host).
 *
 * Structure:
 *   virtio_pci.c  find and set up the PCI device (legacy or virtio 1.x interface)
 *   virtq.c       one split virtqueue, several requests in flight, interrupt thread
 *   p9.c          9P2000.L messages
 *   fs9p.c        this file: the resource manager (iofunc layer, thread pool)
 *
 * Model: every open() walks a new 9P fid from the root fid to the path and binds it to the OCB;
 * every OCB has its own attribute structure ("node"), filled from Tgetattr. close() clunks the fid.
 * Directory reads translate Rreaddir entries into struct dirent records. Symbolic links are read
 * with Treadlink and followed by a redirect of the connect message (see "symbolic links" below);
 * statvfs() is answered from Tstatfs.
 *
 * QNX API facts from the public QNX 8.0 documentation ("Writing a Resource Manager", C Library
 * Reference). Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <dirent.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/procmgr.h>
#include <sys/statvfs.h>
#include <sys/dcmd_blk.h>
#include <pwd.h>
#include <grp.h>

struct fs_node;
struct fs_ocb;
#define IOFUNC_ATTR_T       struct fs_node
#define IOFUNC_OCB_T        struct fs_ocb
#define THREAD_POOL_PARAM_T dispatch_context_t
#include <sys/iofunc.h>
#include <sys/dispatch.h>

#include "virtio_pci.h"
#include "virtq.h"
#include "p9.h"
#include "p9_errno.h"

#define FS9P_VERSION "0.10.0"

struct fs_node {
    iofunc_attr_t attr;          /* must be first */
    struct fs_node *next;        /* list of all nodes (for the deferred free) */
    uint64_t idle_since_ns;      /* 0 while an OCB uses the node */
    uint32_t live_fid;           /* fid of an open OCB of this node, or P9_NOFID; see ocb_calloc() */
};

struct fs_ocb {
    iofunc_ocb_t hdr;            /* must be first */
    uint32_t fid;                /* walked fid; Tlopen'ed if opened != 0 */
    int opened;
    uint32_t iounit;
};

#define OCB_NODE(o) ((struct fs_node *)(void *)(o)->hdr.attr)

static struct {
    const char *mountpoint;
    enum vtp_mode mode;
    const char *tag;             /* select device by mount tag; NULL = first device */
    uint32_t msize;
    unsigned slots;
    int use_irq;
    int verbose;
    int daemonize;
    unsigned max_read;           /* largest reply of one read(), bytes */
    int readonly;
    int irq_prio;                /* -i: base priority of the interrupt thread */
    const char *run_as;          /* -U: user to switch to after setup; NULL = stay root */
    int irq_fixed;               /* -f: keep the interrupt thread at -i (no priority following) */
    int no_slot_pi;              /* -w: no priority inheritance through the request slots */
    int drop_prio_ability;       /* -P: with -U, do not keep the priority ability */
} opt = { "/mnt/host", VTP_AUTO, NULL, 131072 + 4096, 16, 1, 0, 0, 1u << 20, 0, 21, NULL, 0, 0, 0 };

static struct vtp_dev g_dev;
static struct virtq g_vq;
static struct p9_client g_p9;
static iofunc_mount_t g_mount;
static iofunc_funcs_t g_ocb_funcs;
static struct fs_node g_root;
static pthread_mutex_t g_nodes_lk = PTHREAD_MUTEX_INITIALIZER;
static struct fs_node *g_nodes;
static unsigned g_nnodes;

static void logv(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
}
#define VLOG(lvl, ...) do { if (opt.verbose >= (lvl)) logv(__VA_ARGS__); } while (0)

/* ---------- nodes ---------- */

static mode_t qnx_mode_from_linux(uint32_t m)
{
    mode_t t;
    switch (m & P9_S_IFMT) {
    case P9_S_IFDIR:  t = S_IFDIR; break;
    case P9_S_IFREG:  t = S_IFREG; break;
    case P9_S_IFLNK:  t = S_IFLNK; break;
    case P9_S_IFCHR:  t = S_IFCHR; break;
    case P9_S_IFBLK:  t = S_IFBLK; break;
    case P9_S_IFIFO:  t = S_IFIFO; break;
    case P9_S_IFSOCK: t = S_IFSOCK; break;
    default:          t = S_IFREG; break;
    }
    return t | (m & 07777);
}

static void node_fill(struct fs_node *n, const struct p9_attr *a)
{
    n->attr.mode = qnx_mode_from_linux(a->mode);
    n->attr.uid = a->uid;
    n->attr.gid = a->gid;
    n->attr.nbytes = a->size;
    n->attr.inode = a->qid.path ? a->qid.path : 1;
    n->attr.nlink = a->nlink;
    n->attr.atime = a->atime_sec;
    n->attr.mtime = a->mtime_sec;
    n->attr.ctime = a->ctime_sec;
    n->attr.flags &= ~(IOFUNC_ATTR_ATIME | IOFUNC_ATTR_MTIME | IOFUNC_ATTR_CTIME);
}

/* Free nodes that no OCB has used for at least 2 s. The delay keeps a node alive while the
 * resource manager library may still touch it right after a close. */
static void nodes_sweep_locked(void)
{
    uint64_t now = vq_now_ns();
    struct fs_node **pp = &g_nodes;
    while (*pp) {
        struct fs_node *n = *pp;
        if (n->idle_since_ns && now - n->idle_since_ns > 2000000000ull && n->attr.count == 0) {
            *pp = n->next; g_nnodes--; free(n);
        } else pp = &n->next;
    }
}

static struct fs_node *node_new(const struct p9_attr *a)
{
    struct fs_node *n = calloc(1, sizeof *n);
    if (!n) return NULL;
    iofunc_attr_init((void *)n, qnx_mode_from_linux(a->mode), NULL, NULL);
    n->attr.mount = &g_mount;
    n->live_fid = P9_NOFID;
    node_fill(n, a);
    pthread_mutex_lock(&g_nodes_lk);
    if (g_nnodes > 64) nodes_sweep_locked();
    n->next = g_nodes; g_nodes = n; g_nnodes++;
    pthread_mutex_unlock(&g_nodes_lk);
    return n;
}

static void node_release(struct fs_node *n)
{
    pthread_mutex_lock(&g_nodes_lk);
    n->idle_since_ns = vq_now_ns();
    pthread_mutex_unlock(&g_nodes_lk);
}

/* fs_open() calls this before it has a fid for the node. The library also calls it on its own to
 * make a second OCB for an open node, for example for _IO_OPENFD when a program is started from the
 * share; that OCB gets a clone of the fid of an open OCB of the node (Twalk with no names). */
static IOFUNC_OCB_T *ocb_calloc(resmgr_context_t *ctp, IOFUNC_ATTR_T *attr)
{
    (void)ctp;
    struct fs_ocb *o = calloc(1, sizeof *o);
    if (!o) return NULL;
    o->fid = P9_NOFID;
    if (attr && attr != &g_root) {
        pthread_mutex_lock(&g_nodes_lk);
        uint32_t src = attr->live_fid;
        pthread_mutex_unlock(&g_nodes_lk);
        if (src != P9_NOFID) {
            uint32_t nf = p9_fid_alloc(&g_p9);
            if (p9_walk(&g_p9, src, nf, 0, NULL, NULL) == 0) o->fid = nf; else p9_fid_release(&g_p9, nf);
            VLOG(2, "ocb_calloc: new OCB for an open node, fid %u cloned from %u\n", (unsigned)o->fid, (unsigned)src);
        }
    }
    return o;
}

static void node_set_live(struct fs_node *n, uint32_t fid)
{
    pthread_mutex_lock(&g_nodes_lk);
    n->live_fid = fid;
    pthread_mutex_unlock(&g_nodes_lk);
}

static void ocb_free(IOFUNC_OCB_T *o) { free(o); }

/* ---------- path walk ---------- */

/* Split the relative path into components (in place in buf). Returns the count or -ENAMETOOLONG. */
static int split_path(char *buf, const char **names, int max)
{
    int n = 0;
    for (char *p = buf; *p; ) {
        while (*p == '/') p++;
        if (!*p) break;
        if (n == max) return -ENAMETOOLONG;
        names[n++] = p;
        while (*p && *p != '/') p++;
        if (*p) *p++ = 0;
    }
    return n;
}

#define MAX_COMPONENTS 256

static void fid_drop(uint32_t fid) { p9_clunk(&g_p9, fid); p9_fid_release(&g_p9, fid); }

/* ---------- symbolic links ----------
 * QEMU's 9p server walks with lstat() and does not follow a symbolic link: a Twalk stops after a
 * link that is not the last name (partial Rwalk, last qid of type P9_QTSYMLINK). fs-9p then reads
 * the link with Treadlink and answers the connect message with a redirect to the new path
 * (_IO_CONNECT_RET_LINK, struct _io_connect_link_reply with nentries 0 and the path after it); the
 * client library resolves the new path from the start, so links to other file systems and link
 * loops are handled by the client (its SYMLOOP_MAX limit). The new path is absolute: a relative
 * target is joined to the mountpoint and the folder of the link, and "." and ".." are resolved
 * textually. */
#define WALK_LINK 1      /* return value: a symbolic link must be followed; *redir holds the new path */

struct pathv { char *buf; const char **names; int n; };

static int pathv_split(const char *path, struct pathv *pv)
{
    size_t len = strlen(path);
    if (len >= PATH_MAX) return -ENAMETOOLONG;
    pv->buf = malloc(len + 1);
    pv->names = malloc(MAX_COMPONENTS * sizeof *pv->names);
    if (!pv->buf || !pv->names) { free(pv->buf); free(pv->names); return -ENOMEM; }
    memcpy(pv->buf, path, len + 1);
    pv->n = split_path(pv->buf, pv->names, MAX_COMPONENTS);
    if (pv->n < 0) { int rc = pv->n; free(pv->buf); free(pv->names); return rc; }
    return 0;
}
static void pathv_free(struct pathv *pv) { free(pv->buf); free(pv->names); }

/* "mountpoint/names[0..k-1]/target/rest[0..nrest-1]" (target absolute: "target/rest..."), with "."
 * removed and ".." applied textually. Returns a malloc'ed path or NULL. */
static char *link_path(const char *const *names, int k, const char *target, const char *const *rest, int nrest)
{
    size_t cap = strlen(opt.mountpoint) + strlen(target) + 4;
    for (int i = 0; i < k; i++) cap += strlen(names[i]) + 1;
    for (int i = 0; i < nrest; i++) cap += strlen(rest[i]) + 1;
    char *raw = malloc(cap), *out = malloc(cap + 1);
    if (!raw || !out) { free(raw); free(out); return NULL; }
    raw[0] = 0;
    if (target[0] != '/') {
        strcat(raw, opt.mountpoint);
        for (int i = 0; i < k; i++) { strcat(raw, "/"); strcat(raw, names[i]); }
        strcat(raw, "/");
    }
    strcat(raw, target);
    for (int i = 0; i < nrest; i++) { strcat(raw, "/"); strcat(raw, rest[i]); }
    size_t o = 0;
    for (char *p = raw; *p; ) {
        while (*p == '/') p++;
        if (!*p) break;
        char *c = p;
        while (*p && *p != '/') p++;
        size_t l = (size_t)(p - c);
        if (l == 1 && c[0] == '.') continue;
        if (l == 2 && c[0] == '.' && c[1] == '.') { while (o > 0 && out[o - 1] != '/') o--; if (o > 0) o--; continue; }
        out[o++] = '/'; memcpy(out + o, c, l); o += l;
    }
    if (o == 0) out[o++] = '/';
    out[o] = 0;
    free(raw);
    return out;
}

/* Walk a new fid from the root one name at a time over names[0..m-1] and stop at the first symbolic
 * link. Returns its index with *fid on the link, or -1. */
static int find_link(const char *const *names, int m, uint32_t *fid)
{
    uint32_t f = p9_fid_alloc(&g_p9);
    if (p9_walk(&g_p9, g_p9.root_fid, f, 0, NULL, NULL) < 0) { p9_fid_release(&g_p9, f); return -1; }
    for (int i = 0; i < m; i++) {
        struct p9_qid q = {0};
        if (p9_walk(&g_p9, f, f, 1, names + i, &q) < 0) break;
        if (q.type & P9_QTSYMLINK) { *fid = f; return i; }
    }
    fid_drop(f);
    return -1;
}

/* Walk a new fid from the root over names[0..n-1]. Returns 0 with *fid (and *a if a != NULL);
 * WALK_LINK with *redir when a symbolic link has to be followed (a link before the last name, or the
 * last name itself when follow_last is set); or -errno. */
static int walk_names(const char *const *names, int n, int follow_last, uint32_t *fid, struct p9_attr *a, char **redir)
{
    uint32_t f = p9_fid_alloc(&g_p9);
    struct p9_qid last = {0};
    int nw = 0, k;
    int rc = p9_walk_ex(&g_p9, g_p9.root_fid, f, n, names, &last, &nw);
    if (rc == 0) {
        if (!(follow_last && n > 0 && (last.type & P9_QTSYMLINK))) {
            if (a && (rc = p9_getattr(&g_p9, f, P9_GETATTR_BASIC, a)) < 0) { fid_drop(f); return rc; }
            *fid = f;
            return 0;
        }
        k = n - 1;                                    /* the last name is a link to follow */
    } else {
        p9_fid_release(&g_p9, f);
        if (nw > 0 && nw < n && (last.type & P9_QTSYMLINK)) {
            k = nw - 1;                               /* partial Rwalk: it stopped after the link names[k] */
            f = p9_fid_alloc(&g_p9);
            if ((rc = p9_walk(&g_p9, g_p9.root_fid, f, k + 1, names, NULL)) < 0) { p9_fid_release(&g_p9, f); return rc; }
        } else if ((rc == -ENOTDIR || rc == -ELOOP) && n > 1) {
            /* QEMU 6.2 answers a walk through a link with ENOTDIR for the whole Twalk (checked in the
             * guest test); look for the link one name at a time */
            if ((k = find_link(names, n - 1, &f)) < 0) return rc;
        } else return rc;
    }
    char *t = malloc(PATH_MAX);
    rc = t ? (int)p9_readlink(&g_p9, f, t, PATH_MAX) : -ENOMEM;
    fid_drop(f);
    if (rc >= 0) {
        *redir = link_path(names, k, t, names + k + 1, n - k - 1);
        rc = *redir ? WALK_LINK : -ENOMEM;
        VLOG(2, "symbolic link \"%s\" (name %d of %d): redirect to \"%s\"\n", t, k + 1, n, *redir ? *redir : "?");
    }
    free(t);
    return rc;
}

/* Walk a new fid to the relative path. Returns 0 and *fid, WALK_LINK and *redir, or -errno. */
static int walk_path(const char *path, int follow_last, uint32_t *fid, struct p9_attr *a, char **redir)
{
    struct pathv pv;
    int rc = pathv_split(path, &pv);
    if (rc < 0) return rc;
    rc = walk_names(pv.names, pv.n, follow_last, fid, a, redir);
    pathv_free(&pv);
    return rc;
}

/* Walk a new fid to the parent folder of path (following links); copy the last component to name.
 * Returns 0, WALK_LINK and *redir, -EBUSY for the mount root itself, or -errno. */
static int walk_parent(const char *path, uint32_t *pfid, char *name, size_t namelen, char **redir)
{
    struct pathv pv;
    int rc = pathv_split(path, &pv);
    if (rc < 0) return rc;
    if (pv.n == 0) rc = -EBUSY;                       /* the mountpoint itself */
    else if (strlen(pv.names[pv.n - 1]) >= namelen) rc = -ENAMETOOLONG;
    else {
        strcpy(name, pv.names[pv.n - 1]);
        rc = walk_names(pv.names, pv.n - 1, 1, pfid, NULL, redir);
        if (rc == WALK_LINK) {                        /* add the last name to the redirect */
            char *r2 = malloc(strlen(*redir) + strlen(name) + 2);
            if (r2) sprintf(r2, "%s%s%s", *redir, strcmp(*redir, "/") ? "/" : "", name);
            free(*redir); *redir = r2;
            if (!r2) rc = -ENOMEM;
        }
    }
    pathv_free(&pv);
    return rc;
}

/* Reply to a connect message with a path after struct _io_connect_link_reply: a redirect
 * (redirect != 0, status _IO_CONNECT_RET_LINK) or the contents of a link for readlink(). Frees path. */
static int reply_path(resmgr_context_t *ctp, struct _io_connect *c, char *path, int redirect)
{
    struct _io_connect_link_reply *r = (struct _io_connect_link_reply *)(void *)c;
    uint32_t ftype = c->file_type; uint8_t eflag = c->eflag;
    size_t room = c->reply_max, len = strlen(path) + 1;
    if (room > ctp->msg_max_size) room = ctp->msg_max_size;
    room = room > sizeof *r ? room - sizeof *r : 0;
    if (len > room) {
        if (redirect || room == 0) { free(path); return ENAMETOOLONG; }
        len = room;                                   /* readlink(): the client's buffer is smaller */
    }
    memset(r, 0, sizeof *r);
    r->file_type = ftype;
    r->eflag = eflag;
    r->nentries = 0;
    r->path_len = (uint16_t)len;
    memcpy(r + 1, path, len);
    free(path);
    if (redirect) _IO_SET_CONNECT_RET(ctp, _IO_CONNECT_RET_LINK);
    return _RESMGR_PTR(ctp, r, sizeof *r + len);
}


/* QNX open flags (ioflag of _IO_CONNECT) to 9P2000.L Tlopen/Tlcreate flags */
static uint32_t dotl_flags(uint32_t ioflag)
{
    uint32_t f;
    int rd = (ioflag & _IO_FLAG_RD) != 0, wr = (ioflag & _IO_FLAG_WR) != 0;
    f = rd && wr ? P9_DOTL_RDWR : wr ? P9_DOTL_WRONLY : P9_DOTL_RDONLY;
    if (ioflag & O_TRUNC) f |= P9_DOTL_TRUNC;
    if (ioflag & O_APPEND) f |= P9_DOTL_APPEND;
    return f;
}

/* ---------- connect handlers ---------- */

static int fs_open(resmgr_context_t *ctp, io_open_t *msg, RESMGR_HANDLE_T *handle, void *extra)
{
    (void)handle; (void)extra;
    uint32_t ioflag = msg->connect.ioflag;
    const char *path = msg->connect.path;
    VLOG(2, "open \"%s\" ioflag 0x%x subtype %u mode 0%o eflag 0x%x extra_type %u\n", path, (unsigned)ioflag,
         (unsigned)msg->connect.subtype, (unsigned)msg->connect.mode, (unsigned)msg->connect.eflag, (unsigned)msg->connect.extra_type);
    /* A symbolic link as the last name is followed, unless the client asks for the link itself
     * (S_IFLNK in the mode of the connect message). */
    int follow = !S_ISLNK(msg->connect.mode);
    char *redir = NULL;

    int wants_write = (ioflag & _IO_FLAG_WR) || (ioflag & (O_TRUNC | O_CREAT));
    if (opt.readonly && wants_write) {
        uint32_t f; struct p9_attr a;
        int rc = walk_path(path, follow, &f, &a, &redir);
        if (rc == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
        if (rc == 0) { fid_drop(f); return (ioflag & O_CREAT) && (ioflag & O_EXCL) ? EEXIST : EROFS; }
        return (ioflag & O_CREAT) ? EROFS : -rc;
    }

    uint32_t fid; struct p9_attr a;
    int rc = walk_path(path, follow, &fid, &a, &redir);
    if (rc == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
    if (rc == 0 && (ioflag & O_CREAT) && (ioflag & O_EXCL)) { fid_drop(fid); return EEXIST; }
    if (rc == -ENOENT && (ioflag & O_CREAT)) {
        /* create: Tlcreate on a fid of the parent folder turns that fid into the open new file */
        char name[NAME_MAX + 1];
        if ((rc = walk_parent(path, &fid, name, sizeof name, &redir)) == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
        if (rc < 0) return -rc;
        uint32_t iounit = 0;
        rc = p9_lcreate(&g_p9, fid, name, dotl_flags(ioflag) | P9_DOTL_CREATE, msg->connect.mode & 07777, 0, NULL, &iounit);
        if (rc == 0) rc = p9_getattr(&g_p9, fid, P9_GETATTR_BASIC, &a);
        if (rc < 0) { fid_drop(fid); return -rc; }
        struct fs_node *node = node_new(&a);
        struct fs_ocb *ocb = node ? ocb_calloc(ctp, node) : NULL;
        if (!node || !ocb) { fid_drop(fid); free(ocb); if (node) node_release(node); return ENOMEM; }
        ocb->fid = fid; ocb->opened = 1; ocb->iounit = iounit;
        /* no iofunc_open() here: it would report EEXIST for O_EXCL because the node now exists */
        if ((rc = iofunc_ocb_attach(ctp, msg, (void *)ocb, (void *)node, NULL)) != EOK) { fid_drop(fid); free(ocb); node_release(node); return rc; }
        node_set_live(node, fid);
        return EOK;
    }
    if (rc < 0) return -rc;

    struct fs_node *node = node_new(&a);
    struct fs_ocb *ocb = node ? ocb_calloc(ctp, node) : NULL;
    if (!node || !ocb) { rc = ENOMEM; goto fail; }
    if ((rc = iofunc_open(ctp, msg, (void *)node, NULL, NULL)) != EOK) goto fail;
    /* the link itself (not followed): stat works; read and write do not */
    if (S_ISLNK(node->attr.mode) && (ioflag & (_IO_FLAG_RD | _IO_FLAG_WR))) { rc = ELOOP; goto fail; }

    ocb->fid = fid;     /* for reading, Tlopen happens at the first read, so stat() needs no open on the host */
    if (ioflag & _IO_FLAG_WR) {
        if (S_ISDIR(node->attr.mode)) { rc = EISDIR; ocb->fid = P9_NOFID; goto fail; }
        int r = p9_lopen(&g_p9, fid, dotl_flags(ioflag), NULL, &ocb->iounit);
        if (r < 0) { rc = -r; ocb->fid = P9_NOFID; goto fail; }
        ocb->opened = 1;
        if (ioflag & O_TRUNC) node->attr.nbytes = 0;
    }
    if ((rc = iofunc_ocb_attach(ctp, msg, (void *)ocb, (void *)node, NULL)) != EOK) { ocb->fid = P9_NOFID; goto fail; }
    node_set_live(node, fid);
    return EOK;

fail:
    p9_clunk(&g_p9, fid); p9_fid_release(&g_p9, fid);
    free(ocb);
    if (node) node_release(node);
    return rc;
}

static int fs_unlink(resmgr_context_t *ctp, io_unlink_t *msg, RESMGR_HANDLE_T *h, void *r)
{
    if (opt.readonly) return EROFS;
    uint32_t f; struct p9_attr a; char name[NAME_MAX + 1]; char *redir = NULL;
    int rc = walk_path(msg->connect.path, 0, &f, &a, &redir);     /* unlink() removes a link itself */
    if (rc == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
    if (rc < 0) return -rc;
    fid_drop(f);
    int isdir = (a.mode & P9_S_IFMT) == P9_S_IFDIR;
    if (S_ISDIR(msg->connect.mode) && !isdir) return ENOTDIR;     /* rmdir() of a file */
    if ((rc = walk_parent(msg->connect.path, &f, name, sizeof name, &redir)) == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
    if (rc < 0) return -rc;
    rc = p9_unlinkat(&g_p9, f, name, isdir ? P9_AT_REMOVEDIR : 0);
    fid_drop(f);
    return -rc;
}

static int fs_rename(resmgr_context_t *ctp, io_rename_t *msg, RESMGR_HANDLE_T *h, io_rename_extra_t *x)
{
    if (opt.readonly) return EROFS;
    /* new name: path of the connect message (relative to the mountpoint); old name: x->path,
     * an absolute path in the namespace or a path relative to the mountpoint */
    const char *old = x->path;
    size_t ml = strlen(opt.mountpoint);
    if (old[0] == '/') {
        if (strncmp(old, opt.mountpoint, ml) != 0 || (old[ml] != '/' && old[ml] != 0)) return EXDEV;
        old += ml;
    }
    char oname[NAME_MAX + 1], nname[NAME_MAX + 1]; uint32_t of, nf; char *redir = NULL;
    /* new name below a linked folder: redirect (the library sends the rename again to the new path) */
    int rc = walk_parent(msg->connect.path, &nf, nname, sizeof nname, &redir);
    if (rc == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
    if (rc < 0) return -rc;
    /* old name below a linked folder: EXDEV, so that mv copies and removes through the link */
    if ((rc = walk_parent(old, &of, oname, sizeof oname, &redir)) == WALK_LINK) { free(redir); fid_drop(nf); return EXDEV; }
    if (rc < 0) { fid_drop(nf); return -rc; }
    rc = p9_renameat(&g_p9, of, oname, nf, nname);
    fid_drop(of); fid_drop(nf);
    return -rc;
}

static int fs_mknod(resmgr_context_t *ctp, io_mknod_t *msg, RESMGR_HANDLE_T *h, void *r)
{
    if (opt.readonly) return EROFS;
    if (!S_ISDIR(msg->connect.mode)) return ENOSYS;               /* only mkdir() */
    uint32_t f; char name[NAME_MAX + 1]; char *redir = NULL;
    int rc = walk_parent(msg->connect.path, &f, name, sizeof name, &redir);
    if (rc == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
    if (rc < 0) return rc == -EBUSY ? EEXIST : -rc;
    rc = p9_mkdir(&g_p9, f, name, msg->connect.mode & 07777, 0, NULL);
    fid_drop(f);
    return -rc;
}

/* symlink(): _IO_CONNECT_LINK with extra type _IO_CONNECT_EXTRA_SYMLINK; the target is the extra
 * data. Hard links (link()) are not supported: ENOSYS. */
static int fs_link(resmgr_context_t *ctp, io_link_t *msg, RESMGR_HANDLE_T *h, io_link_extra_t *x)
{
    (void)h;
    if (opt.readonly) return EROFS;
    VLOG(2, "link \"%s\" extra_type %u extra_len %u\n", msg->connect.path, (unsigned)msg->connect.extra_type, (unsigned)msg->connect.extra_len);
    if (msg->connect.extra_type != _IO_CONNECT_EXTRA_SYMLINK) return ENOSYS;
    size_t xl = msg->connect.extra_len;
    char *target = malloc(xl + 1);
    if (!target) return ENOMEM;
    memcpy(target, x->path, xl); target[xl] = 0;
    uint32_t f; char name[NAME_MAX + 1]; char *redir = NULL;
    int rc = walk_parent(msg->connect.path, &f, name, sizeof name, &redir);
    if (rc == WALK_LINK) { free(target); return reply_path(ctp, &msg->connect, redir, 1); }
    if (rc < 0) { free(target); return rc == -EBUSY ? EEXIST : -rc; }
    rc = p9_symlink(&g_p9, f, name, target, 0, NULL);
    fid_drop(f); free(target);
    return -rc;
}

/* readlink(): the contents of the link after struct _io_connect_link_reply; a link in an earlier
 * name of the path is followed with a redirect. */
static int fs_readlink(resmgr_context_t *ctp, io_readlink_t *msg, RESMGR_HANDLE_T *h, void *reserved)
{
    (void)h; (void)reserved;
    uint32_t f; struct p9_attr a; char *redir = NULL;
    int rc = walk_path(msg->connect.path, 0, &f, &a, &redir);
    if (rc == WALK_LINK) return reply_path(ctp, &msg->connect, redir, 1);
    if (rc < 0) return -rc;
    if ((a.mode & P9_S_IFMT) != P9_S_IFLNK) { fid_drop(f); return EINVAL; }
    char *t = malloc(PATH_MAX);
    rc = t ? (int)p9_readlink(&g_p9, f, t, PATH_MAX) : -ENOMEM;
    fid_drop(f);
    if (rc < 0) { free(t); return -rc; }
    return reply_path(ctp, &msg->connect, t, 0);
}

/* ---------- I/O handlers ---------- */

static int read_dir(resmgr_context_t *ctp, io_read_t *msg, struct fs_ocb *ocb)
{
    size_t cap = msg->i.nbytes;
    if (cap > 65536) cap = 65536;
    uint32_t rawcap = (uint32_t)cap;
    if (rawcap > g_p9.msize - P9_READDIRHDRSZ) rawcap = g_p9.msize - P9_READDIRHDRSZ;
    uint8_t *out = malloc(cap ? cap : 1), *raw = malloc(rawcap ? rawcap : 1);
    if (!out || !raw) { free(out); free(raw); return ENOMEM; }

    uint64_t off = (uint64_t)ocb->hdr.offset;
    size_t used = 0;
    ssize_t n = p9_readdir(&g_p9, ocb->fid, off, raw, rawcap);
    if (n < 0) { free(out); free(raw); return (int)-n; }
    size_t pos = 0; struct p9_dirent e; int r;
    while ((r = p9_dirent_next(raw, (size_t)n, &pos, &e)) == 1) {
        size_t reclen = offsetof(struct dirent, d_name) + e.namelen + 1;
        reclen = (reclen + 7) & ~(size_t)7;
        if (used + reclen > cap) break;          /* rest is fetched again on the next call */
        struct dirent *d = (struct dirent *)(void *)(out + used);
        memset(d, 0, reclen);
        d->d_ino = e.qid.path ? e.qid.path : 1;
        d->d_offset = (off_t)e.offset;
        d->d_reclen = (int16_t)reclen;
        d->d_namelen = (int16_t)e.namelen;
        memcpy(d->d_name, e.name, e.namelen);
        used += reclen;
        off = e.offset;
    }
    free(raw);
    if (r < 0) { free(out); return EIO; }
    if (used == 0 && n > 0) { free(out); return EMSGSIZE; }   /* client buffer smaller than one entry */
    ocb->hdr.offset = (off_t)off;
    _IO_SET_READ_NBYTES(ctp, used);
    MsgReply(ctp->rcvid, (long)used, out, used);
    free(out);
    return _RESMGR_NOREPLY;
}

static int fs_read(resmgr_context_t *ctp, io_read_t *msg, RESMGR_OCB_T *ocb)
{
    int nonblock, rc;
    if ((rc = iofunc_read_verify(ctp, msg, (void *)ocb, &nonblock)) != EOK) return rc;
    struct fs_node *node = OCB_NODE(ocb);
    if (ocb->fid == P9_NOFID) return EBADF;
    if (!ocb->opened) {
        uint32_t fl = P9_DOTL_RDONLY | (S_ISDIR(node->attr.mode) ? P9_DOTL_DIRECTORY : 0);
        int r = p9_lopen(&g_p9, ocb->fid, fl, NULL, &ocb->iounit);
        if (r < 0) return -r;
        ocb->opened = 1;
    }
    int xtype = msg->i.xtype & _IO_XTYPE_MASK;

    if (S_ISDIR(node->attr.mode)) {
        if (xtype != _IO_XTYPE_NONE && xtype != _IO_XTYPE_READDIR) return ENOSYS;
        return read_dir(ctp, msg, ocb);
    }

    off_t start; int pread_ = 0;
    if (xtype == _IO_XTYPE_OFFSET) {
        struct _xtype_offset *xo = (struct _xtype_offset *)(void *)(&msg->i + 1);
        start = xo->offset; pread_ = 1;
    } else if (xtype == _IO_XTYPE_NONE) {
        start = ocb->hdr.offset;
    } else return ENOSYS;

    size_t want = msg->i.nbytes;
    if (want > opt.max_read) want = opt.max_read;
    if (want == 0) { _IO_SET_READ_NBYTES(ctp, 0); return _RESMGR_NPARTS(0); }
    uint8_t *buf = malloc(want);
    if (!buf) return ENOMEM;
    size_t got = 0;
    uint32_t chunk = g_p9.msize - P9_IOHDRSZ;
    while (got < want) {
        uint32_t ask = (want - got) > chunk ? chunk : (uint32_t)(want - got);
        ssize_t n = p9_read(&g_p9, ocb->fid, (uint64_t)start + got, buf + got, ask);
        if (n < 0) { if (got == 0) { free(buf); return (int)-n; } break; }
        got += (size_t)n;
        if ((uint32_t)n < ask) break;            /* end of file */
    }
    if (!pread_) ocb->hdr.offset = start + (off_t)got;
    _IO_SET_READ_NBYTES(ctp, got);
    MsgReply(ctp->rcvid, (long)got, buf, got);
    free(buf);
    return _RESMGR_NOREPLY;
}

static int fs_stat(resmgr_context_t *ctp, io_stat_t *msg, RESMGR_OCB_T *ocb)
{
    struct fs_node *node = OCB_NODE(ocb);
    struct p9_attr a;
    if (ocb->fid != P9_NOFID && p9_getattr(&g_p9, ocb->fid, P9_GETATTR_BASIC, &a) == 0) node_fill(node, &a);
    iofunc_stat(ctp, (void *)node, &msg->o);
    return _RESMGR_PTR(ctp, &msg->o, sizeof msg->o);
}

static int fs_close_ocb(resmgr_context_t *ctp, void *reserved, RESMGR_OCB_T *ocb)
{
    struct fs_node *node = OCB_NODE(ocb);
    if (ocb->fid != P9_NOFID) {
        pthread_mutex_lock(&g_nodes_lk);
        if (node->live_fid == ocb->fid) node->live_fid = P9_NOFID;
        pthread_mutex_unlock(&g_nodes_lk);
        p9_clunk(&g_p9, ocb->fid);
        p9_fid_release(&g_p9, ocb->fid);
        ocb->fid = P9_NOFID;
    }
    int rc = iofunc_close_ocb_default(ctp, reserved, (void *)ocb);
    node_release(node);
    return rc;
}

static int fs_write(resmgr_context_t *ctp, io_write_t *msg, RESMGR_OCB_T *ocb)
{
    int nonblock, rc;
    if (opt.readonly) return EROFS;
    if ((rc = iofunc_write_verify(ctp, msg, (void *)ocb, &nonblock)) != EOK) return rc;
    if (ocb->fid == P9_NOFID) return EBADF;
    if (!ocb->opened) {     /* an OCB made by the library (see ocb_calloc()) */
        int r = p9_lopen(&g_p9, ocb->fid, dotl_flags(ocb->hdr.ioflag) & ~P9_DOTL_TRUNC, NULL, &ocb->iounit);
        if (r < 0) return -r;
        ocb->opened = 1;
    }
    struct fs_node *node = OCB_NODE(ocb);
    int xtype = msg->i.xtype & _IO_XTYPE_MASK;
    size_t hdr = sizeof msg->i;
    off_t start;
    int pwrite_ = 0;
    if (xtype == _IO_XTYPE_OFFSET) {
        struct _xtype_offset *xo = (struct _xtype_offset *)(void *)(&msg->i + 1);
        start = xo->offset; pwrite_ = 1; hdr += sizeof *xo;
    } else if (xtype == _IO_XTYPE_NONE) {
        start = (ocb->hdr.ioflag & O_APPEND) ? (off_t)node->attr.nbytes : ocb->hdr.offset;
    } else return ENOSYS;
#ifdef _IO_WRITE_GET_NBYTES
    size_t n = _IO_WRITE_GET_NBYTES(msg);
#else
    size_t n = msg->i.nbytes;
#endif
    if (n == 0) { _IO_SET_WRITE_NBYTES(ctp, 0); return _RESMGR_NPARTS(0); }
    uint32_t chunk = g_p9.msize - P9_IOHDRSZ;
    size_t bufsz = n > (1u << 20) ? (1u << 20) : n;
    uint8_t *buf = malloc(bufsz);
    if (!buf) return ENOMEM;
    size_t done = 0;
    while (done < n) {
        size_t part = n - done > bufsz ? bufsz : n - done;
        if (resmgr_msgget(ctp, buf, part, hdr + done) != (ssize_t)part) { rc = EFAULT; break; }
        size_t pdone = 0;
        while (pdone < part) {
            uint32_t ask = part - pdone > chunk ? chunk : (uint32_t)(part - pdone);
            ssize_t w = p9_write(&g_p9, ocb->fid, (uint64_t)start + done + pdone, buf + pdone, ask);
            if (w <= 0) { rc = w < 0 ? (int)-w : EIO; break; }
            pdone += (size_t)w;
        }
        done += pdone;
        if (pdone < part) break;
    }
    free(buf);
    if (done == 0 && rc != EOK) return rc;
    if (!pwrite_) ocb->hdr.offset = start + (off_t)done;
    if ((uint64_t)start + done > (uint64_t)node->attr.nbytes) node->attr.nbytes = (uint64_t)start + done;
    _IO_SET_WRITE_NBYTES(ctp, done);
    return _RESMGR_NPARTS(0);
}

static int fs_sync(resmgr_context_t *ctp, io_sync_t *msg, RESMGR_OCB_T *ocb)
{
    if (!ocb->opened) return EOK;
    return -p9_fsync(&g_p9, ocb->fid);
}
/* Attribute changes: Tsetattr on the OCB's fid, then the node is refreshed from Tgetattr. The
 * iofunc helper runs first for the guest-side permission checks; the host applies its own rules
 * (with security_model=none, QEMU changes files with the rights of the user who runs it). */
static int setattr_ocb(struct fs_ocb *ocb, const struct p9_setattr *sa)
{
    if (ocb->fid == P9_NOFID) return EBADF;
    int rc = p9_setattr(&g_p9, ocb->fid, sa);
    struct p9_attr a;
    if (p9_getattr(&g_p9, ocb->fid, P9_GETATTR_BASIC, &a) == 0) node_fill(OCB_NODE(ocb), &a);
    return rc < 0 ? -rc : EOK;
}

static int fs_chmod(resmgr_context_t *ctp, io_chmod_t *msg, RESMGR_OCB_T *ocb)
{
    if (opt.readonly) return EROFS;
    int rc = iofunc_chmod(ctp, msg, (void *)ocb, (void *)OCB_NODE(ocb));
    if (rc != EOK) return rc;
    struct p9_setattr sa = { .valid = P9_SETATTR_MODE, .mode = (uint32_t)(msg->i.mode & 07777) };
    return setattr_ocb(ocb, &sa);
}

static int fs_chown(resmgr_context_t *ctp, io_chown_t *msg, RESMGR_OCB_T *ocb)
{
    if (opt.readonly) return EROFS;
    int rc = iofunc_chown(ctp, msg, (void *)ocb, (void *)OCB_NODE(ocb));
    if (rc != EOK) return rc;
    struct p9_setattr sa = { .valid = P9_SETATTR_CTIME, .uid = (uint32_t)-1, .gid = (uint32_t)-1 };
    if (msg->i.uid != -1) { sa.valid |= P9_SETATTR_UID; sa.uid = (uint32_t)msg->i.uid; }
    if (msg->i.gid != -1) { sa.valid |= P9_SETATTR_GID; sa.gid = (uint32_t)msg->i.gid; }
    return setattr_ocb(ocb, &sa);
}

/* _IO_UTIME (utime(): seconds) arrives in the handler "utime", _IO_UTIME64 (utimes(), utimensat():
 * seconds and nanoseconds) in the handler "utime64" (QNX documentation of resmgr_io_funcs_t). */
static int fs_utime(resmgr_context_t *ctp, io_utime_t *msg, RESMGR_OCB_T *ocb)
{
    if (opt.readonly) return EROFS;
    int rc = iofunc_utime(ctp, msg, (void *)ocb, (void *)OCB_NODE(ocb));
    if (rc != EOK) return rc;
    VLOG(2, "utime: cur_flag %d\n", (int)msg->i.cur_flag);
    /* without the *_SET bits the host uses its current time */
    struct p9_setattr sa = { .valid = P9_SETATTR_ATIME | P9_SETATTR_MTIME };
    if (!msg->i.cur_flag) {
        sa.valid |= P9_SETATTR_ATIME_SET | P9_SETATTR_MTIME_SET;
        /* _IO_UTIME carries 32-bit signed seconds (struct members _actime, _modtime); sign-extend them.
         * Times after 2038 arrive as _IO_UTIME64 (fs_utime64). */
        sa.atime_sec = (uint64_t)(int64_t)msg->i.times._actime;
        sa.mtime_sec = (uint64_t)(int64_t)msg->i.times._modtime;
    }
    return setattr_ocb(ocb, &sa);
}

static int fs_utime64(resmgr_context_t *ctp, io_utime_t *msg, RESMGR_OCB_T *ocb)
{
    if (opt.readonly) return EROFS;
    int rc = iofunc_utime(ctp, msg, (void *)ocb, (void *)OCB_NODE(ocb));
    if (rc != EOK) return rc;
    const struct _io_utime64 *m = (const struct _io_utime64 *)(const void *)msg;
    VLOG(2, "utime64: atime %lld.%09lld mtime %lld.%09lld\n",
         (long long)m->atime_s, (long long)m->atime_ns, (long long)m->mtime_s, (long long)m->mtime_ns);
    /* A time of zero means "now" (QNX documentation of iofunc_utime()); UTIME_NOW and UTIME_OMIT in
     * the nanosecond field have their POSIX meaning. Without the *_SET bit the host uses its time. */
    struct p9_setattr sa = { .valid = 0 };
    int64_t s_[2] = { m->atime_s, m->mtime_s }, ns[2] = { m->atime_ns, m->mtime_ns };
    for (int i = 0; i < 2; i++) {
        uint32_t now = i ? P9_SETATTR_MTIME : P9_SETATTR_ATIME, set = i ? P9_SETATTR_MTIME_SET : P9_SETATTR_ATIME_SET;
#ifdef UTIME_OMIT
        if (ns[i] == UTIME_OMIT) continue;
#endif
#ifdef UTIME_NOW
        if (ns[i] == UTIME_NOW) { sa.valid |= now; continue; }
#endif
        if (s_[i] == 0 && ns[i] == 0) { sa.valid |= now; continue; }
        sa.valid |= now | set;
        if (i) { sa.mtime_sec = (uint64_t)s_[i]; sa.mtime_nsec = (uint64_t)ns[i]; }
        else   { sa.atime_sec = (uint64_t)s_[i]; sa.atime_nsec = (uint64_t)ns[i]; }
    }
    if (sa.valid == 0) return EOK;
    return setattr_ocb(ocb, &sa);
}

/* _IO_SPACE (ftruncate(), truncate(), posix_fallocate()): only changes of the file size are
 * supported; freeing a range in the middle of a file returns ENOSYS. The reply is the new size. */
static int space_is_free(unsigned st)
{
#ifdef F_FREESP
    if (st == F_FREESP) return 1;
#endif
#ifdef F_FREESP64
    if (st == F_FREESP64) return 1;
#endif
    return 0;
}

static int fs_space(resmgr_context_t *ctp, io_space_t *msg, RESMGR_OCB_T *ocb)
{
    if (opt.readonly) return EROFS;
    int nonblock, rc;
    if ((rc = iofunc_space_verify(ctp, msg, (void *)ocb, &nonblock)) != EOK) return rc;
    if (ocb->fid == P9_NOFID) return EBADF;
    struct fs_node *node = OCB_NODE(ocb);
    struct p9_attr a;
    if ((rc = p9_getattr(&g_p9, ocb->fid, P9_GETATTR_BASIC, &a)) < 0) return -rc;
    node_fill(node, &a);
    int64_t size = (int64_t)a.size, base;
    switch (msg->i.whence) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = (int64_t)ocb->hdr.offset; break;
    case SEEK_END: base = size; break;
    default: return EINVAL;
    }
    int64_t start = base + (int64_t)msg->i.start, len = (int64_t)msg->i.len, nsize;
    if (start < 0 || len < 0) return EINVAL;
    if (space_is_free(msg->i.subtype)) {
        if (len != 0 && start + len < size) return ENOSYS;     /* a hole inside the file */
        nsize = start;                                          /* to end of file: new size = start */
    } else {
        nsize = start + len;                                    /* allocate or grow: never shrink */
        if (nsize < size) nsize = size;
    }
    if (nsize != size) {
        struct p9_setattr sa = { .valid = P9_SETATTR_SIZE, .size = (uint64_t)nsize };
        if ((rc = setattr_ocb(ocb, &sa)) != EOK) return rc;
    }
    msg->o = (uint64_t)node->attr.nbytes;
    return _RESMGR_PTR(ctp, &msg->o, sizeof msg->o);
}

/* statvfs() and fstatvfs(): devctl DCMD_FSYS_STATVFS with a struct __msg_statvfs (QNX 8.0 devctl
 * reference); the numbers come from Tstatfs of the host folder. */
static int fs_devctl(resmgr_context_t *ctp, io_devctl_t *msg, RESMGR_OCB_T *ocb)
{
    int rc = iofunc_devctl_default(ctp, msg, (void *)ocb);
    if (rc != _RESMGR_DEFAULT) return rc;
    if (msg->i.dcmd != DCMD_FSYS_STATVFS) return ENOSYS;
    struct p9_statfs st;
    if ((rc = p9_statfs(&g_p9, ocb->fid != P9_NOFID ? ocb->fid : g_p9.root_fid, &st)) < 0) return -rc;
    struct statvfs sv;
    memset(&sv, 0, sizeof sv);
    sv.f_bsize = st.bsize; sv.f_frsize = st.bsize;
    sv.f_blocks = st.blocks; sv.f_bfree = st.bfree; sv.f_bavail = st.bavail;
    sv.f_files = st.files; sv.f_ffree = st.ffree; sv.f_favail = st.ffree;
    sv.f_fsid = (unsigned long)st.fsid;
    strcpy(sv.f_basetype, "9p");
    sv.f_namemax = st.namelen;
#ifdef ST_RDONLY
    if (opt.readonly) sv.f_flag |= ST_RDONLY;
#endif
    struct __msg_statvfs *out = (struct __msg_statvfs *)(void *)(&msg->o + 1);
    __msg_statvfs_init(out, &sv);
    memset(&msg->o, 0, sizeof msg->o);
    msg->o.ret_val = EOK;
    msg->o.nbytes = sizeof *out;
    return _RESMGR_PTR(ctp, &msg->o, sizeof msg->o + sizeof *out);
}

/* ---------- main ---------- */

static void usage(const char *prog)
{
    fprintf(stderr,
        "fs-9p %s - mount a QEMU virtio-9p host folder (9P2000.L) on QNX 8.0\n"
        "usage: %s [-m mountpoint] [-t auto|legacy|modern] [-a mount_tag] [-s msize] [-n slots]\n"
        "          [-i priority] [-f] [-w] [-U user] [-P] [-p] [-r] [-d] [-v...]\n"
        "  -m path   mountpoint (default /mnt/host)\n"
        "  -t mode   virtio PCI interface (default auto: legacy for transitional devices)\n"
        "  -a tag    use the device whose mount tag is tag (default: first device)\n"
        "  -s bytes  9P msize to ask for (default %u)\n"
        "  -n count  request slots (default %u, at most %d)\n"
        "  -i prio   base priority of the interrupt thread (default %d; 0 = priority of fs-9p);\n"
        "            while requests are in flight, the thread runs at the priority of the\n"
        "            highest waiting client, above or below the base\n"
        "  -f        fixed: keep the interrupt thread at the base priority, and no priority\n"
        "            inheritance through the request slots (see -w)\n"
        "  -w        a client that waits for a free request slot does not raise the slot's\n"
        "            owner or the interrupt thread (the behaviour of 0.9.0; for comparison)\n"
        "  -U user   after setup, run as this user (name or uid[:gid]) with only the abilities\n"
        "            io and priority\n"
        "  -P        with -U, keep only io: clients above the maximum priority for unprivileged\n"
        "            processes (usually 63) are then served at that maximum\n"
        "  -p        poll the used ring instead of using the interrupt\n"
        "  -r        read-only mount\n"
        "  -d        run in the background once the mountpoint is ready\n"
        "  -v        more log output on stderr (repeat for more)\n",
        FS9P_VERSION, prog, opt.msize, opt.slots, VQ_MAX_SLOTS, opt.irq_prio);
}

static int setup_device(void)
{
    vtp_log_fn lg = opt.verbose >= 1 ? logv : NULL;
    int skipped = 0;
    for (int idx = 0; ; idx++) {
        int orc = vtp_open(&g_dev, idx, opt.mode, lg);
        if (orc == -2) {
            fprintf(stderr, "fs-9p: no%s virtio-9p device%s%s%s found", skipped ? " free" : "",
                    opt.tag ? " with mount tag \"" : "", opt.tag ? opt.tag : "", opt.tag ? "\"" : "");
            if (skipped) fprintf(stderr, " (%d device%s skipped: attached by another driver, or not usable)", skipped, skipped > 1 ? "s" : "");
            fputc('\n', stderr);
            return -1;
        }
        if (orc != 0) {
            /* The PCI server refuses a second owner attach, for example while another fs-9p instance
             * serves this device. The device is not reset; try the next one. */
            fprintf(stderr, "fs-9p: virtio-9p device %d is attached by another driver or not usable; skipping it\n", idx);
            vtp_close(&g_dev);
            skipped++;
            continue;
        }
        if (vtp_init(&g_dev) != 0) { vtp_close(&g_dev); return -1; }
        if (!opt.tag || strcmp(opt.tag, g_dev.tag) == 0) break;
        VLOG(1, "fs-9p: device %d has mount tag \"%s\"; skipping\n", idx, g_dev.tag);
        vtp_close(&g_dev);
    }
    int follow = opt.irq_fixed ? 0 : VQ_FOLLOW_IRQ | (opt.no_slot_pi ? 0 : VQ_FOLLOW_SLOTS);
    if (vq_init(&g_vq, &g_dev, opt.slots, opt.msize, opt.use_irq, opt.irq_prio, follow) != 0) { vtp_close(&g_dev); return -1; }
    p9_client_init(&g_p9, &g_vq, logv, opt.verbose >= 3 ? 1 : 0);
    char ver[32];
    int rc = p9_version(&g_p9, opt.msize, ver, sizeof ver);
    if (rc < 0) { fprintf(stderr, "fs-9p: Tversion failed: %s\n", strerror(-rc)); vtp_close(&g_dev); return -1; }
    struct p9_qid qid;
    rc = p9_attach(&g_p9, 0, "root", "", 0, &qid);
    if (rc < 0) { fprintf(stderr, "fs-9p: Tattach failed: %s\n", strerror(-rc)); vtp_close(&g_dev); return -1; }
    VLOG(1, "fs-9p: %s, msize %u, mount tag \"%s\", %s interface, %s\n", ver, g_p9.msize, g_dev.tag,
         g_dev.modern ? "modern" : "legacy", g_vq.use_irq ? "interrupt-driven" : "polling");
    return 0;
}

/* -U: drop root after setup (the "pre-security-policies" method of the public QNX 8.0 System
 * Security Guide, page "Process manager abilities", and the C Library Reference page of
 * procmgr_ability()). The device is attached, its registers and DMA buffers are mapped, the
 * interrupt is attached and the mountpoint is registered before this call, so the abilities
 * mem_phys, interrupt and pathspace are no longer needed. The non-root set keeps two:
 *   io        ThreadCtl(_NTO_TCTL_IO_LEVEL) in thread-pool threads that start later; the legacy
 *             interface reaches the device through I/O ports
 *   priority  serve clients whose priority is above the maximum for unprivileged processes
 *             (usually 63) at their own priority: without it, message passing boosts a pool
 *             thread only to that maximum (System Architecture guide, "Priority inheritance and
 *             messages"), and pthread_setschedprio() cannot raise the interrupt thread above it
 *             (EPERM). -P leaves this ability out.
 * Every other ability of the non-root set is denied, and all of them are locked. Then the process
 * switches to the user for good (setgid() and setuid() as root set the real, effective and saved
 * IDs). */
static int drop_privileges(const char *spec)
{
    uid_t uid; gid_t gid;
    struct passwd *pw = getpwnam(spec);
    if (pw) { uid = pw->pw_uid; gid = pw->pw_gid; }
    else {
        char *end;
        unsigned long u = strtoul(spec, &end, 10);
        if (end == spec || (*end != 0 && *end != ':')) { fprintf(stderr, "fs-9p: -U %s: no such user\n", spec); return -1; }
        uid = (uid_t)u; gid = (gid_t)u;
        if (*end == ':') gid = (gid_t)strtoul(end + 1, NULL, 10);
    }
    if (uid == 0) { fprintf(stderr, "fs-9p: -U: the user must not be root\n"); return -1; }
    int rc = procmgr_ability(0,
        PROCMGR_ADN_NONROOT | PROCMGR_AOP_ALLOW | PROCMGR_AOP_LOCK | PROCMGR_AID_IO,
        PROCMGR_ADN_NONROOT | (opt.drop_prio_ability ? PROCMGR_AOP_DENY : PROCMGR_AOP_ALLOW) | PROCMGR_AOP_LOCK | PROCMGR_AID_PRIORITY,
        PROCMGR_ADN_NONROOT | PROCMGR_AOP_DENY | PROCMGR_AOP_LOCK | PROCMGR_AID_EOL);
    if (rc != EOK) { fprintf(stderr, "fs-9p: procmgr_ability: %s\n", strerror(rc)); return -1; }
    if (setgroups(0, NULL) == -1) { perror("fs-9p: setgroups"); return -1; }
    if (setgid(gid) == -1) { perror("fs-9p: setgid"); return -1; }
    if (setuid(uid) == -1) { perror("fs-9p: setuid"); return -1; }
    fprintf(stderr, "fs-9p: running as uid %d gid %d; abilities kept for non-root: %s\n", (int)getuid(), (int)getgid(),
            opt.drop_prio_ability ? "io" : "io, priority");
    return 0;
}

int main(int argc, char **argv)
{
    int c;
    while ((c = getopt(argc, argv, "m:t:a:s:n:i:U:fwPprdvh")) != -1) {
        switch (c) {
        case 'm': opt.mountpoint = optarg; break;
        case 't': opt.mode = !strcmp(optarg, "legacy") ? VTP_LEGACY : !strcmp(optarg, "modern") ? VTP_MODERN : VTP_AUTO; break;
        case 'a': opt.tag = optarg; break;
        case 's': opt.msize = (uint32_t)strtoul(optarg, NULL, 0); if (opt.msize < 8192) opt.msize = 8192; break;
        case 'n': opt.slots = (unsigned)strtoul(optarg, NULL, 0); break;
        case 'i': opt.irq_prio = atoi(optarg); if (opt.irq_prio < 0) opt.irq_prio = 0; break;
        case 'U': opt.run_as = optarg; break;
        case 'f': opt.irq_fixed = 1; break;
        case 'w': opt.no_slot_pi = 1; break;
        case 'P': opt.drop_prio_ability = 1; break;
        case 'p': opt.use_irq = 0; break;
        case 'r': opt.readonly = 1; break;
        case 'd': opt.daemonize = 1; break;
        case 'v': opt.verbose++; break;
        default: usage(argv[0]); return c == 'h' ? 0 : 2;
        }
    }
    if (opt.mountpoint[0] != '/') { fprintf(stderr, "fs-9p: mountpoint must be an absolute path\n"); return 2; }

    /* Background mode: the parent exits with the child's setup result, so a script can use the
     * mountpoint as soon as "fs-9p -d" returns. Forked before any thread exists. */
    int ready_fd = -1;
    if (opt.daemonize) {
        int pfd[2];
        if (pipe(pfd) == -1) { perror("fs-9p: pipe"); return 1; }
        pid_t pid = fork();
        if (pid == -1) { perror("fs-9p: fork"); return 1; }
        if (pid > 0) {
            close(pfd[1]);
            char st = 1;
            if (read(pfd[0], &st, 1) != 1) st = 1;
            return st;
        }
        close(pfd[0]);
        ready_fd = pfd[1];
        setsid();
    }

    /* All threads inherit this mask; the main thread takes the signals with sigwait(). */
    sigset_t sigs;
    sigemptyset(&sigs);
    sigaddset(&sigs, SIGTERM); sigaddset(&sigs, SIGINT); sigaddset(&sigs, SIGHUP);
    pthread_sigmask(SIG_BLOCK, &sigs, NULL);
    signal(SIGPIPE, SIG_IGN);

    if (setup_device() != 0) return 1;

    dispatch_t *dpp = dispatch_create();
    if (!dpp) { perror("fs-9p: dispatch_create"); vtp_close(&g_dev); return 1; }

    static resmgr_connect_funcs_t cf;
    static resmgr_io_funcs_t iof;
    iofunc_func_init(_RESMGR_CONNECT_NFUNCS, &cf, _RESMGR_IO_NFUNCS, &iof);
    cf.open = fs_open;
    cf.unlink = fs_unlink;
    cf.rename = fs_rename;
    cf.mknod = fs_mknod;
    cf.link = fs_link;
    cf.readlink = fs_readlink;
    iof.read = fs_read;
    iof.stat = fs_stat;
    iof.close_ocb = fs_close_ocb;
    iof.write = fs_write;
    iof.sync = fs_sync;
    iof.chmod = fs_chmod;
    iof.chown = fs_chown;
    iof.utime = fs_utime;
    iof.utime64 = fs_utime64;
    iof.space = fs_space;
    iof.devctl = fs_devctl;

    memset(&g_ocb_funcs, 0, sizeof g_ocb_funcs);
    g_ocb_funcs.nfuncs = _IOFUNC_NFUNCS;
    g_ocb_funcs.ocb_calloc = ocb_calloc;
    g_ocb_funcs.ocb_free = ocb_free;
    memset(&g_mount, 0, sizeof g_mount);
    g_mount.conf = IOFUNC_PC_CHOWN_RESTRICTED | IOFUNC_PC_NO_TRUNC | IOFUNC_PC_SYNC_IO;
    g_mount.blocksize = 4096;
    g_mount.funcs = &g_ocb_funcs;

    iofunc_attr_init((void *)&g_root, S_IFDIR | 0555, NULL, NULL);
    {   /* mode, owner and times of the mount root come from the host folder (fid 0 = attach fid) */
        struct p9_attr ra9;
        if (p9_getattr(&g_p9, 0, P9_GETATTR_BASIC, &ra9) == 0) node_fill(&g_root, &ra9);
        else fprintf(stderr, "fs-9p: Tgetattr of the share root failed; root mode 0555\n");
    }
    g_root.attr.mount = &g_mount;
    g_root.attr.inode = 1;

    resmgr_attr_t ra;
    memset(&ra, 0, sizeof ra);
    ra.nparts_max = 1;
    ra.msg_max_size = 4096;
    int id = resmgr_attach(dpp, &ra, opt.mountpoint, _FTYPE_ANY, _RESMGR_FLAG_DIR, &cf, &iof, (void *)&g_root);
    if (id == -1) { perror("fs-9p: resmgr_attach"); vtp_close(&g_dev); return 1; }
    if (opt.run_as && drop_privileges(opt.run_as) != 0) { resmgr_detach(dpp, id, 0); vtp_close(&g_dev); return 1; }

    thread_pool_attr_t pa;
    memset(&pa, 0, sizeof pa);
    pa.handle = dpp;
    pa.context_alloc = dispatch_context_alloc;
    pa.block_func = dispatch_block;
    pa.unblock_func = dispatch_unblock;
    pa.handler_func = dispatch_handler;
    pa.context_free = dispatch_context_free;
    pa.lo_water = 2;
    pa.hi_water = 4;
    pa.increment = 1;
    pa.maximum = (unsigned short)(g_vq.nslots + 2);
    thread_pool_t *tp = thread_pool_create(&pa, 0);
    if (!tp || thread_pool_start(tp) == -1) { perror("fs-9p: thread pool"); resmgr_detach(dpp, id, 0); vtp_close(&g_dev); return 1; }

    char irqs[80] = "";
    if (g_vq.use_irq) snprintf(irqs, sizeof irqs, " (interrupt thread priority %d, %s)", g_vq.irq_prio,
                               g_vq.irq_follow ? "set to the highest waiting client" : "fixed");
    fprintf(stderr, "fs-9p %s: mount tag \"%s\" mounted at %s%s (9P2000.L, msize %u, %s interface, %s%s, %u request slots)\n",
            FS9P_VERSION, g_dev.tag, opt.mountpoint, opt.readonly ? " read-only" : "", g_p9.msize, g_dev.modern ? "modern" : "legacy",
            g_vq.use_irq ? "interrupt-driven" : "polling", irqs, g_vq.nslots);
    if (ready_fd >= 0) {
        char ok = 0;
        if (write(ready_fd, &ok, 1) != 1) { /* parent gone; keep running */ }
        close(ready_fd);
        int nfd = open("/dev/null", O_RDWR);
        if (nfd >= 0) { dup2(nfd, 0); dup2(nfd, 1); if (opt.verbose == 0) dup2(nfd, 2); if (nfd > 2) close(nfd); }
    }

    int sig = 0;
    sigwait(&sigs, &sig);
    {   /* a slot that is not free here, with no request in progress, would be a leak; this line comes
         * before the statistics lines, which tests and demos read as the last two lines of the log */
        unsigned sfree, sbusy, slost, sinfl;
        vq_slot_counts(&g_vq, &sfree, &sbusy, &slost, &sinfl);
        fprintf(stderr, "fs-9p: request slots at unmount: %u of %u free, %u in use, %u lost; %u requests in flight\n",
                sfree, g_vq.nslots, sbusy, slost, sinfl);
    }
    fprintf(stderr, "fs-9p: signal %d, unmounting %s (%lu 9P requests, %lu Rlerror, %lu interrupts, %lu found after unmask, %lu reaped by waiters, %lu lost, at most %u requests in flight; "
            "%lu waits for a free slot, %lu by a client above every slot owner, highest waiting %d, %lu slots handed over)\n",
            sig, opt.mountpoint, g_p9.n_rpc, g_p9.n_err, g_vq.n_irq_ours, g_vq.n_irq_late, g_vq.n_reaped_by_waiter, g_vq.n_lost, g_vq.max_inflight,
            g_vq.n_slot_wait, g_vq.n_slot_wait_above, g_vq.max_slot_wait_prio, g_vq.n_handoff);
    if (g_vq.use_irq)
        fprintf(stderr, "fs-9p: priorities: highest waiting client %d; interrupt thread base %d, raised %lu times, highest %d; set below the base %lu times, lowest %d; %lu priority changes failed%s%s\n",
                g_vq.max_client_prio, g_vq.irq_prio, g_vq.n_prio_raise, g_vq.max_irq_prio, g_vq.n_prio_below, g_vq.min_irq_prio, g_vq.n_prio_fail,
                g_vq.n_prio_fail ? ", last error " : "", g_vq.n_prio_fail ? strerror(g_vq.prio_errno) : "");
    resmgr_detach(dpp, id, _RESMGR_DETACH_ALL);
    vtp_close(&g_dev);      /* device reset: QEMU drops the 9P session and all fids */
    return 0;
}
