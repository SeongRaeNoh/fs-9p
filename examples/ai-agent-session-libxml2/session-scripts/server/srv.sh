#!/usr/bin/env bash
# server/srv.sh - the lab-server half of ../run.sh. run.sh sends this file over ssh and
# runs it on the lab server as "bash -s -- SUBCOMMAND ARG..."; no copy of it is kept there.
# Subcommands, options and exit statuses: see the header of ../run.sh.
# Folders on the lab server (printed as the names in brackets):
#   T/fs-9p              copy of the fs-9p tools (the same files as ../fs-9p/tools/ and the CMake
#                        toolchain file)                                          [REPO]
#   T/img/readme_image   copy of the image of tools/make-image.sh (output/ and local/)  [IMAGE]
#   T/share              the share; the guest sees it at /mnt/host               [SHARE]
#   T/linux              Linux reference build folder                            [LINUX_BUILD]
# The guest: QEMU on the lab server, ssh port 22349, started and stopped with
# tools/qnx-vm (directly, or by tools/qnx-ci.sh).
set -u
main() {
Q=[lab]
T=$Q/[task folder]
TR=$T/fs-9p
IMG=$T/img/readme_image
SH=$T/share
LB=$T/linux
KEY=[lab]/[ssh key of the image]
PORT=22349
OPTS=(-DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF)
LIMIT=540          # seconds for one ci or linux call (the session's Bash calls end after 600 s)
CI_TIME=400        # tools/qnx-run -t for each test in the guest (CI_TIMEOUT of tools/qnx-ci.sh)
. "$Q/qnx800/qnxsdp-env.sh" >/dev/null 2>&1
. "$Q/qemu/env.sh" >/dev/null 2>&1
. "$Q/[user]-cmake/env.sh" >/dev/null 2>&1
export QNX_SSH_PORT=$PORT QNX_SSH_KEY=$KEY
SDP=${QNX_TARGET:-}; SDP=${SDP%/target/*}; [ "$SDP" = "${QNX_TARGET:-}" ] && SDP=/nonexistent-sdp-path
hide() {
    sed -e "s|$SH|SHARE|g" -e "s|$IMG|IMAGE|g" -e "s|$TR|REPO|g" -e "s|$LB|LINUX_BUILD|g" \
        -e "s|$SDP|<QNX>|g" -e "s|$T|[lab]|g" -e "s|$Q|[lab]|g" -e "s|[lab home]|[lab home]|g" -e "s|[lab user]|[lab user]|g" |
}
say() { echo "run.sh: $*"; }
ours() { [ -f "$IMG/qnx-vm/qemu.pid" ] && kill -0 "$(cat "$IMG/qnx-vm/qemu.pid")" 2>/dev/null; }
need_port() {   # exit 3 when a VM that is not this session's guest uses the port
    local n; n=$(pgrep -f "[q]emu-system.*$PORT" | wc -l)
    ours && n=$((n - 1))
    [ "$n" -le 0 ] || { say "another VM on the lab server uses ssh port $PORT; the guest of this session cannot start now"; exit 3; }
}
QR() { QNX_SHARE=$SH "$TR/tools/qnx-run" "$@"; }
link_cores() {   # docs/usage.md, "Core files through the share"
    mkdir -p "$SH/cores" && chmod 777 "$SH/cores" &&
    QR -t 60 sh -c 'if [ ! -L /data/var/dumper ]; then mv /data/var/dumper /data/var/dumper.saved && ln -s /mnt/host/cores /data/var/dumper; fi' >/dev/null 2>&1 &&
    say "core files: the guest's dumper folder /data/var/dumper is a link to /mnt/host/cores (SHARE/cores on the host); ./run.sh run reports a new core file in core_file"
}
unlink_cores() {
    QR -t 60 sh -c 'if [ -L /data/var/dumper ] && [ -d /data/var/dumper.saved ]; then rm /data/var/dumper && mv /data/var/dumper.saved /data/var/dumper; fi' >/dev/null 2>&1
}
sp() {   # a path given relative to SHARE (or as SHARE/...) -> the server path; refuses ".." (status 64)
    case "$1" in *..*) say "path with '..' refused: $1" >&2; return 64 ;; esac
    case "$1" in SHARE) echo "$SH" ;; SHARE/*) echo "$SH/${1#SHARE/}" ;; "$SH"|"$SH"/*) echo "$1" ;;
        /*) say "absolute paths outside SHARE are refused: $1" >&2; return 64 ;; *) echo "$SH/$1" ;; esac
}
gdb_ok() {   # the gdb commands that ./run.sh gdb accepts
    case "$1" in *shell*|*'|'*|*';'*|*'`'*|*'$('*|*python*|*pipe*) return 1 ;; esac
    [[ "$1" =~ ^(bt|backtrace|where)(\ full)?(\ -?[0-9]+)?$ ]] && return 0
    [[ "$1" =~ ^(frame|f|up|down)(\ [0-9]+)?$ ]] && return 0
    [[ "$1" =~ ^info\ (frame|locals|args|source|line|symbol)(\ .*)?$ ]] && return 0
    [[ "$1" =~ ^(print|p|ptype|whatis|list|l)\ .+$ ]] && return 0
    return 1
}
sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
ci)
    local tests="" keep=0 a rc
    for a in "$@"; do
        case "$a" in --tests=*) tests=$a ;; --keep-vm) keep=1 ;; *) say "ci: unknown option $a"; exit 64 ;; esac
    done
    ours && { say "the guest of this session is running; run ./run.sh vm stop first (tools/qnx-ci.sh boots its own guest)"; exit 3; }
    need_port
    [ -f "$SH/src/libxml2/CMakeLists.txt" ] || { say "no sources in SHARE/src/libxml2"; exit 3; }
    rm -rf "$SH/ci/results"
    say "tools/qnx-ci.sh IMAGE SHARE SHARE/src/libxml2 ${OPTS[*]} $tests (CI_COVERAGE=0, CI_TIMEOUT=$CI_TIME, CI_KEEP_VM=$keep)"
    CI_COVERAGE=0 CI_TIMEOUT=$CI_TIME CI_KEEP_VM=$keep CI_OUT=$SH/ci/results \
        timeout -k 30 "$LIMIT" "$TR/tools/qnx-ci.sh" "$IMG" "$SH" "$SH/src/libxml2" "${OPTS[@]}" ${tests:+"$tests"} 2>&1 | hide
    rc=${PIPESTATUS[0]}
    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
        say "tools/qnx-ci.sh reached the limit of one run.sh call ($LIMIT s, a setting) and was stopped; the guest is stopped"
        "$TR/tools/qnx-vm" stop "$IMG" >/dev/null 2>&1; keep=0
    fi
    [ "$keep" = 1 ] && ours && link_cores
    say "tools/qnx-ci.sh exit status $rc"
    exit "$rc" ;;
junit)
    [ -f "$SH/ci/results/libxml2.junit.xml" ] || exit 1
    hide < "$SH/ci/results/libxml2.junit.xml"; exit 0 ;;
linux)
    local rc
    [ -f "$SH/src/libxml2/CMakeLists.txt" ] || { say "no sources in SHARE/src/libxml2"; exit 3; }
    mkdir -p "$LB"
    say "Linux reference: cmake -DCMAKE_BUILD_TYPE=Debug ${OPTS[*]} with the lab server's gcc, build folder LINUX_BUILD/libxml2"
    timeout -k 10 "$LIMIT" bash -c '
        cmake -S "$1/src/libxml2" -B "$2/libxml2" -DCMAKE_BUILD_TYPE=Debug '"${OPTS[*]}"' > "$2/configure.txt" 2>&1 ||
            { tail -30 "$2/configure.txt"; echo "run.sh: configure failed"; exit 2; }
        echo "== build"
        cmake --build "$2/libxml2" -j 8 2>&1 | grep -v -E "^\[ *[0-9]+%\] (Building|Linking|Built)"
        [ "${PIPESTATUS[0]}" = 0 ] || { echo "run.sh: build failed"; exit 2; }
        echo "== ctest (Linux)"
        shift 2
        ctest --test-dir "$0/libxml2" -j 4 --timeout 480 --output-on-failure "$@"' "$LB" "$SH" "$LB" "$@" 2>&1 | hide
    rc=${PIPESTATUS[0]}
    [ "$rc" = 124 ] && say "the Linux build and ctest reached the limit of one run.sh call ($LIMIT s, a setting) and were stopped"
    say "linux exit status $rc"
    exit "$rc" ;;
vm)
    case "${1:-}" in
    start)
        ours && { say "the guest is already running"; exit 0; }
        need_port
        mkdir -p "$SH"
        "$TR/tools/qnx-vm" start "$IMG" "$SH" "$PORT" 2>&1 | grep -v 'QEMU started (pid' | hide
        [ "${PIPESTATUS[0]}" = 0 ] || { say "the guest did not start"; "$TR/tools/qnx-vm" stop "$IMG" >/dev/null 2>&1; exit 1; }
        link_cores; exit 0 ;;
    stop)
        if ours; then unlink_cores; "$TR/tools/qnx-vm" stop "$IMG" 2>&1 | hide; else say "the guest of this session is not running"; fi
        exit 0 ;;
    status)
        if ours; then say "guest running (ssh port $PORT, share SHARE)"; else say "guest not running"; fi
        local n; n=$(pgrep -f "[q]emu-system.*$PORT" | wc -l); ours && n=$((n - 1))
        say "other VMs on ssh port $PORT: $n"; exit 0 ;;
    *) say "usage: ./run.sh vm start|stop|status"; exit 64 ;;
    esac ;;
run)
    local t=300 C="" hasld=0 prog o n
    local envs=()
    ours || { say "the guest is not running; start it with ./run.sh vm start (or ./run.sh ci --keep-vm)"; exit 3; }
    while [ $# -gt 0 ]; do
        case "$1" in
        -t) [[ "${2:-}" =~ ^[0-9]+$ ]] || { say "run: -t needs a number of seconds"; exit 64; }; t=$2; shift 2 ;;
        -C) C=$(sp "${2:-.}") || exit 64; shift 2 ;;
        -e) case "${2:-}" in LD_LIBRARY_PATH=*) hasld=1 ;; esac; envs+=(-e "${2//SHARE\//$SH/}"); shift 2 ;;
        --) shift; break ;;
        -*) say "run: unknown option $1"; exit 64 ;;
        *) break ;;
        esac
    done
    [ $# -ge 1 ] || { say "usage: ./run.sh run [-t SECONDS] [-C DIR] [-e VAR=VALUE]... PROGRAM [ARG...]"; exit 64; }
    [ "$hasld" = 1 ] || envs+=(-e "LD_LIBRARY_PATH=$SH/ci/libxml2")
    prog=$1; shift
    case "$prog" in */*) prog=$(sp "$prog") || exit 64 ;; esac
    local args=(); for a in "$@"; do args+=("${a//SHARE\//$SH/}"); done
    n=$(find "$SH/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l); o=$SH/runs/$(printf %03d $((n + 1)))
    mkdir -p "$o" "$SH/cores"
    QNX_SHARE=$SH QNX_CORE_DIR=$SH/cores "$TR/tools/qnx-run" --json -t "$t" -o "$o" -C "${C:-$SH}" "${envs[@]}" "$prog" "${args[@]}" 2>&1 | hide
    exit "${PIPESTATUS[0]}" ;;
gdb)
    [ $# -ge 3 ] || { say "usage: ./run.sh gdb PROGRAM CORE COMMAND... (paths relative to SHARE)"; exit 64; }
    local prog core c libdirs
    prog=$(sp "$1") || exit 64; core=$(sp "$2") || exit 64; shift 2
    local gargs=()
    for c in "$@"; do
        gdb_ok "$c" || { say "gdb command not accepted: '$c' (accepted: bt, bt full, bt N, frame N, up, down, info frame|locals|args|source|line|symbol, print/p EXPR, ptype, whatis, list/l)"; exit 64; }
        gargs+=(-ex "$c")
    done
    [ -f "$prog" ] && [ -f "$core" ] || { say "no such program or core file"; exit 64; }
    libdirs=$( { dirname "$prog"; find "$SH/ci/libxml2" -name '*.so*' -type f -printf '%h\n' 2>/dev/null; } | sort -u | paste -sd: )
    timeout 120 "${GDB:-ntox86_64-gdb}" -batch -nx -ex "set solib-search-path $libdirs" "${gargs[@]}" "$prog" "$core" 2>&1 | hide
    exit "${PIPESTATUS[0]}" ;;
files)
    local p; p=$(sp "${1:-.}") || exit 64
    LC_ALL=C ls -la "$p" 2>&1 | hide; exit 0 ;;
*)
    say "unknown subcommand '$sub' (ci, linux, vm, run, gdb, files)"; exit 64 ;;
esac
}
main "$@" < /dev/null
exit $?
