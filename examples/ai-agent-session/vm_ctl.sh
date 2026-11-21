#!/usr/bin/env bash
# vm_ctl.sh start|stop|status
#   start   boot the QNX 8.0 guest with the shared folder (QEMU virtio-9p): tools/qnx-share.sh runs
#           the image IMAGE in the background; the image starts fs-9p at boot, which mounts the
#           shared folder at /mnt/host
#   stop    shut the guest down
#   status  is the guest running, and is /mnt/host mounted?
# Settings: env.local in this folder (copy env.example); BUILD_HOST empty: run on this machine.
# IMAGE must be made by tools/make-image.sh with SSH_IDENT (see env.example). The guest's serial
# console output goes to IMAGE/ai-session-console.log on the QEMU host.
# This is the reader version; session-scripts/vm_ctl.sh is the version that the session ran (it
# used a VM wrapper script of the lab and copied fs-9p into the guest).
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")"
[ -f env.local ] || { echo "env.local missing: copy env.example to env.local and edit it"; exit 2; }
. ./env.local
q() { printf '%q' "$1"; }
H() { if [ -n "${BUILD_HOST:-}" ]; then ssh -q "$BUILD_HOST" "$1"; else bash -c "$1"; fi; }
PIDF=$IMAGE/ai-session-qemu.pid
CONSOLE=$IMAGE/ai-session-console.log
KEYOPT=""; [ -n "${SSH_KEY:-}" ] && KEYOPT="-i $(q "$SSH_KEY") -o IdentitiesOnly=yes"
# G CMD: run CMD as root in the guest (the same ssh options as tools/qnx-run)
G() { H "exec 2>&1; ssh -p $(q "$SSH_PORT") $KEYOPT -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 root@127.0.0.1 $(q "$1") </dev/null" 2>/dev/null; }
running() { H "test -f $(q "$PIDF") && kill -0 \"\$(cat $(q "$PIDF"))\" 2>/dev/null" 2>/dev/null; }
case "${1:-}" in
start)
    if running; then echo "guest running"; G "ls -ld /mnt/host 2>&1"; exit 0; fi
    H "exec 2>&1; . $(q "${QEMU_ENV:-/dev/null}") >/dev/null 2>&1; setsid nohup $(q "$REPO/tools/qnx-share.sh") $(q "$IMAGE") $(q "$SHARE") $(q "$SSH_PORT") </dev/null >$(q "$CONSOLE") 2>&1 & echo \$! >$(q "$PIDF")" 2>/dev/null
    n=0
    until G "ls /mnt/host >/dev/null" >/dev/null; do
        n=$((n + 1)); [ $n -ge 60 ] && break
        running || { echo "QEMU ended; see $CONSOLE on the QEMU host"; exit 1; }
        sleep 5
    done
    G true >/dev/null || { echo "no ssh login to the guest; see $CONSOLE on the QEMU host"; exit 1; }
    echo "ssh ready"
    H "grep -a -m1 'mounted at' $(q "$CONSOLE")" 2>/dev/null |
        sed -e "s,$SHARE,SHARE,g" | tr -d '\r'
    G "ls -ld /mnt/host 2>&1" ;;
stop)
    if running; then
        H "kill \"\$(cat $(q "$PIDF"))\"" 2>/dev/null
        n=0; while running && [ $n -lt 30 ]; do n=$((n + 1)); sleep 1; done
        H "rm -f $(q "$PIDF")" 2>/dev/null
        echo "stopped"
    else
        echo "guest not running"
    fi ;;
status)
    if running; then
        echo "guest running"; G "ls -ld /mnt/host 2>&1"
    else
        echo "guest not running"
    fi ;;
*) sed -n 2,7p "$0"; exit 2 ;;
esac
