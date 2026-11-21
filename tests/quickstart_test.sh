#!/usr/bin/env bash
# tests/quickstart_test.sh - check tools/add-to-quickstart.sh on a QNX 8.0 Quick Start Target Image.
# Runs on the Linux machine that has QNX SDP 8.0 and QEMU. The image folder QSTI is only read: the
# guest writes to a qcow2 overlay in tests/work_quickstart/, which the script deletes at the end.
# Steps, as a user would do them (docs/usage.md, "Quick Start Target Image"):
#   1. boot the image (without fs-9p) and, on the serial console as root, add an ssh key made for
#      this check to root's authorized_keys (root's home is /data/home/root) and allow root logins
#      with a key (the image has "PermitRootLogin no"); the user does this once with their own key;
#   2. run tools/add-to-quickstart.sh over ssh, twice (the second run must not add a second block);
#   3. stop the VM, start it again with tools/qnx-vm (QNX_DISK = the overlay) and check that fs-9p
#      mounted /mnt/host at boot, as qnxuser, and that it comes back by itself after slay -9;
#   4. run tools/add-to-quickstart.sh --remove and check that post_startup.sh is as before.
# Environment:
#   SDP_ENV    qnxsdp-env.sh of QNX SDP 8.0
#   QSTI       Quick Start Target Image folder (output/ifs.bin, output/disk-qemu.vmdk); use a copy
#              of your own, not a folder that other VMs use as their backing disk
#   SHARE      host folder for the guest
#   SSH_PORT   host port forwarded to the guest's ssh port
#   QEMU_ENV   optional: script that puts qemu-system-x86_64 and qemu-img into PATH
#   QSTI_ROOT_PASSWORD  root password of the image's serial console login (default: root)
# Usage: SDP_ENV=... QSTI=... SHARE=... SSH_PORT=... bash tests/quickstart_test.sh
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.."
: "${SDP_ENV:?}" "${QSTI:?}" "${SHARE:?}" "${SSH_PORT:?}"
TOP=$PWD
QSTI=$(cd "$QSTI" && pwd)
W=$TOP/tests/work_quickstart; rm -rf "$W"; mkdir -p "$W/img/output" "$W/img/local"
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
hide() { sed -e "s|$SHARE|SHARE|g" -e "s|$W|WORK|g" -e "s|$QSTI|QSTI|g" -e "s|$TOP|REPO|g" -e "s|$HOME|HOME|g"; }
. "$SDP_ENV" >/dev/null
[ -n "${QEMU_ENV:-}" ] && . "$QEMU_ENV" >/dev/null 2>&1
VER=$(sed -n 's/^#define FS9P_VERSION "\(.*\)"/\1/p' src/fs9p.c)
PS=/system/etc/startup/post_startup.sh
mkdir -p "$SHARE"; SHARE=$(cd "$SHARE" && pwd)

echo "=== setup: overlay on the image disk, ssh key for this check, fs-9p build"
[ -f "$QSTI/output/ifs.bin" ] && [ -f "$QSTI/output/disk-qemu.vmdk" ] || { echo "QSTI has no output/ifs.bin or output/disk-qemu.vmdk"; exit 2; }
ln -s "$QSTI/output/ifs.bin" "$W/img/output/ifs.bin"
[ -f "$QSTI/local/options" ] && ln -s "$QSTI/local/options" "$W/img/local/options"
qemu-img create -q -f qcow2 -F vmdk -b "$QSTI/output/disk-qemu.vmdk" "$W/disk.qcow2" && ok "qcow2 overlay created (the image disk is only read)" || { bad "overlay"; exit 1; }
ssh-keygen -q -t ed25519 -N '' -C fs9p-quickstart-test -f "$W/key" && PUB=$(cat "$W/key.pub")
{ make clean && make; } > "$W/make.txt" 2>&1 && [ -x build/fs-9p ] && ok "make: build/fs-9p" || { bad "make"; tail -5 "$W/make.txt"; exit 1; }
SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes -i "$W/key" -p "$SSH_PORT")
export QNX_SSH="ssh ${SSHO[*]} root@127.0.0.1"
G() { ssh "${SSHO[@]}" root@127.0.0.1 "$1" </dev/null; }

