/*
 * virtio_pci.c - virtio PCI transport (legacy and virtio 1.x) for QNX 8.0, using the QNX PCI server
 * library (libpci). API facts from the public QNX 8.0 documentation (PCI Server User's Guide,
 * C Library Reference); register layout from the OASIS virtio specification 1.2, section 4.1.
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/neutrino.h>
#include <hw/inout.h>
#include "virtio_pci.h"

/* legacy I/O BAR register offsets (spec 4.1.4.8) */
#define LEG_HOST_F      0x00
#define LEG_GUEST_F     0x04
#define LEG_Q_PFN       0x08
#define LEG_Q_SIZE      0x0c
#define LEG_Q_SEL       0x0e
#define LEG_Q_NOTIFY    0x10
#define LEG_STATUS      0x12
#define LEG_ISR         0x13
#define LEG_DEVCFG      0x14    /* device config when MSI-X is disabled */

/* modern common configuration offsets (spec 4.1.4.3) */
#define CC_DFSEL        0x00
#define CC_DF           0x04
#define CC_GFSEL        0x08
#define CC_GF           0x0c
#define CC_NUMQ         0x12
#define CC_STATUS       0x14
#define CC_QSEL         0x16
#define CC_QSIZE        0x18
#define CC_QMSIX        0x1a
#define CC_QENABLE      0x1c
#define CC_QNOFF        0x1e
#define CC_QDESC        0x20
#define CC_QDRIVER      0x28
#define CC_QDEVICE      0x30

#define LOG(d, ...) do { if ((d)->log) (d)->log(__VA_ARGS__); } while (0)

static __thread int t_io_priv;

int vtp_io_priv(void)
{
    if (t_io_priv) return 0;
    if (ThreadCtl(_NTO_TCTL_IO_LEVEL, (void *)_NTO_IO_LEVEL_1) == -1) return -1;
    t_io_priv = 1;
    return 0;
}

static inline uint8_t  cc8 (struct vtp_dev *d, int o) { return *(volatile uint8_t  *)(d->cc + o); }
static inline uint16_t cc16(struct vtp_dev *d, int o) { return *(volatile uint16_t *)(d->cc + o); }
static inline uint32_t cc32(struct vtp_dev *d, int o) { return *(volatile uint32_t *)(d->cc + o); }
static inline void wcc8 (struct vtp_dev *d, int o, uint8_t v)  { *(volatile uint8_t  *)(d->cc + o) = v; }
static inline void wcc16(struct vtp_dev *d, int o, uint16_t v) { *(volatile uint16_t *)(d->cc + o) = v; }
static inline void wcc32(struct vtp_dev *d, int o, uint32_t v) { *(volatile uint32_t *)(d->cc + o) = v; }
static inline void wcc64(struct vtp_dev *d, int o, uint64_t v) { wcc32(d, o, (uint32_t)v); wcc32(d, o + 4, (uint32_t)(v >> 32)); }

/* Walk the PCI capability list and map the virtio vendor capabilities (capability id 0x09). */
static int map_modern(struct vtp_dev *d, pci_ba_t *ba, int nba)
{
    volatile uint8_t *barmap[6] = {0};
    uint32_t notify_off = 0; int notify_bar = -1;
    uint16_t status; uint8_t ptr;
    pci_device_cfg_rd16(d->bdf, 0x06, &status);
    if (!(status & 0x10)) { LOG(d, "FAIL: no capability list\n"); return -1; }
    pci_device_cfg_rd8(d->bdf, 0x34, &ptr);
    for (int guard = 0; ptr && guard < 48; guard++) {
        uint8_t id, next, type, bar; uint32_t off, len;
        pci_device_cfg_rd8(d->bdf, ptr, &id);
        pci_device_cfg_rd8(d->bdf, ptr + 1, &next);
        if (id == 0x09) {
            pci_device_cfg_rd8(d->bdf, ptr + 3, &type);
            pci_device_cfg_rd8(d->bdf, ptr + 4, &bar);
            pci_device_cfg_rd32(d->bdf, ptr + 8, &off);
            pci_device_cfg_rd32(d->bdf, ptr + 12, &len);
            LOG(d, "PCI: virtio cap at 0x%02x cfg_type=%u bar=%u offset=0x%x length=0x%x\n", ptr, type, bar, off, len);
            if (type >= 1 && type <= 4 && bar < 6) {
                if (!barmap[bar]) {
                    int i; for (i = 0; i < nba && ba[i].bar_num != bar; i++) ;
                    if (i == nba || ba[i].type != pci_asType_e_MEM) { LOG(d, "FAIL: BAR%u not a memory BAR\n", bar); return -1; }
                    void *m = mmap_device_memory(NULL, ba[i].size, PROT_READ | PROT_WRITE | PROT_NOCACHE, 0, ba[i].addr);
                    if (m == MAP_FAILED) { LOG(d, "FAIL: mmap_device_memory: %s\n", strerror(errno)); return -1; }
                    barmap[bar] = m;
                    LOG(d, "PCI: BAR%u mapped with mmap_device_memory (0x%llx bytes)\n", bar, (unsigned long long)ba[i].size);
                }
                volatile uint8_t *p = barmap[bar] + off;
                if (type == 1) d->cc = p;
                else if (type == 2) { notify_bar = bar; notify_off = off; pci_device_cfg_rd32(d->bdf, ptr + 16, &d->notify_mult); }
                else if (type == 3) d->isr = p;
                else if (type == 4) d->dcfg = p;
            }
        }
        ptr = next;
    }
    if (!d->cc || notify_bar < 0 || !d->isr || !d->dcfg) { LOG(d, "FAIL: missing virtio capability (common/notify/isr/device)\n"); return -1; }
    d->notify = barmap[notify_bar] + notify_off;
    LOG(d, "PCI: modern interface, notify_off_multiplier=%u\n", d->notify_mult);
    return 0;
}

