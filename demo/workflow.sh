#!/usr/bin/env bash
# demo/workflow.sh - the developer workflow that fs-9p enables, shown step by step (for the video).
# Runs on the developer machine with the settings of tests/env.local (see tests/env.example):
#   1. write a C file into the shared folder on the QEMU host,
#   2. build it with qcc on the host, output into the shared folder,
#   3. run it in the QNX guest straight from /mnt/host (no scp of the program),
#   4. edit the source, build again, run again,
#   5. run it from the host with tools/qnx-run, which returns the output and the exit status.
# The driver must be in the guest (GUEST_FS9P, default /tmp/fs9p/fs-9p, where tests/run_guest_tests.sh
# puts it); the script mounts the share if it is not mounted. Output goes to the terminal and to
# tests/logs/workflow_<date>.log. Set PAUSE=2 to wait 2 s after each step (for screen recording).
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.."
[ -f tests/env.local ] || { echo "tests/env.local missing; copy tests/env.example and edit it"; exit 2; }
. tests/env.local
: "${BUILD_HOST:?}" "${SDP_ENV:?}" "${SHARE:?}" "${GUEST_SSH:?}"
GUEST_FS9P=${GUEST_FS9P:-/tmp/fs9p/fs-9p}
PAUSE=${PAUSE:-0}
mkdir -p tests/logs
LOG=tests/logs/workflow_$(date +%Y%m%d_%H%M%S).log
q() { printf '%q' "$1"; }

# The ssh calls run quietly (-q), send the remote stderr to stdout on the QEMU host and drop ssh's own
# stderr, so that text which a server prints at login does not reach the log.
# host CMD: run CMD on the QEMU host in SHARE/demo with the SDP environment; print it with a prompt
host() {
    printf '\nhost:share/demo$ %s\n' "$1"
    ssh -q "$BUILD_HOST" "exec 2>&1; echo @@D@@; . $(q "$SDP_ENV") >/dev/null; export QNX_SHARE=$(q "$SHARE") QNX_SSH=$(q "$GUEST_SSH") PATH=$(q "$REMOTE_DIR/tools"):\$PATH; mkdir -p $(q "$SHARE/demo") && cd $(q "$SHARE/demo") && { $1; }" 2>/dev/null |
        sed -n '/^@@D@@$/,$p' | sed 1d
    sleep "$PAUSE"
}
# guest CMD: run CMD as root in the QNX guest; print it with a prompt
guest() {
    printf '\nqnx:/mnt/host/demo# %s\n' "$1"
    ssh -q "$BUILD_HOST" "exec 2>&1; echo @@D@@; $GUEST_SSH $(q "cd /mnt/host/demo 2>/dev/null; $1") </dev/null" 2>/dev/null |
        sed -n '/^@@D@@$/,$p' | sed 1d
    sleep "$PAUSE"
}
say() { printf '\n### %s\n' "$*"; }

{
echo "# fs-9p developer workflow demo, $(date -Iseconds), sources sha256 $(sh tests/srchash.sh) (tests/srchash.sh)"

say "0. The QNX guest mounts the host folder with fs-9p (once per boot)"
guest "ls /mnt/host >/dev/null 2>&1 || $GUEST_FS9P -d; ls -ld /mnt/host"

say "1. Host: write a C file into the shared folder"
host "cat > hello.c <<'EOF'
#include <stdio.h>
#include <sys/utsname.h>

int main(void)
{
    struct utsname u;
    uname(&u);
    printf(\"Hello from %s %s on %s - version 1\\n\", u.sysname, u.release, u.nodename);
    return 0;
}
EOF
cp hello.c hello.c.v1; cat hello.c"

say "2. Host: build it with the QNX toolchain (qcc), output into the shared folder"
host "rm -f hello; qcc -Vgcc_ntox86_64 -Wall -o hello hello.c && ls -l hello | awk '{print \$1, \$5, \$NF}'"

say "3. Guest: run it straight from /mnt/host - nothing was copied into the guest"
guest "ls -l /mnt/host/demo"
guest "./hello"

say "4. Host: edit the source (version 2 also prints the process id) and build again"
host "sed -i -e 's/version 1/version 2/' -e 's/^    return 0;/    printf(\"my process id is %d\\\\n\", (int)getpid());\\n    return 0;/' -e 's/^#include <stdio.h>/#include <stdio.h>\\n#include <unistd.h>/' hello.c; diff -u hello.c.v1 hello.c | tail -n +3"
host "qcc -Vgcc_ntox86_64 -Wall -o hello hello.c && ls -l hello | awk '{print \$1, \$5, \$NF}'"

say "5. Guest: run the new build at once"
guest "./hello"

say "6. Guest: write a result file; the host reads it"
guest "./hello > result.txt; echo exit status \$?"
host "cat result.txt"

say "7. Host: the same run as one host command; tools/qnx-run returns the program's output and exit status"
host "qnx-run ./hello; echo \"exit status \$?\""

say "done: edit, build and run without copying the program into the guest"
host "rm -f hello hello.c hello.c.v1 result.txt"
} 2>&1 | tee "$LOG"
echo "log: $LOG"
