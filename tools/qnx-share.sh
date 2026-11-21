#!/bin/sh
# tools/qnx-share.sh - start a QNX 8.0 image in QEMU with a host folder shared over virtio-9p.
#
# usage: tools/qnx-share.sh IMAGE_DIR SHARE_FOLDER [SSH_PORT]
#   IMAGE_DIR     image folder made by tools/make-image.sh, or a QNX 8.0 Quick Start Target Image
#                 folder (output/ifs.bin, output/disk-qemu.vmdk)
#   SHARE_FOLDER  host folder that the guest sees at /mnt/host (created if missing)
#   SSH_PORT      host port forwarded to the guest's ssh port 22 (default 2222)
# The terminal becomes the guest's serial console; Ctrl-a x quits QEMU. The disk is opened with
# snapshot=on: changes inside the guest are dropped at quit, so the image stays as it was built
# (unless QNX_DISK is set). Files in SHARE_FOLDER are host files and stay.
# Optional settings (environment):
#   QNX_CONSOLE_LOG  write the serial console to this file (and to the unix socket
#                    $QNX_CONSOLE_LOG.sock) instead of the terminal; tools/qnx-vm uses this
#   QEMU_EXTRA       more QEMU options, split at spaces (for example a second -fsdev/-device pair)
#   QNX_DISK         disk file to open read-write instead of IMAGE_DIR/output/disk-qemu.vmdk with
#                    snapshot=on, so that changes inside the guest stay: for example the disk of a
#                    Quick Start image after tools/add-to-quickstart.sh, or a qcow2 overlay on it
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -eu
IMG=${1:?usage: tools/qnx-share.sh IMAGE_DIR SHARE_FOLDER [SSH_PORT]}
SHARE=${2:?usage: tools/qnx-share.sh IMAGE_DIR SHARE_FOLDER [SSH_PORT]}
PORT=${3:-2222}
mkdir -p "$SHARE"
SHARE=$(cd "$SHARE" && pwd)
if [ -n "${QNX_DISK:-}" ]; then
    [ -f "$QNX_DISK" ] || { echo "qnx-share: QNX_DISK=$QNX_DISK is not a file" >&2; exit 1; }
    DRIVE="file=$(cd "$(dirname "$QNX_DISK")" && pwd)/$(basename "$QNX_DISK"),if=ide,id=drv0"
else
    DRIVE=file=output/disk-qemu.vmdk,if=ide,id=drv0,snapshot=on
fi
cd "$IMG"
[ -f output/ifs.bin ] && { [ -n "${QNX_DISK:-}" ] || [ -f output/disk-qemu.vmdk ]; } || { echo "qnx-share: $IMG/output has no ifs.bin or disk-qemu.vmdk" >&2; exit 1; }
opt() { sed -n "s/^OPT_$1='\(.*\)'\$/\1/p" local/options 2>/dev/null | head -1; }
CPUS=$(opt CPU); CPUS=${CPUS:-2}
RAM=$(opt RAM); RAM=${RAM:-1G}
MAC=$(opt MACADDR); case "$MAC" in ??:??:??:??:??:??) MACOPT=",mac=$MAC" ;; *) MACOPT= ;; esac
if [ -n "${QNX_CONSOLE_LOG:-}" ]; then
    set -- -chardev "socket,id=ser0,path=$QNX_CONSOLE_LOG.sock,server=on,wait=off,logfile=$QNX_CONSOLE_LOG" -serial chardev:ser0
else
    set -- -serial mon:stdio
fi
# shellcheck disable=SC2086  # QEMU_EXTRA is split at spaces on purpose
exec qemu-system-x86_64 -enable-kvm -cpu host -smp "$CPUS" -m "$RAM" \
  -drive "$DRIVE" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${PORT}-:22 \
  -device virtio-net-pci,netdev=net0$MACOPT \
  -kernel output/ifs.bin "$@" \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -vga none -display none \
  -fsdev local,id=fs0,path="$SHARE",security_model=none \
  -device virtio-9p-pci,fsdev=fs0,mount_tag=hostshare ${QEMU_EXTRA:-}
