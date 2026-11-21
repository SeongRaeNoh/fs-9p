/*
 * virtio_pci.h - virtio PCI transport (legacy and virtio 1.x "modern" interface) for QNX 8.0.
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 * Source of the register layout: OASIS virtio specification 1.2, section 4.1.
 */
#ifndef VIRTIO_PCI_H
#define VIRTIO_PCI_H

#include <stdint.h>
#include <stddef.h>
#include <pci/pci.h>

#define VIRTIO_VID              0x1af4
#define VIRTIO_9P_DID_TRANS     0x1009
#define VIRTIO_9P_DID_MODERN    0x1049

#define VIRTIO_ST_ACK           1
#define VIRTIO_ST_DRIVER        2
#define VIRTIO_ST_DRIVER_OK     4
#define VIRTIO_ST_FEATURES_OK   8
#define VIRTIO_ST_FAILED        128

#define VIRTIO_9P_F_MOUNT_TAG   0
#define VIRTIO_F_VERSION_1      32

enum vtp_mode { VTP_AUTO = -1, VTP_LEGACY = 0, VTP_MODERN = 1 };

/* printf-like logger; NULL = silent */
typedef void (*vtp_log_fn)(const char *fmt, ...);

struct vtp_dev {
    int modern;                 /* 1: virtio 1.x interface through the memory BAR; 0: legacy I/O BAR */
    int index;                  /* index passed to pci_device_find() */
    pci_bdf_t bdf;
    pci_devhdl_t hdl;
    uint16_t did;
    uintptr_t iob;              /* legacy: mapped I/O port base */
    volatile uint8_t *cc;       /* modern: common configuration */
    volatile uint8_t *isr;      /* modern: ISR status byte */
    volatile uint8_t *dcfg;     /* modern: device-specific configuration */
    volatile uint8_t *notify;   /* modern: notify region base (BAR + offset) */
    uint32_t notify_mult;       /* modern: notify_off_multiplier */
    volatile uint8_t *qnotify;  /* modern: notify address of queue 0 */
    int irq;                    /* legacy INTx number from the PCI server, -1 if none */
    uint64_t features;          /* accepted feature bits */
    char tag[256];              /* virtio-9p mount tag */
    vtp_log_fn log;
};

/* Request I/O privilege for the calling thread (needed by libpci on x86_64 and for legacy port I/O).
 * Safe to call many times; returns 0 or -1. */
int vtp_io_priv(void);

/* Find, attach and map the index-th virtio-9p PCI function (index counts transitional devices first,
 * then modern-only devices). mode selects the interface. The PCI attach is an owner attach, which the
 * PCI server refuses while another process owns the device. Returns 0, -2 if there is no device at
 * this index, or -1 if the attach or the mapping failed (the device is left as it was). */
int vtp_open(struct vtp_dev *d, int index, enum vtp_mode mode, vtp_log_fn log);

/* Reset the device, negotiate features (mount tag, VERSION_1 for modern), read the mount tag.
 * Returns 0 or -1. */
int vtp_init(struct vtp_dev *d);

uint16_t vtp_queue_size(struct vtp_dev *d, uint16_t q);

/* Register queue q. desc/avail/used are bus addresses. For legacy the three parts must form one
 * contiguous region that starts at desc (4096-aligned) with the used ring 4096-aligned. */
int vtp_queue_enable(struct vtp_dev *d, uint16_t q, uint64_t desc, uint64_t avail, uint64_t used);

int vtp_driver_ok(struct vtp_dev *d);
void vtp_notify(struct vtp_dev *d, uint16_t q);
uint8_t vtp_read_isr(struct vtp_dev *d);   /* reading the ISR deasserts INTx */
uint8_t vtp_get_status(struct vtp_dev *d);
void vtp_set_status(struct vtp_dev *d, uint8_t s);
void vtp_reset(struct vtp_dev *d);
void vtp_close(struct vtp_dev *d);

/* Physically contiguous DMA memory, zeroed. *bus receives the device-side address.
 * Returns the virtual address or NULL. */
void *vtp_dma_alloc(struct vtp_dev *d, size_t len, uint64_t *bus);
void vtp_dma_free(void *p, size_t len);

#endif
