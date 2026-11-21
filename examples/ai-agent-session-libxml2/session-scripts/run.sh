#!/usr/bin/env bash
# run.sh - the session's only way to the QNX 8.0 guest and to the Linux reference build of the
# libxml2 clone in libxml2/. It wraps fs-9p's tools (copies in fs-9p/tools/; the same files are on
# the lab server). QNX SDP 8.0, QEMU and cmake are on a lab server; run.sh reaches it with ssh and
# sends server/srv.sh, which does the work there. The guest runs in QEMU on that server; fs-9p
# mounts the server folder SHARE at /mnt/host in the guest, so the guest runs the programs that
# qcc built into SHARE without copying them.
#
# usage: ./run.sh SUBCOMMAND [ARG...]   (call it by its absolute path; no cd needed)
#   ci [--tests=REGEX] [--keep-vm]
#        Copies libxml2/ (without .git) to SHARE/src/libxml2 on the server, then runs
#          tools/qnx-ci.sh IMAGE SHARE SHARE/src/libxml2 -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF [--tests=REGEX]
#        with CI_COVERAGE=0 and CI_TIMEOUT=400: boots the guest, builds libxml2 with qcc into
#        SHARE/ci/libxml2, runs libxml2's ctest suite in the guest (tools/qnx-run is the test
#        emulator), writes gdb's backtrace of each crashed test (core file in SHARE/ci/cores) into
#        the JUnit file, and stops the guest. --tests=REGEX runs only the matching tests (ctest -R).
#        --keep-vm leaves the guest running for "run" (CI_KEEP_VM=1). Tests that tools/qnx-ci.sh
#        cannot start in the guest (libxml2's script and catalog tests) are left out and named.
#        The JUnit file is copied to results/calls/NNN-ci.junit.xml.
#   linux [CTEST_ARG...]
#        Copies libxml2/ as "ci" does, builds it with the server's gcc (Debug, the same two options)
#        in LINUX_BUILD/libxml2 and runs ctest there (the Linux reference; extra arguments go to
#        ctest, for example -R testchar).
#   vm start|stop|status
#        tools/qnx-vm for this session's guest (ssh port 22349, share SHARE). "start" also links the
#        guest's dumper folder to SHARE/cores (docs/usage.md, "Core files through the share");
#        "stop" puts the folder back and stops QEMU.
#   run [-t SECONDS] [-C DIR] [-e VAR=VALUE]... PROGRAM [ARG...]
#        tools/qnx-run --json -t SECONDS (default 300) with QNX_CORE_DIR=SHARE/cores in the running
#        guest. PROGRAM: a path relative to SHARE (for example ci/libxml2/testchar, or
#        SHARE/ci/libxml2/testchar) or a guest command name without "/". -C DIR: working folder,
#        relative to SHARE (default SHARE). LD_LIBRARY_PATH is SHARE/ci/libxml2 unless you give
#        -e LD_LIBRARY_PATH=...; "SHARE/" in -e values and in ARGs becomes the server path.
#   gdb PROGRAM CORE COMMAND...
#        The SDP's ntox86_64-gdb on the server, batch mode, on PROGRAM and CORE (paths relative to
#        SHARE, for example ci/libxml2/NAME ci/cores/NAME.core). Each COMMAND is one gdb
#        command; accepted: bt, bt full, bt N, frame N, up, down, info frame|locals|args|source|
#        line|symbol, print/p EXPR, ptype EXPR, whatis EXPR, list/l ARG.
#   files [PATH]
#        ls -la of a folder or file of SHARE (default SHARE itself).
# Every call also writes its complete output to results/calls/NNN-SUBCOMMAND.txt (NNN counts the
# calls of the session). Server paths are printed as SHARE, IMAGE, REPO, LINUX_BUILD, <QNX> (the
# SDP installation) and [lab]. No run times are printed.
# Exit status: that of the wrapped tool (tools/qnx-ci.sh: 0 all passed, 1 a build or test failed,
# 2 bad usage or no VM; tools/qnx-run: the program's status, 128+N for signal N; ctest: 0 or 8);
# 3: the server, the sources or ssh port 22349 is not available; 64: bad usage of run.sh.
set -u
HERE=$(dirname "$(readlink -f "$0")")
HOST=[lab server]
T=[lab]/[task folder]
mkdir -p "$HERE/results/calls"
sub=${1:-}
[ $# -gt 0 ] && shift
n=$(find "$HERE/results/calls" -maxdepth 1 -name '[0-9][0-9][0-9]-*.txt' | wc -l)
num=$(printf %03d $((n + 1)))
case "$sub" in ci|linux|vm|run|gdb|files) ;; *)
    sed -n '/^# usage:/,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;; esac
log=$HERE/results/calls/$num-$sub.txt

remote() {   # remote SECONDS SUBCOMMAND ARG...: server/srv.sh on the lab server
    local t=$1; shift
    # the server's login banner goes to ssh's stderr and is dropped; srv.sh's own stderr comes on stdout
    timeout -k 10 "$t" ssh -q -o ConnectTimeout=15 -o ServerAliveInterval=30 -o BatchMode=yes "$HOST" \
        "bash -s -- $(printf '%q ' "$@") 2>&1" < "$HERE/server/srv.sh" 2>/dev/null
    local rc=$?
    [ "$rc" = 255 ] && echo "run.sh: the lab server did not answer (ssh exit status 255)"
    return "$rc"
}
sync_src() {
    timeout -k 10 300 rsync -a --delete --exclude=.git \
        -e "ssh -q -o ConnectTimeout=15 -o BatchMode=yes" --rsync-path="mkdir -p $T/share/src && rsync" \
        "$HERE/libxml2/" "$HOST:$T/share/src/libxml2/" 2>/dev/null ||
        { echo "run.sh: copying libxml2/ to the lab server failed (rsync exit status $?)"; return 3; }
    echo "run.sh: copied libxml2/ (without .git) to SHARE/src/libxml2"
}
work() {
    echo "== ./run.sh $sub $*"
    case "$sub" in
    ci)
        sync_src || return 3
        remote 590 ci "$@"; local rc=$?
        local j=$HERE/results/calls/$num-ci.junit.xml
        if remote 60 junit > "$j" 2>/dev/null && [ -s "$j" ]; then
            echo "run.sh: JUnit file copied to results/calls/$num-ci.junit.xml"
        else rm -f "$j"; fi
        return "$rc" ;;
    linux) sync_src || return 3; remote 590 linux "$@" ;;
    vm)    remote 300 vm "$@" ;;
    run)   remote 590 run "$@" ;;
    gdb)   remote 180 gdb "$@" ;;
    files) remote 60 files "$@" ;;
    esac
}
work "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
echo "run.sh: exit status $rc; complete output in results/calls/$num-$sub.txt" | tee -a "$log"
exit "$rc"
