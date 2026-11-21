#!/usr/bin/env bash
# vm_ctl.sh start|stop|status
#   start   boot the QNX 8.0 guest with the shared folder (QEMU virtio-9p), copy fs-9p into the
#           guest if it is missing, and mount the shared folder at /mnt/host
#   stop    shut the guest down
#   status  is the guest running, and is /mnt/host mounted?
set -u
cd "$(dirname "$0")"
. ./env.local
q() { printf '%q' "$1"; }
G() { ssh -q "$BUILD_HOST" "exec 2>&1; $VM ssh $VM_NAME $(q "$1") </dev/null" 2>/dev/null; }
case "${1:-}" in
start)
    ssh -q "$BUILD_HOST" "exec 2>&1; . $(q "$QEMU_ENV") >/dev/null 2>&1; QEMU_EXTRA=$(q "-fsdev local,id=fs0,path=$SHARE,security_model=none -device virtio-9p-pci,fsdev=fs0,mount_tag=hostshare -fsdev local,id=fs1,path=$SHARE2,security_model=none -device virtio-9p-pci,fsdev=fs1,mount_tag=share2,disable-legacy=on") $VM start $VM_NAME $VM_PORT" 2>/dev/null | grep -v '^vnc' | sed -E "s/ready after [0-9]+ s on port [0-9]+/ready/"
    G "test -x /tmp/fs9p/fs-9p" || ssh -q "$BUILD_HOST" "exec 2>&1; $VM ssh $VM_NAME mkdir -p /tmp/fs9p </dev/null; $VM scp $VM_NAME $(q "$FS9P") :/tmp/fs9p/" 2>/dev/null
    G "ls /mnt/host >/dev/null 2>&1 || /tmp/fs9p/fs-9p -d -a hostshare -m /mnt/host 2>&1 | grep 'mounted at'; ls -ld /mnt/host" ;;
stop)
    ssh -q "$BUILD_HOST" "exec 2>&1; $VM stop $VM_NAME" 2>/dev/null ;;
status)
    if ssh -q "$BUILD_HOST" "exec 2>&1; $VM list" 2>/dev/null | grep -q "^$VM_NAME "; then
        echo "guest running"; G "ls -ld /mnt/host 2>&1"
    else
        echo "guest not running"
    fi ;;
*) sed -n 2,6p "$0"; exit 2 ;;
esac