int vtp_open(struct vtp_dev *d, int index, enum vtp_mode mode, vtp_log_fn log)
{
    pci_err_t err;
    memset(d, 0, sizeof *d);
    d->log = log; d->irq = -1; d->index = index;
    if (vtp_io_priv() == -1) { LOG(d, "FAIL: ThreadCtl(_NTO_TCTL_IO_LEVEL): %s\n", strerror(errno)); return -1; }

    /* transitional devices first, then modern-only devices */
    int ntrans = 0;
    while (pci_device_find(ntrans, VIRTIO_VID, VIRTIO_9P_DID_TRANS, PCI_CCODE_ANY) != PCI_BDF_NONE) ntrans++;
    if (index < ntrans) { d->bdf = pci_device_find(index, VIRTIO_VID, VIRTIO_9P_DID_TRANS, PCI_CCODE_ANY); d->did = VIRTIO_9P_DID_TRANS; }
    else { d->bdf = pci_device_find(index - ntrans, VIRTIO_VID, VIRTIO_9P_DID_MODERN, PCI_CCODE_ANY); d->did = VIRTIO_9P_DID_MODERN; }
    if (d->bdf == PCI_BDF_NONE) { LOG(d, "PCI: no virtio-9p PCI device (1af4:1009 or 1af4:1049) at index %d\n", index); return -2; }
    LOG(d, "PCI: found %04x:%04x bdf=0x%x\n", VIRTIO_VID, d->did, (unsigned)d->bdf);
    d->modern = (mode == VTP_MODERN);
    if (mode == VTP_AUTO) d->modern = (d->did == VIRTIO_9P_DID_MODERN);
    if (d->did == VIRTIO_9P_DID_MODERN && !d->modern) { LOG(d, "PCI: modern-only device, switching to the modern interface\n"); d->modern = 1; }

    LOG(d, "PCI: attaching\n");
    d->hdl = pci_device_attach(d->bdf, pci_attachFlags_DEFAULT, &err);
    LOG(d, "PCI: attached (%s)\n", pci_strerror(err));
    if (d->hdl == NULL) return -1;

    pci_ba_t ba[7]; int_t nba = 7;
    err = pci_device_read_ba(d->hdl, &nba, ba, pci_reqType_e_UNSPECIFIED);
    if (err != PCI_ERR_OK) { LOG(d, "FAIL: pci_device_read_ba: %s\n", pci_strerror(err)); return -1; }
    LOG(d, "PCI: %d address spaces\n", (int)nba);
    for (int i = 0; i < nba; i++)
        LOG(d, "PCI: BAR%d %s addr=0x%llx size=0x%llx attr=0x%x\n", (int)ba[i].bar_num,
            ba[i].type == pci_asType_e_IO ? "IO " : ba[i].type == pci_asType_e_MEM ? "MEM" : "???",
            (unsigned long long)ba[i].addr, (unsigned long long)ba[i].size, (unsigned)ba[i].attr);

    pci_cmd_t cmd, cmd2;
    pci_device_read_cmd(d->bdf, &cmd);
    err = pci_device_write_cmd(d->hdl, cmd | 0x1 | 0x2 | 0x4, &cmd2);   /* I/O space, memory space, bus master */
    LOG(d, "PCI: command register 0x%04x -> 0x%04x (%s)\n", (unsigned)cmd, (unsigned)cmd2, pci_strerror(err));

    if (!d->modern) {
        int i;
        for (i = 0; i < nba && ba[i].type != pci_asType_e_IO; i++) ;
        if (i == nba) { LOG(d, "FAIL: no I/O BAR for the legacy interface; use the modern interface\n"); return -1; }
        d->iob = mmap_device_io(ba[i].size, ba[i].addr);
        if (d->iob == (uintptr_t)MAP_FAILED) { LOG(d, "FAIL: mmap_device_io: %s\n", strerror(errno)); return -1; }
        LOG(d, "PCI: legacy interface, I/O BAR%d at port 0x%llx mapped\n", (int)ba[i].bar_num, (unsigned long long)ba[i].addr);
    } else if (map_modern(d, ba, nba) != 0) {
        return -1;
    }

    pci_irq_t irq; int_t nirq = 1;
    err = pci_device_read_irq(d->hdl, &nirq, &irq);
    if (err == PCI_ERR_OK && nirq >= 1) { d->irq = (int)irq; LOG(d, "PCI: interrupt %d\n", d->irq); }
    else LOG(d, "PCI: no interrupt (%s)\n", pci_strerror(err));
    return 0;
}