echo; echo "=== boot 1: the Quick Start image without fs-9p; ssh key added on the serial console"
export QNX_DISK=$W/disk.qcow2
QNX_CONSOLE_LOG=$W/console1.log setsid tools/qnx-share.sh "$W/img" "$SHARE" "$SSH_PORT" > "$W/qemu1.out" 2>&1 < /dev/null &
QPID=$!
i=0; until grep -a -q 'login:' "$W/console1.log" 2>/dev/null || [ $i -ge 60 ]; do sleep 3; i=$((i + 1)); done
grep -a -q 'login:' "$W/console1.log" && ok "boot 1: login prompt on the serial console" || bad "boot 1: no login prompt"
cat > "$W/console.py" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(0.5)
for line in sys.argv[2:]:
    s.sendall(line.encode() + b"\r")
    end = time.time() + 3
    while time.time() < end:
        try: s.recv(65536)
        except socket.timeout: pass
EOF
python3 -I "$W/console.py" "$W/console1.log.sock" "" root "${QSTI_ROOT_PASSWORD:-root}" \
    "mkdir -p \$HOME/.ssh && echo '$PUB' >> \$HOME/.ssh/authorized_keys && chmod 700 \$HOME/.ssh && chmod 600 \$HOME/.ssh/authorized_keys && echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-root-key.conf && { slay -s SIGHUP sshd; echo KEY-\$((1+1))-ADDED; }" exit
grep -a -q 'KEY-2-ADDED' "$W/console1.log" && ok "serial console: logged in as root, ssh key added, root key login allowed" || bad "serial console: key not added"
# Few tries: OpenSSH refuses all connections from a source address for a while after repeated
# failed logins (PerSourcePenalties), and with QEMU user networking every login comes from 10.0.2.2.
i=0; until G true 2>/dev/null || [ $i -ge 10 ]; do sleep 5; i=$((i + 1)); done
G 'uname -sr' > "$W/uname.txt" 2>&1; sed 's/^/  guest: /' "$W/uname.txt"
grep -q '^QNX 8' "$W/uname.txt" && ok "ssh as root with the key" || bad "ssh login"
G "test -e /mnt/host && echo present || echo absent; test -e /system/bin/fs-9p && echo has-fs-9p || echo no-fs-9p" > "$W/before.txt" 2>&1
sed 's/^/  before: /' "$W/before.txt"
grep -q '^absent' "$W/before.txt" && grep -q '^no-fs-9p' "$W/before.txt" && ok "before: no /mnt/host and no /system/bin/fs-9p in the image" || bad "before: fs-9p already there"
G "cat $PS" | md5sum > "$W/ps_md5_before.txt"

echo; echo "=== tools/add-to-quickstart.sh (run twice)"
{ tools/add-to-quickstart.sh; echo "exit status $?"; } > "$W/add1.txt" 2>&1; sed 's/^/  /' "$W/add1.txt"
{ tools/add-to-quickstart.sh; echo "exit status $?"; } > "$W/add2.txt" 2>&1; sed 's/^/  /' "$W/add2.txt"
grep -q '^exit status 0' "$W/add1.txt" && grep -q '^exit status 0' "$W/add2.txt" && ok "add-to-quickstart.sh: exit status 0, twice" || bad "add-to-quickstart.sh exit status"
G "grep -c '^# fs-9p begin' $PS; tail -1 $PS; ls -l /system/bin/fs-9p /system/bin/fs-9p-supervise" > "$W/after_add.txt" 2>&1
sed 's/^/  /' "$W/after_add.txt"
[ "$(head -1 "$W/after_add.txt")" = 1 ] && [ "$(sed -n 2p "$W/after_add.txt")" = "exit 0" ] && ok "post_startup.sh: one fs-9p block, before the final exit 0" || bad "post_startup.sh block"
grep -E -q -- '^-rwxr-xr-x .* /system/bin/fs-9p$' "$W/after_add.txt" && grep -E -q -- '^-rwxr-xr-x .* /system/bin/fs-9p-supervise$' "$W/after_add.txt" && ok "fs-9p and fs-9p-supervise in /system/bin" || bad "programs in /system/bin"
G "sed -n '/^# fs-9p begin/,/^# fs-9p end/p' $PS" | sed 's/^/  block: /'
kill "$QPID"; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
kill -0 "$QPID" 2>/dev/null && kill -9 "$QPID"
rm -f "$W/console1.log.sock"

