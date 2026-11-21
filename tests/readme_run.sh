#!/usr/bin/env bash
# tests/readme_run.sh - check that the quick start of README.md works as written.
# Runs on the Linux machine that has QNX SDP 8.0 and QEMU. It takes the two command blocks that
# README.md marks with "<!-- readme-run:quickstart -->" and "<!-- readme-run:use -->" and runs them
# unchanged, after the README's variable block (IMAGE, SHARE, SSH_PORT) and the SDP environment.
# The blocks build fs-9p, build a QNX 8.0 image with tools/make-image.sh (mkqnximage), start it in
# the background with tools/qnx-vm, build a program into the share with qcc, run it with
# tools/qnx-run and run the unit tests of examples/qnx-unit in the guest. Then the script checks,
# through tools/qnx-run: reading and writing the share, the user and abilities of the running fs-9p
# (pidin), and that fs-9p comes back by itself after slay -9 (fs-9p-supervise in the boot script).
# At the end it stops the VM with tools/qnx-vm stop.
# The only change to the blocks' environment: SSH_IDENT and QNX_SSH_KEY name a key pair made for
# this check (the README relies on the user's own ~/.ssh key instead).
#
# Environment:
#   SDP_ENV        qnxsdp-env.sh of QNX SDP 8.0 (the README's "source" line)
#   IMAGE          README variable: image folder (created by the block)
#   SHARE          README variable: host folder for the guest
#   SSH_PORT       README variable: host port forwarded to the guest's ssh port
#   QEMU_ENV       optional: script that puts qemu-system-x86_64 into PATH
# Usage: SDP_ENV=... IMAGE=... SHARE=... SSH_PORT=... bash tests/readme_run.sh
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.."
: "${SDP_ENV:?}" "${IMAGE:?}" "${SHARE:?}" "${SSH_PORT:?}"
TOP=$PWD
W=$TOP/tests/work_readme; rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
hide() { sed -e "s|$SHARE|SHARE|g" -e "s|$IMAGE|IMAGE|g" -e "s|$TOP|REPO|g" -e "s|$HOME|HOME|g"; }
block() {   # block NAME: the sh block after the marker <!-- readme-run:NAME -->
    awk -v m="<!-- readme-run:$1 -->" '$0 == m {f = 1; next}
         f && /^ *```sh/ {p = 1; next}
         p && /^ *```/ {exit}
         p {print}' README.md
}
VER=$(sed -n 's/^#define FS9P_VERSION "\(.*\)"/\1/p' src/fs9p.c)
block quickstart > "$W/quickstart.sh"; block use > "$W/use.sh"
[ -s "$W/quickstart.sh" ] && [ -s "$W/use.sh" ] || { echo "marked blocks missing in README.md"; exit 2; }
echo "=== blocks from README.md (run unchanged)"
cat "$W/quickstart.sh" "$W/use.sh"

ssh-keygen -q -t ed25519 -N '' -C fs9p-readme-check -f "$W/id"
{
    echo "cd '$TOP' || exit 1"
    echo ". '$SDP_ENV' >/dev/null"
    [ -n "${QEMU_ENV:-}" ] && echo ". '$QEMU_ENV' >/dev/null 2>&1"
    echo "IMAGE='$IMAGE'"
    echo "SHARE='$SHARE'"
    echo "SSH_PORT='$SSH_PORT'"
    echo "export SSH_IDENT='$W/id.pub' QNX_SSH_KEY='$W/id'"
    echo "set -e"
    cat "$W/quickstart.sh"
    cat "$W/use.sh"
} > "$W/run.sh"
[ -n "$IMAGE" ] && [ -f "$IMAGE/qnx-vm/qemu.pid" ] && tools/qnx-vm stop "$IMAGE" >/dev/null 2>&1
rm -rf "$IMAGE"
mkdir -p "$SHARE"
rm -rf "$SHARE/hello" "$SHARE/hello.c" "$SHARE/from_guest.txt" "$SHARE/qnx-unit-build"
echo "written on the host for the README check" > "$SHARE/readme_check.txt"

echo; echo "=== run the blocks"
bash "$W/run.sh" > "$W/blocks.txt" 2>&1; st=$?
grep -v -E '^(qcc|cc|gcc|  CC|ntox86_64-)' "$W/blocks.txt" | grep -v -i 'warning: ' | hide | grep -v -E 'sshd-auth does not exist' | sed -e 's/^/  /'
[ "$st" = 0 ] && ok "both README blocks ran with exit status 0" || bad "README blocks: exit status $st"
[ -x build/fs-9p ] && [ -f "$IMAGE/output/ifs.bin" ] && ok "build/fs-9p and the image (IMAGE/output) exist" || bad "build or image missing"
grep -q '^qnx-vm: ready: the guest answers on ssh and /mnt/host is mounted' "$W/blocks.txt" && ok "tools/qnx-vm start returned with the guest ready" || bad "qnx-vm start"
grep -q "fs-9p $VER: mount tag \"hostshare\" mounted at /mnt/host" "$W/blocks.txt" && ok "boot output: fs-9p $VER mounted the share at /mnt/host" || bad "no mount line in the boot output"
grep -q '^hello from QNX$' "$W/blocks.txt" && ok "tools/qnx-run SHARE/hello: output of the program built on the host, run in the guest" || bad "qnx-run hello"
grep -q '^qnx-test: 0 failed' "$W/blocks.txt" && ok "make -C examples/qnx-unit qnx-test: unit tests passed in the guest" || bad "make qnx-test"