uint8_t vtp_get_status(struct vtp_dev *d) { return d->modern ? cc8(d, CC_STATUS) : in8(d->iob + LEG_STATUS); }
void vtp_set_status(struct vtp_dev *d, uint8_t s) { if (d->modern) wcc8(d, CC_STATUS, s); else out8(d->iob + LEG_STATUS, s); }

void vtp_reset(struct vtp_dev *d)
{
    vtp_io_priv();
    vtp_set_status(d, 0);
    for (int i = 0; i < 1000 && vtp_get_status(d) != 0; i++) usleep(100);
}

int vtp_init(struct vtp_dev *d)
{
    uint64_t feat;
    vtp_reset(d);
    vtp_set_status(d, VIRTIO_ST_ACK);
    vtp_set_status(d, VIRTIO_ST_ACK | VIRTIO_ST_DRIVER);
    uint16_t tlen;
    if (!d->modern) {
        feat = in32(d->iob + LEG_HOST_F);
        uint32_t want = feat & (1u << VIRTIO_9P_F_MOUNT_TAG);
        out32(d->iob + LEG_GUEST_F, want);
        d->features = want;
        LOG(d, "VIRTIO: legacy host features 0x%08llx, accepted 0x%08x\n", (unsigned long long)feat, want);
        tlen = in16(d->iob + LEG_DEVCFG);
        for (int i = 0; i < tlen && i < (int)sizeof d->tag - 1; i++) d->tag[i] = in8(d->iob + LEG_DEVCFG + 2 + i);
    } else {
        wcc32(d, CC_DFSEL, 0); uint32_t lo = cc32(d, CC_DF);
        wcc32(d, CC_DFSEL, 1); uint32_t hi = cc32(d, CC_DF);
        feat = ((uint64_t)hi << 32) | lo;
        uint64_t want = feat & ((1ull << VIRTIO_9P_F_MOUNT_TAG) | (1ull << VIRTIO_F_VERSION_1));
        wcc32(d, CC_GFSEL, 0); wcc32(d, CC_GF, (uint32_t)want);
        wcc32(d, CC_GFSEL, 1); wcc32(d, CC_GF, (uint32_t)(want >> 32));
        d->features = want;
        LOG(d, "VIRTIO: modern device features 0x%016llx, accepted 0x%016llx, num_queues %u\n",
            (unsigned long long)feat, (unsigned long long)want, cc16(d, CC_NUMQ));
        vtp_set_status(d, VIRTIO_ST_ACK | VIRTIO_ST_DRIVER | VIRTIO_ST_FEATURES_OK);
        uint8_t st = vtp_get_status(d);
        if (!(st & VIRTIO_ST_FEATURES_OK)) { LOG(d, "FAIL: device did not accept features (status 0x%x)\n", st); return -1; }
        tlen = *(volatile uint16_t *)d->dcfg;
        for (int i = 0; i < tlen && i < (int)sizeof d->tag - 1; i++) d->tag[i] = d->dcfg[2 + i];
    }
    LOG(d, "VIRTIO: mount tag \"%s\" (len %u)\n", d->tag, tlen);
    return 0;
}

