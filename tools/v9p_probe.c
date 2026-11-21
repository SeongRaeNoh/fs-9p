/*
 * v9p_probe.c - diagnostic tool: set up the virtio-9p PCI device with the fs-9p modules and run
 * Tversion, Tattach, a root directory listing and optionally a file read, printing each step.
 * The test script uses it to show the first Tversion/Rversion exchange with the device.
 * Run as root while fs-9p is NOT running (both would drive the same device).
 *
 * usage: v9p_probe [-m legacy|modern] [-i] [-v] [-f relative/path]
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include "../src/virtio_pci.h"
#include "../src/virtq.h"
#include "../src/p9.h"

static void logp(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); }

static void print_qid(const char *pfx, const struct p9_qid *q)
{
    printf("%s qid type=0x%02x version=%u path=0x%llx\n", pfx, q->type, q->version, (unsigned long long)q->path);
}

int main(int argc, char **argv)
{
    enum vtp_mode mode = VTP_LEGACY; int use_irq = 0, verbose = 1, c; const char *file = NULL;
    while ((c = getopt(argc, argv, "m:ivf:")) != -1) {
        if (c == 'm') mode = strcmp(optarg, "modern") == 0 ? VTP_MODERN : VTP_LEGACY;
        else if (c == 'i') use_irq = 1;
        else if (c == 'v') verbose = 2;
        else if (c == 'f') file = optarg;
        else { fprintf(stderr, "usage: %s [-m legacy|modern] [-i] [-v] [-f relative/path]\n", argv[0]); return 2; }
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("v9p_probe: interface %s, pid %d\n", mode == VTP_MODERN ? "modern" : "legacy", getpid());
    struct vtp_dev d; struct virtq q; struct p9_client p;
    if (vtp_open(&d, 0, mode, logp) != 0) return 1;
    if (vtp_init(&d) != 0) return 1;
    if (vq_init(&q, &d, 1, 8192, use_irq, 0, 0) != 0) { printf("FAIL: virtqueue setup\n"); vtp_close(&d); return 1; }
    p9_client_init(&p, &q, logp, verbose);

    char ver[32];
    int rc = p9_version(&p, 8192, ver, sizeof ver);
    if (rc < 0) { printf("RESULT: Tversion/Rversion FAILED (%s)\n", strerror(-rc)); vtp_close(&d); return 1; }
    printf("    Rversion msize=%u version=\"%s\"\n", p.msize, ver);
    printf("RESULT: Tversion/Rversion exchange completed\n");

    struct p9_qid qid;
    if ((rc = p9_attach(&p, 0, "root", "", 0, &qid)) < 0) { printf("RESULT: Tattach FAILED (%s)\n", strerror(-rc)); vtp_close(&d); return 1; }
    print_qid("    Rattach", &qid);

    printf("--- list root directory\n");
    uint32_t fid = p9_fid_alloc(&p);
    if (p9_walk(&p, 0, fid, 0, NULL, NULL) == 0 && p9_lopen(&p, fid, P9_DOTL_RDONLY, NULL, NULL) == 0) {
        static uint8_t buf[8192];
        ssize_t n = p9_readdir(&p, fid, 0, buf, sizeof buf - 64);
        size_t pos = 0; struct p9_dirent e;
        while (n > 0 && p9_dirent_next(buf, (size_t)n, &pos, &e) == 1)
            printf("    entry type=%u name=\"%.*s\" next_offset=%llu\n", e.type, e.namelen, e.name, (unsigned long long)e.offset);
        p9_clunk(&p, fid);
    }
    if (file) {
        printf("--- read %s\n", file);
        char *dup = strdup(file); const char *names[64]; int n = 0;
        for (char *t = strtok(dup, "/"); t && n < 64; t = strtok(NULL, "/")) names[n++] = t;
        uint32_t f2 = p9_fid_alloc(&p); struct p9_attr a;
        if ((rc = p9_walk(&p, 0, f2, n, names, NULL)) < 0) printf("    walk: %s\n", strerror(-rc));
        else {
            if (p9_getattr(&p, f2, P9_GETATTR_BASIC, &a) == 0)
                printf("    Rgetattr mode=0%o uid=%u gid=%u size=%llu\n", a.mode, a.uid, a.gid, (unsigned long long)a.size);
            if (p9_lopen(&p, f2, P9_DOTL_RDONLY, NULL, NULL) == 0) {
                static uint8_t buf[4096];
                ssize_t k = p9_read(&p, f2, 0, buf, 200);
                if (k >= 0) { printf("    Rread count=%zd data: \"", k); for (ssize_t i = 0; i < k; i++) putchar(buf[i] == '\n' ? '|' : buf[i]); printf("\"\n"); }
            }
            p9_clunk(&p, f2);
        }
        free(dup);
    }
    p9_clunk(&p, 0);
    if (q.use_irq) printf("IRQ: %lu interrupts, %lu with the queue bit set\n", q.n_irq, q.n_irq_ours);
    vtp_close(&d);       /* reset the device; QEMU drops the 9P session */
    printf("RESULT: done\n");
    return 0;
}