export QNX_IMAGE="$IMAGE" QNX_SSH_KEY="$W/id"
QR() { tools/qnx-run "$@"; }
echo; echo "=== tools/qnx-run: the guest reads and writes the share"
QR sh -c 'ls /mnt/host; cat /mnt/host/readme_check.txt; echo "written in the guest" > /mnt/host/from_guest.txt' > "$W/rw.txt" 2>&1
hide < "$W/rw.txt" | sed 's/^/  /'
grep -q '^written on the host for the README check' "$W/rw.txt" && ok "guest reads the host file" || bad "guest read"
[ "$(cat "$SHARE/from_guest.txt" 2>/dev/null)" = "written in the guest" ] && ok "host sees the file written in the guest" || bad "guest write"

echo; echo "=== tools/qnx-run: the running fs-9p is not root and keeps only two abilities"
QR sh -c 'pidin -p fs-9p -F "%a %n %U %W"; pidin -p fs-9p abilities | grep -E " [R-]N[L-][I-]"' > "$W/pidin.txt" 2>&1
sed 's/^/  /' "$W/pidin.txt"
grep -E -q 'fs-9p +1000 +1000' "$W/pidin.txt" && ok "pidin: fs-9p runs with uid 1000 (qnxuser)" || bad "fs-9p user"
NAB=$(grep -c -E ' [R-]N[L-][I-]' "$W/pidin.txt")
[ "$NAB" = 2 ] && grep -q -E '^ *io +[R-]NL' "$W/pidin.txt" && ok "pidin: 2 abilities for non-root (io, priority), locked" || bad "abilities for non-root: $NAB"

echo; echo "=== slay -9 fs-9p while a file is open: fs-9p-supervise starts it again, no command typed"
# The commands go to the guest shell on stdin (qnx-run -i): a script file on the share could not be
# read on after the kill.
cat > "$W/restart_check.sh" <<'EOF'
cd /
exec 3< /mnt/host/readme_check.txt
p1=$(pidin -p fs-9p -F '%a' | sed 1d | tr -d ' ')
slay -9 fs-9p
i=0; p2=$p1
while [ "$i" -lt 30 ]; do
    p2=$(pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | tr -d ' ')
    [ -n "$p2" ] && [ "$p2" != "$p1" ] && [ -f /mnt/host/readme_check.txt ] && break
    sleep 1; i=$((i + 1))
done
[ -n "$p2" ] && [ "$p2" != "$p1" ] && echo "fs-9p has a new process id" || echo "fs-9p has no new process"
[ -f /mnt/host/readme_check.txt ] && echo "/mnt/host is back" || echo "/mnt/host is not back"
read -r x <&3; echo "read on the descriptor opened before the kill: status $?"
cat /mnt/host/readme_check.txt
pidin -p fs-9p -F "%a %n %U %W" | sed 1d | sed 's/^ *[0-9]* */new process: /'
EOF
tools/qnx-run -i sh < "$W/restart_check.sh" > "$W/restart.txt" 2>&1
sed 's/^/  /' "$W/restart.txt"
grep -q '^fs-9p has a new process id' "$W/restart.txt" && grep -q '^/mnt/host is back' "$W/restart.txt" && ok "after slay -9 a new fs-9p process mounted /mnt/host again" || bad "automatic restart"
grep -q -E 'before the kill: status [1-9]' "$W/restart.txt" && ok "a read on the descriptor opened before the kill fails" || bad "old descriptor"
grep -q '^written on the host for the README check' "$W/restart.txt" && ok "a new open reads the file" || bad "new open after restart"
grep -E -q 'new process: .*fs-9p +1000 +1000' "$W/restart.txt" && ok "the restarted fs-9p runs with uid 1000 too" || bad "user of the restarted fs-9p"
tools/qnx-vm console > "$W/console.txt" 2>&1
grep -c "fs-9p $VER: mount tag \"hostshare\" mounted at /mnt/host" "$W/console.txt" | sed 's/^/  mount lines on the console: /'
grep -q '^fs-9p-supervise: fs-9p ended by signal 9; starting it again (restart 1)' "$W/console.txt" && ok "console: fs-9p-supervise reported signal 9 and restart 1" || bad "supervisor line on the console"

echo; echo "=== tools/qnx-vm status and stop"
tools/qnx-vm status 2>&1 | hide | sed 's/^/  /'
tools/qnx-vm status >/dev/null 2>&1 && ok "tools/qnx-vm status: running" || bad "qnx-vm status"
PID=$(cat "$IMAGE/qnx-vm/qemu.pid" 2>/dev/null)
tools/qnx-vm stop 2>&1 | sed 's/^/  /'
[ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null && ok "tools/qnx-vm stop: QEMU ended" || bad "QEMU still runs"

echo; echo "=== serial console, lines of fs-9p and of the boot script"
grep -a -E '^---> |fs-9p|Startup complete' "$W/console.txt" | grep -v 'sshd-auth does not exist' | hide | sed 's/^/  /'
rm -rf "$SHARE/readme_check.txt" "$SHARE/from_guest.txt" "$SHARE/hello" "$SHARE/hello.c" "$SHARE/qnx-unit-build"
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
