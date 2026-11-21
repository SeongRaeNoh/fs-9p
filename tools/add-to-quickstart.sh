#!/usr/bin/env bash
# tools/add-to-quickstart.sh - add fs-9p to an existing QNX 8.0 Quick Start Target Image (or another
# QNX 8.0 image whose /system is writable and whose boot runs /system/etc/startup/post_startup.sh),
# so that fs-9p mounts the QEMU host folder at /mnt/host at every boot, under image/fs-9p-supervise.
# Nothing is rebuilt: the script works on the running guest over ssh and keeps the guest's files.
#
# usage: tools/add-to-quickstart.sh            add or update fs-9p
#        tools/add-to-quickstart.sh --remove   remove what this script added
# What it does in the guest (as root, through QNX_SSH):
#   1. copies build/fs-9p and image/fs-9p-supervise to /system/bin/ (a running fs-9p is stopped
#      first with SIGTERM, because a running program file cannot be replaced)
#   2. inserts a block between "# fs-9p begin" and "# fs-9p end" before the last "exit 0" line of
#      /system/etc/startup/post_startup.sh (an existing block is replaced); the first run keeps the
#      original file as post_startup.sh.before-fs-9p
#   3. runs sync
# Afterwards, start the VM with the virtio-9p device (QEMU options
#   -fsdev local,id=fs0,path=SHARE,security_model=none -device virtio-9p-pci,fsdev=fs0,mount_tag=hostshare
# or QNX_DISK=... tools/qnx-share.sh / tools/qnx-vm, see docs/usage.md). Without the device, fs-9p
# prints an error at boot and the boot goes on.
#
# Settings (environment):
#   QNX_SSH       command that runs its argument as a root shell command in the guest
#                 (default: ssh -p $QNX_SSH_PORT root@127.0.0.1 with batch-mode options; QNX_SSH_PORT
#                 default 2222; QNX_SSH_KEY: private key file for -i)
#   FS9P_OPTIONS  options for fs-9p in the boot block (default: -U qnxuser)
# Build fs-9p first (make). Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
me=add-to-quickstart
die() { echo "$me: $*" >&2; exit 1; }
cd "$(dirname "$0")/.." || exit 1
remove=0
case "${1:-}" in
    "") ;;
    --remove) remove=1 ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see $me -h)" ;;
esac
if [ -n "${QNX_SSH:-}" ]; then
    read -r -a SSH <<< "$QNX_SSH"
else
    SSH=(ssh -p "${QNX_SSH_PORT:-2222}" -o BatchMode=yes -o StrictHostKeyChecking=no
         -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    [ -n "${QNX_SSH_KEY:-}" ] && SSH+=(-i "$QNX_SSH_KEY" -o IdentitiesOnly=yes)
    SSH+=(root@127.0.0.1)
fi
G() { "${SSH[@]}" "$1"; }          # G CMD: run CMD in the guest; stdin goes to CMD
PS=/system/etc/startup/post_startup.sh
BIN=/system/bin

sys=$(G 'uname -sr; id -u; test -f '$PS' && echo has-post-startup' </dev/null) || die "ssh to the guest failed (QNX_SSH or QNX_SSH_PORT / QNX_SSH_KEY)"
case "$sys" in "QNX 8."*) ;; *) die "the guest is not QNX 8 (uname: $(echo "$sys" | head -1))" ;; esac
[ "$(echo "$sys" | sed -n 2p)" = 0 ] || die "QNX_SSH must give a root shell (id -u is not 0)"
echo "$sys" | grep -q '^has-post-startup$' || die "$PS not found in the guest"
# (slay's exit status is not used: it is 0 when no process matched)
G "if pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | grep -q .; then slay -f fs-9p >/dev/null 2>&1; echo '$me: stopped the running fs-9p (SIGTERM)'; sleep 2; fi; true" </dev/null

tmp=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
G "cat $PS" < /dev/null > "$tmp/old" || die "cannot read $PS"
# Drop an earlier block, then insert the new one before the last "exit 0" line (or at the end).
awk '/^# fs-9p begin/ {skip = 1} !skip {print} /^# fs-9p end/ {skip = 0}' "$tmp/old" > "$tmp/clean"
if [ "$remove" = 1 ]; then
    cp "$tmp/clean" "$tmp/new"
else
    [ -x build/fs-9p ] || die "build/fs-9p is missing; run make first"
    cat > "$tmp/block" <<EOF
# fs-9p begin (added by tools/add-to-quickstart.sh; remove with tools/add-to-quickstart.sh --remove)
# Mount the QEMU host folder (virtio-9p device, mount tag hostshare) at /mnt/host; fs-9p-supervise
# starts fs-9p again when a signal ends it.
if [ -x $BIN/fs-9p-supervise ] && [ -x $BIN/fs-9p ]; then
    echo "---> Starting fs-9p"
    $BIN/fs-9p-supervise ${FS9P_OPTIONS:--U qnxuser}
fi
# fs-9p end
EOF
    awk -v bf="$tmp/block" '{l[NR] = $0} $0 == "exit 0" {last = NR}
        END {for (i = 1; i <= NR; i++) {
                 if (i == last) while ((getline b < bf) > 0) print b
                 print l[i]}
             if (!last) while ((getline b < bf) > 0) print b}' "$tmp/clean" > "$tmp/new"
fi

if [ "$remove" = 1 ]; then
    G "rm -f $BIN/fs-9p $BIN/fs-9p-supervise" </dev/null || die "cannot remove the programs"
    echo "$me: removed $BIN/fs-9p and $BIN/fs-9p-supervise"
else
    G "cat > $BIN/fs-9p.new && chmod 755 $BIN/fs-9p.new && mv -f $BIN/fs-9p.new $BIN/fs-9p" < build/fs-9p || die "cannot copy fs-9p"
    G "cat > $BIN/fs-9p-supervise && chmod 755 $BIN/fs-9p-supervise" < image/fs-9p-supervise || die "cannot copy fs-9p-supervise"
    echo "$me: copied fs-9p and fs-9p-supervise to $BIN/"
fi
G "test -f $PS.before-fs-9p || cp -p $PS $PS.before-fs-9p; cat > $PS.new && chmod 555 $PS.new && mv -f $PS.new $PS && sync" < "$tmp/new" || die "cannot write $PS"
if [ "$remove" = 1 ]; then
    echo "$me: removed the fs-9p block from $PS"
else
    echo "$me: $PS now starts fs-9p at boot (lines $(grep -n '^# fs-9p begin' "$tmp/new" | cut -d: -f1)-$(grep -n '^# fs-9p end' "$tmp/new" | cut -d: -f1))"
    echo "$me: restart the VM with the virtio-9p device (see docs/usage.md, \"Quick Start Target Image\")"
fi