echo; echo "=== boot 2: tools/qnx-vm start with QNX_DISK (the same overlay)"
export QNX_SSH_KEY=$W/key QNX_IMAGE=$W/img
{ tools/qnx-vm start "$W/img" "$SHARE" "$SSH_PORT"; echo "exit status $?"; } > "$W/start.txt" 2>&1; hide < "$W/start.txt" | sed 's/^/  /'
grep -q '^exit status 0' "$W/start.txt" && grep -q 'ready: the guest answers on ssh and /mnt/host is mounted' "$W/start.txt" &&
    ok "boot 2: /mnt/host mounted at boot, no command typed" || bad "boot 2: no /mnt/host"
grep -q "fs-9p $VER: mount tag \"hostshare\" mounted at /mnt/host" "$W/start.txt" && ok "boot 2: console line of fs-9p $VER" || bad "boot 2: mount line"
echo "written on the host for the Quick Start check" > "$SHARE/qs_check.txt"
{ tools/qnx-run cat "$SHARE/qs_check.txt"; echo "exit status $?"; } > "$W/cat.txt" 2>&1; sed 's/^/  /' "$W/cat.txt"
grep -q '^written on the host for the Quick Start check' "$W/cat.txt" && ok "qnx-run cat: the guest reads a host file through /mnt/host" || bad "guest read"
{ tools/qnx-run pidin -p fs-9p -F '%a %n %U %W'; } > "$W/pidin.txt" 2>&1; sed 's/^/  /' "$W/pidin.txt"
grep -E -q 'fs-9p +1000 +1000' "$W/pidin.txt" && ok "pidin: fs-9p runs as uid 1000 (qnxuser)" || bad "fs-9p user"
cat > "$W/restart_check.sh" <<'EOF'
cd /
p1=$(pidin -p fs-9p -F '%a' | sed 1d | tr -d ' ')
slay -9 fs-9p
i=0; p2=$p1
while [ "$i" -lt 30 ]; do
    p2=$(pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | tr -d ' ')
    [ -n "$p2" ] && [ "$p2" != "$p1" ] && [ -f /mnt/host/qs_check.txt ] && break
    sleep 1; i=$((i + 1))
done
[ -n "$p2" ] && [ "$p2" != "$p1" ] && echo "fs-9p has a new process id" || echo "fs-9p has no new process"
[ -f /mnt/host/qs_check.txt ] && echo "/mnt/host is back" || echo "/mnt/host is not back"
EOF
tools/qnx-run -i sh < "$W/restart_check.sh" > "$W/restart.txt" 2>&1; sed 's/^/  /' "$W/restart.txt"
grep -q '^fs-9p has a new process id' "$W/restart.txt" && grep -q '^/mnt/host is back' "$W/restart.txt" && ok "slay -9: fs-9p-supervise started fs-9p again and /mnt/host is back" || bad "restart"
tools/qnx-vm console > "$W/console2.txt" 2>&1
grep -a -E '^---> Starting fs-9p|fs-9p' "$W/console2.txt" | hide | sed 's/^/  console: /'
grep -q '^---> Starting fs-9p' "$W/console2.txt" && grep -q 'fs-9p-supervise: fs-9p ended by signal 9; starting it again (restart 1)' "$W/console2.txt" &&
    ok "console: the boot block started fs-9p; fs-9p-supervise reported restart 1" || bad "console lines"

echo; echo "=== tools/add-to-quickstart.sh --remove"
{ tools/add-to-quickstart.sh --remove; echo "exit status $?"; } > "$W/remove.txt" 2>&1; sed 's/^/  /' "$W/remove.txt"
{ G "cat $PS" | md5sum; G "test -e /system/bin/fs-9p || echo no-fs-9p; test -e /system/bin/fs-9p-supervise || echo no-supervise"; } > "$W/after_rm.txt" 2>&1
grep -q '^exit status 0' "$W/remove.txt" && [ "$(head -1 "$W/after_rm.txt")" = "$(head -1 "$W/ps_md5_before.txt")" ] &&
    grep -q '^no-fs-9p' "$W/after_rm.txt" && grep -q '^no-supervise' "$W/after_rm.txt" &&
    ok "--remove: post_startup.sh has the md5 it had before, the two programs are gone" || bad "--remove"
tools/qnx-vm stop 2>&1 | sed 's/^/  /'
rm -f "$SHARE/qs_check.txt"
rm -rf "$W"
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