uint16_t vtp_queue_size(struct vtp_dev *d, uint16_t q)
{
    if (!d->modern) { out16(d->iob + LEG_Q_SEL, q); return in16(d->iob + LEG_Q_SIZE); }
    wcc16(d, CC_QSEL, q);
    return cc16(d, CC_QSIZE);
}

int vtp_queue_enable(struct vtp_dev *d, uint16_t q, uint64_t desc, uint64_t avail, uint64_t used)
{
    (void)avail; (void)used;
    if (!d->modern) {
        out16(d->iob + LEG_Q_SEL, q);
        out32(d->iob + LEG_Q_PFN, (uint32_t)(desc >> 12));
        LOG(d, "VIRTIO: legacy queue PFN 0x%llx written\n", (unsigned long long)(desc >> 12));
        return 0;
    }
    wcc16(d, CC_QSEL, q);
    wcc16(d, CC_QMSIX, 0xffff);           /* no MSI-X vector: INTx */
    wcc64(d, CC_QDESC, desc);
    wcc64(d, CC_QDRIVER, avail);
    wcc64(d, CC_QDEVICE, used);
    uint16_t noff = cc16(d, CC_QNOFF);
    d->qnotify = d->notify + (size_t)noff * d->notify_mult;
    wcc16(d, CC_QENABLE, 1);
    LOG(d, "VIRTIO: modern queue enabled, queue_notify_off %u\n", noff);
    return 0;
}

int vtp_driver_ok(struct vtp_dev *d)
{
    vtp_set_status(d, vtp_get_status(d) | VIRTIO_ST_DRIVER_OK);
    uint8_t st = vtp_get_status(d);
    LOG(d, "VIRTIO: device status 0x%02x%s\n", st, (st & VIRTIO_ST_DRIVER_OK) ? " (DRIVER_OK)" : "");
    return (st & VIRTIO_ST_FAILED) ? -1 : 0;
}

void vtp_notify(struct vtp_dev *d, uint16_t q)
{
    if (d->modern) { *(volatile uint16_t *)d->qnotify = q; return; }
    vtp_io_priv();      /* port I/O needs the privilege in every calling thread */
    out16(d->iob + LEG_Q_NOTIFY, q);
}

uint8_t vtp_read_isr(struct vtp_dev *d)
{
    if (d->modern) return d->isr[0];
    vtp_io_priv();
    return in8(d->iob + LEG_ISR);
}

void vtp_close(struct vtp_dev *d)
{
    if (!d->hdl) return;
    vtp_reset(d);
    pci_device_detach(d->hdl);
    d->hdl = NULL;
}

void *vtp_dma_alloc(struct vtp_dev *d, size_t len, uint64_t *bus)
{
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE | PROT_NOCACHE, MAP_SHARED | MAP_PHYS | MAP_ANON, NOFD, 0);
    if (p == MAP_FAILED) { LOG(d, "FAIL: mmap(MAP_PHYS|MAP_ANON, %zu): %s\n", len, strerror(errno)); return NULL; }
    off64_t off; size_t contig;
    if (mem_offset64(p, NOFD, len, &off, &contig) == -1) { LOG(d, "FAIL: mem_offset64: %s\n", strerror(errno)); munmap(p, len); return NULL; }
    if (contig < len) { LOG(d, "FAIL: DMA region not contiguous (%zu of %zu bytes)\n", contig, len); munmap(p, len); return NULL; }
    memset(p, 0, len);
    uint64_t phys = (uint64_t)off;
    /* Ask the PCI server for the inbound (device-to-memory) translation; on x86 it is identity. */
    pci_ba_t as = { .addr = phys, .size = len, .type = pci_asType_e_MEM,
                    .attr = pci_asAttr_e_INBOUND | pci_asAttr_e_CONTIG, .bar_num = -1 }, xl;
    pci_err_t err = pci_device_map_as(d->hdl, &as, &xl);
    *bus = (err == PCI_ERR_OK) ? (uint64_t)xl.addr : phys;
    LOG(d, "DMA: %zu bytes at phys 0x%llx, bus 0x%llx%s\n", len, (unsigned long long)phys, (unsigned long long)*bus,
        err == PCI_ERR_OK ? "" : " (pci_device_map_as failed; CPU address used)");
    return p;
}

void vtp_dma_free(void *p, size_t len) { if (p) munmap(p, len); }
