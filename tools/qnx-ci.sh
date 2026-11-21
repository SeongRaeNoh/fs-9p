#!/usr/bin/env bash
# tools/qnx-ci.sh - one command for a team's own (self-hosted) test machine: boot the QNX 8.0 VM,
# build each CMake project with qcc into the shared folder, run its tests in the guest with
# ctest -j N --output-junit (tools/qnx-run is the test emulator, so every test program runs on the
# QNX kernel from /mnt/host), write a gcovr coverage report on the host from the .gcda files that
# the guest wrote through the share, and stop the VM. Nothing is copied into or out of the guest.
# With coverage on (the default), ctest runs one test at a time (-j 1), so that the coverage
# figures are the same in every run (see CI_COVERAGE below).
#
# usage: tools/qnx-ci.sh IMAGE_DIR SHARE_FOLDER PROJECT [OPTION...] [PROJECT [OPTION...]]...
#   IMAGE_DIR     image folder made by tools/make-image.sh; booted with tools/qnx-vm start
#   SHARE_FOLDER  host folder that the guest sees at /mnt/host; build folders go to
#                 SHARE_FOLDER/ci/NAME (NAME = base name of the project folder)
#   PROJECT       a CMake source folder. If its tests read files from the source tree, the folder
#                 must be inside SHARE_FOLDER too.
#   OPTION        applies to the PROJECT before it:
#                   -DVAR=VALUE      a CMake cache entry for the configure step
#                   --filter=REGEX   gcovr: report only source files whose path matches REGEX
#                   --exclude=REGEX  gcovr: leave out source files whose path matches REGEX
#                   --jobs=N         ctest -j N for this project (default CI_JOBS; only with
#                                    coverage off, see CI_COVERAGE); --jobs=1 for a suite whose
#                                    tests share fixed resources such as a TCP port
#                   --tests=REGEX    run only the tests whose name matches REGEX (ctest -R)
#                   --user=NAME      run this project's tests as the guest user NAME
#                                    (tools/qnx-run -u), for suites that refuse to run as root
#                   --timeout=N      time limit per test in seconds for this project (tools/qnx-run
#                                    -t N; ctest --timeout N+60); default CI_TIMEOUT
#                   --build-only     configure and build this project with qcc, run none of its
#                                    tests; after a successful build CI_OUT/NAME.built.txt names
#                                    the number of tests registered (no JUnit file, no coverage)
# Settings (environment):
#   QNX_SSH_PORT  host port forwarded to the guest's ssh port (default 2222), for tools/qnx-vm
#   QNX_SSH_KEY   private key for the guest login (the key of SSH_IDENT in tools/make-image.sh)
#   CI_JOBS       parallel build jobs; parallel tests (ctest -j) when coverage is off (default 4)
#   CI_TIMEOUT    time limit per test in seconds, tools/qnx-run -t (default 300); ctest gets
#                 --timeout CI_TIMEOUT+60 for tests without their own TIMEOUT property
#   CI_COVERAGE   1 (default): build with gcov counters and write coverage reports, and run the
#                 tests one at a time (ctest -j 1; CI_JOBS then sets only the build's -j, and
#                 --jobs=N has no effect). Reason: when a test program ends, the gcov runtime
#                 adds its counts to the .gcda file of each object file it ran, and the test
#                 programs of one project share object files (a library linked into several of
#                 them). With ctest -j 4 the line count of one file differed between runs
#                 (cause not traced; two programs that update one .gcda file at the same time
#                 are the likely reason: fs-9p does not share fcntl() record locks between two
#                 opens, docs/usage.md, Limitations).
#                 0: plain build; the tests run with ctest -j N
#   CI_OUT        folder for the reports (default SHARE_FOLDER/ci/results): NAME.junit.xml (ctest),
#                 NAME.coverage.txt and NAME.cobertura.xml (gcovr); NAME.built.txt (--build-only)
#   CI_KEEP_VM    1: leave the VM running at the end (default: stop it, also after an error)
#   GCOVR         gcovr command (default gcovr); GCOV: gcov of QNX SDP 8.0 (default ntox86_64-gcov)
#   CI_CORES      1 (default): backtraces of crashed tests (below); 0: off
#   GDB           gdb of QNX SDP 8.0 for the core files (default ntox86_64-gdb); CI_BT_FRAMES: number
#                 of frames (default 20)
# Needs: the QNX SDP 8.0 environment (qcc), cmake and ctest 3.21 or newer, gcovr for coverage, QEMU.
# Each test program gets LD_LIBRARY_PATH = its project's build folder (shared libraries of the
# project load from the share) and, with coverage, GCOV_PREFIX and GCOV_PREFIX_STRIP, so that the
# guest writes each .gcda file next to its object file in the host build folder.
# Tests that CMake does not start through the emulator: CMake adds CMAKE_CROSSCOMPILING_EMULATOR
# only to tests registered as add_test(NAME n COMMAND target). A test registered as add_test(n prog)
# or with a path as its command would run on Linux. After the build, qnx-ci.sh reads every
# CTestTestfile.cmake of the build folder: a test whose command is a program of the build folder
# (an ELF file built with qcc) gets tools/qnx-run in front of it, in that generated file only (the
# project's sources are not changed); a test whose command is anything else (for example sh with a
# script) would run on Linux, so it is left out of the run (ctest -E) and named in the output.
# Crashed tests (CI_CORES=1): after the boot, qnx-ci.sh asks the guest for the dump folder of QNX's
# dumper (option -d in pidin -p dumper -F '%A'), replaces that folder by a link to
# SHARE_FOLDER/ci/cores for this run and puts it back at the end, so that the guest writes every
# core file through the share. A test counts as crashed when it failed and its output holds
# "(core dumped)", which the guest's shell prints when the test program itself ended by a signal
# with a core file (a deliberately crashing child process that the test waits for does not count).
# For each crashed test, qnx-ci.sh opens the newest core file of the test's program with the SDP's
# gdb on the host (solib-search-path: the folders of the build folder that hold shared libraries)
# and writes the backtrace into that test's <failure> element of the JUnit file; the failure
# message names the signal, the core file and the first frame in the project with file and line.
# Frames in the project (a source file in the project or build folder) keep their file and line;
# frames elsewhere (the C library and other system libraries) are shown by function name only,
# and a run of more than two such frames is shortened to its first and last frame.
# Output: per project the counts of tests started through tools/qnx-run and of tests left out, the
# ctest result lines (without times), the counts from the JUnit file (with the full output of
# every test), the backtrace of each crashed test and the gcovr summary (for a --build-only
# project only the number of tests registered); a last line "RESULT: ...".
# Paths in the output: the share, the repository, the image folder and the SDP installation (the
# folder above $QNX_TARGET's target/) are printed as SHARE, REPO, IMAGE and <QNX>.
# Exit status: 0 if every project was built and every test that ran passed; 1 if a build or a test
# failed; 2 on bad usage or if the VM did not start.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
me=qnx-ci
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
QR=$REPO/tools/qnx-run
QV=$REPO/tools/qnx-vm
die() { echo "$me: $*" >&2; exit 2; }
[ $# -ge 3 ] || die "usage: tools/qnx-ci.sh IMAGE_DIR SHARE_FOLDER PROJECT [-DVAR=VALUE|--filter=RE|--exclude=RE|--jobs=N|--tests=RE|--user=NAME|--timeout=N|--build-only]... [PROJECT ...]"
IMG=$1 SHARE=$2; shift 2
[ -d "$IMG" ] || die "$IMG is not a folder"
IMG=$(cd "$IMG" && pwd -P)
mkdir -p "$SHARE" && SHARE=$(cd "$SHARE" && pwd -P) || die "cannot create $SHARE"
JOBS=${CI_JOBS:-4}; TLIM=${CI_TIMEOUT:-300}; COV=${CI_COVERAGE:-1}
[[ $TLIM =~ ^[0-9]+$ ]] || die "CI_TIMEOUT=$TLIM: not a number of seconds"
OUT=${CI_OUT:-$SHARE/ci/results}
GCOVR=${GCOVR:-gcovr}; GCOV=${GCOV:-ntox86_64-gcov}
CORES=${CI_CORES:-1}; GDB=${GDB:-ntox86_64-gdb}; FRAMES=${CI_BT_FRAMES:-20}
[[ $FRAMES =~ ^[1-9][0-9]*$ ]] || die "CI_BT_FRAMES=$FRAMES: not a number"
MOUNT=${QNX_MOUNT:-/mnt/host}
for c in qcc cmake ctest; do command -v $c >/dev/null || die "$c not found (source qnxsdp-env.sh; cmake 3.21 or newer)"; done
[ "$COV" = 1 ] && { $GCOVR --version >/dev/null 2>&1 || die "gcovr not found (GCOVR=...; or CI_COVERAGE=0)"; }

# projects: NAMES[i], SRCS[i], CMAKE_OPTS[i] and GCOVR_OPTS[i] (options separated by newlines)
NAMES=() SRCS=() CMAKE_OPTS=() GCOVR_OPTS=() PJOBS=() PTESTS=() PUSER=() PTLIM=() PBUILD=()
for a in "$@"; do
    case "$a" in
    -D*)      [ ${#SRCS[@]} -gt 0 ] || die "$a comes before any PROJECT"
              CMAKE_OPTS[-1]+="$a"$'\n' ;;
    --filter=*|--exclude=*)
              [ ${#SRCS[@]} -gt 0 ] || die "$a comes before any PROJECT"
              GCOVR_OPTS[-1]+="${a%%=*}"$'\n'"${a#*=}"$'\n' ;;
    --jobs=*) [ ${#SRCS[@]} -gt 0 ] || die "$a comes before any PROJECT"
              [[ ${a#*=} =~ ^[1-9][0-9]*$ ]] || die "bad $a"
              PJOBS[-1]=${a#*=} ;;
    --tests=*) [ ${#SRCS[@]} -gt 0 ] || die "$a comes before any PROJECT"
              PTESTS[-1]=${a#*=} ;;
    --user=*) [ ${#SRCS[@]} -gt 0 ] || die "$a comes before any PROJECT"
              [[ ${a#*=} =~ ^[A-Za-z0-9_.-]+$ ]] || die "bad $a"
              PUSER[-1]=${a#*=} ;;
    --timeout=*) [ ${#SRCS[@]} -gt 0 ] || die "$a comes before any PROJECT"
              [[ ${a#*=} =~ ^[1-9][0-9]*$ ]] || die "bad $a"
              PTLIM[-1]=${a#*=} ;;
    --build-only) [ ${#SRCS[@]} -gt 0 ] || die "$a comes before any PROJECT"
              PBUILD[-1]=1 ;;
    -*)       die "unknown option $a" ;;
    *)        [ -f "$a/CMakeLists.txt" ] || die "$a: no CMakeLists.txt"
              s=$(cd "$a" && pwd -P); n=$(basename "$s")
              for x in "${NAMES[@]}"; do [ "$x" = "$n" ] && die "two projects named $n"; done
              NAMES+=("$n") SRCS+=("$s") CMAKE_OPTS+=("") GCOVR_OPTS+=("") PJOBS+=("$JOBS") PTESTS+=("") PUSER+=("") PTLIM+=("$TLIM") PBUILD+=(0) ;;
    esac
done
[ ${#SRCS[@]} -gt 0 ] || die "no PROJECT given"

# the SDP installation folder: $QNX_TARGET is <installation>/target/qnx
SDP=${QNX_TARGET:-}; SDP=${SDP%/target/*}; [ "$SDP" = "${QNX_TARGET:-}" ] && SDP=
hide_args=(-e "s|$SHARE|SHARE|g" -e "s|$REPO|REPO|g" -e "s|$IMG|IMAGE|g")
[ -n "$SDP" ] && hide_args+=(-e "s|$SDP|<QNX>|g")
hide() { sed "${hide_args[@]}"; }

# route_tests BUILD EMULATOR_ARGUMENT...: put the emulator in front of every test command in the
# generated CTestTestfile.cmake files that is a program of BUILD and does not have it yet; sets
# n_emu (tests started through the emulator), n_wrapped (of these, the ones changed here), n_env
# (tests with an ENVIRONMENT property), host_names (tests whose command is not such a program),
# tprog[NAME] (the host path of the program that each test started through the emulator runs).
declare -A tprog
route_tests() {
    local B=$1 emu_q="" a f d line name nm cmd rest wd p out toks
    shift
    for a in "$@"; do emu_q+="\"$a\" "; done
    n_emu=0 n_wrapped=0 host_names=() tprog=()
    n_env=$(find "$B" -name CTestTestfile.cmake -exec grep -h '^set_tests_properties(' {} + | grep -c ' ENVIRONMENT ')
    while IFS= read -r f; do
        d=$(dirname "$f") out=""
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ $line =~ ^add_test\((\[=\[[^]]*\]=\]|[^\ \"]+)\ \"([^\"]*)\"(.*)$ ]]; then
                name=${BASH_REMATCH[1]} cmd=${BASH_REMATCH[2]} rest=${BASH_REMATCH[3]}
                nm=${name#\[=\[}; nm=${nm%\]=\]}
                if [ "$cmd" = "$1" ]; then
                    n_emu=$((n_emu + 1))
                    # the program is the first argument after the emulator's own arguments
                    mapfile -t toks < <(printf '%s' "$rest" | grep -o '"[^"]*"')
                    p=${toks[$#-1]:-}; p=${p#\"}; p=${p%\"}
                    [ -n "$p" ] && tprog[$nm]=$p
                else
                    wd=$(grep -F "set_tests_properties($name " "$f" | grep -o 'WORKING_DIRECTORY "[^"]*"' | head -1 | cut -d'"' -f2)
                    case $cmd in
                    /*)  p=$cmd ;;
                    */*) p=${wd:-$d}/$cmd ;;
                    *)   p=$d/$cmd; [ -f "$p" ] || p=${wd:-$d}/$cmd ;;
                    esac
                    [ -f "$p" ] && p=$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")
                    if [ -f "$p" ] && [[ $p == "$B"/* ]] && [ "$(head -c 4 "$p" | tr -d '\000')" = $'\177ELF' ]; then
                        line="add_test($name $emu_q\"$p\"$rest"
                        n_emu=$((n_emu + 1)) n_wrapped=$((n_wrapped + 1)) tprog[$nm]=$p
                    else
                        host_names+=("$nm")
                    fi
                fi
            fi
            out+=$line$'\n'
        done < "$f"
        printf '%s' "$out" > "$f"
    done < <(find "$B" -name CTestTestfile.cmake)
}

# clean_bt SOURCE BUILD < gdb output: "Core was generated by", "Program terminated with signal" and the
# frames of the last backtrace (gdb also prints frame #0 once when it loads the core). Frames in
# SOURCE or BUILD keep file and line (a function name with arguments longer than 160 characters
# becomes "FUNCTION (...)");
# other frames are shown as "#N  FUNCTION () (outside the project)", and a run of more than two of
# them is shortened to its first frame, one line with the numbers of the others, and its last frame.
clean_bt() {
    awk -v src="$1" -v bld="$2" '
    function inproj(f) { return index(f, src "/") == 1 || index(f, bld "/") == 1 }
    /^Core was generated by / { gen = $0; next }
    /^Program terminated with signal / { sig = $0; next }
    /^#[0-9]+ / {
        num = substr($1, 2) + 0
        if (num == 0) { nf = 0; more = 0 }
        rest = $0; sub(/^#[0-9]+ +/, "", rest); sub(/^0x[0-9a-fA-F]+ in /, "", rest)
        fn = rest; sub(/ .*/, "", fn)
        loc = ""; file = ""
        if (match(rest, / at [^ ]+:[0-9]+$/)) { loc = substr(rest, RSTART); file = substr(rest, RSTART + 4); sub(/:[0-9]+$/, "", file) }
        if (file != "" && inproj(file)) {
            head = substr(rest, 1, length(rest) - length(loc))
            if (length(head) > 160) rest = fn " (...)" loc
            out[nf] = sprintf("#%-2d %s", num, rest); kind[nf] = "p"
        } else {
            out[nf] = sprintf("#%-2d %s () (outside the project)", num, fn); kind[nf] = "o"
        }
        fno[nf] = num; nf++
        next
    }
    /^\(More stack frames follow/ { more = 1 }
    END {
        if (gen != "") print gen
        if (sig != "") print sig
        i = 0
        while (i < nf) {
            if (kind[i] == "p") { print out[i]; i++; continue }
            j = i; while (j + 1 < nf && kind[j + 1] == "o") j++
            if (j - i >= 2) {
                print out[i]
                if (j - i == 2) printf "#%-2d (1 frame outside the project)\n", fno[i + 1]
                else printf "#%d-#%d (%d frames outside the project)\n", fno[i + 1], fno[j - 1], j - i - 1
                print out[j]
            } else for (k = i; k <= j; k++) print out[k]
            i = j + 1
        }
        if (more) print "(more frames follow; CI_BT_FRAMES sets how many are shown)"
    }'
}

# junit_failure JUNIT LIST: LIST has lines "TEST<tab>MESSAGE<tab>FILE"; the <failure .../> element of
# each named test case becomes <failure message="MESSAGE" type="crash">contents of FILE</failure>
junit_failure() {
    awk -v list="$2" '
    function esc(x,   o, c, i) {
        o = ""
        for (i = 1; i <= length(x); i++) {
            c = substr(x, i, 1)
            if (c == "&") o = o "&amp;"; else if (c == "<") o = o "&lt;"; else if (c == ">") o = o "&gt;"
            else if (c == "\"") o = o "&quot;"; else o = o c
        }
        return o
    }
    BEGIN {
        while ((getline l < list) > 0) {
            k = index(l, "\t"); nm = esc(substr(l, 1, k - 1)); r = substr(l, k + 1)
            k = index(r, "\t"); msg[nm] = substr(r, 1, k - 1); bf[nm] = substr(r, k + 1)
        }
    }
    /<testcase / { cur = ""; if (match($0, /name="[^"]*"/)) cur = substr($0, RSTART + 6, RLENGTH - 7) }
    (cur in msg) && match($0, /<failure message="[^"]*"\/>/) {
        body = ""; f = bf[cur]
        while ((getline l < f) > 0) body = body esc(l) "\n"
        close(f)
        printf "%s<failure message=\"%s\" type=\"crash\">%s</failure>%s\n", substr($0, 1, RSTART - 1), esc(msg[cur]), body, substr($0, RSTART + RLENGTH)
        delete msg[cur]
        next
    }
    { print }' "$1"
}

# backtraces BUILD SOURCE JUNIT STAMP: for every crashed test of the project (see the header) find
# the newest core file of its program written after STAMP, print the backtrace and write it into
# the JUnit file; sets n_bt (number of backtraces written)
backtraces() {
    local B=$1 s=$2 J=$3 stamp=$4 t prog base core i last sz libdirs bt sig top msg k=0 list
    local crashed=()
    n_bt=0
    mapfile -t crashed < <(awk '
        /<testcase / { cur = ""; fail = 0; cd = 0
                       if (match($0, /name="[^"]*"/)) cur = substr($0, RSTART + 6, RLENGTH - 7)
                       if ($0 ~ /status="fail"/) fail = 1 }
        /\(core dumped\)/ { cd = 1 }
        /<\/testcase>/ { if (cur != "" && fail && cd) print cur; cur = "" }' "$J" |
        sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g')
    [ ${#crashed[@]} -gt 0 ] || return 0
    echo "crashed tests (failed; the guest shell printed \"(core dumped)\"): ${#crashed[@]}"
    if ! command -v "$GDB" >/dev/null; then echo "  $GDB not found: no backtraces"; return 0; fi
    libdirs=$( { echo "$B"; find "$B" -name '*.so*' -type f -printf '%h\n'; } | sort -u | paste -sd: )
    list=$B.backtraces; : > "$list"
    for t in "${crashed[@]}"; do
        prog=${tprog[$t]:-}
        if [ -z "$prog" ] || [ ! -f "$prog" ]; then echo "-- $t: no backtrace: its program is not a program of the build folder"; continue; fi
        base=$(basename "$prog")
        # dumper writes the core file after the program has ended: wait until the newest core
        # file of the program keeps its size for 1 s (at most 20 s)
        i=0 last=-1 core=
        while [ $i -lt 20 ]; do
            core=$(find "$cores_host" -maxdepth 1 -type f -name "$base.core*" -newer "$stamp" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
            sz=-1; [ -n "$core" ] && sz=$(stat -c %s "$core" 2>/dev/null || echo -1)
            [ "$sz" -gt 0 ] && [ "$sz" = "$last" ] && break
            last=$sz; sleep 1; i=$((i + 1))
        done
        if [ -z "$core" ]; then echo "-- $t: no backtrace: no core file of $base in SHARE/ci/cores"; continue; fi
        k=$((k + 1)); bt=$B.backtrace.$k.txt
        "$GDB" -batch -ex "set solib-search-path $libdirs" -ex "bt $FRAMES" "$prog" "$core" 2>&1 | clean_bt "$s" "$B" > "$bt"
        if ! grep -q '^#' "$bt"; then echo "-- $t: no backtrace: $GDB printed no frames for $(basename "$core")"; continue; fi
        sig=$(sed -n 's/^Program terminated with signal \([A-Z0-9]*\).*/\1/p' "$bt" | head -1)
        top=$(grep -m1 -E ' at [^ ]+:[0-9]+$' "$bt" | sed -E 's/^#[0-9]+ +([^ ]+) .* at ([^ ]+)$/\1 at \2/')
        top=${top//"$s/"/}; top=${top//"$B/"/build folder/}
        msg="crashed${sig:+ with $sig}; core file $(basename "$core"); first frame in the project: ${top:-none}"
        printf '%s\t%s\t%s\n' "$t" "$msg" "$bt" >> "$list"
        n_bt=$((n_bt + 1))
        echo "-- $t: $msg"
        echo "   backtrace ($GDB, core file $(echo "$core" | hide)):"
        sed 's/^/   /' "$bt" | hide
    done
    if [ "$n_bt" -gt 0 ]; then
        junit_failure "$J" "$list" > "$J.tmp" && mv "$J.tmp" "$J"
        echo "JUnit file $(basename "$J"): backtraces written into the <failure> element of $n_bt test case(s): $(grep -c 'type="crash"' "$J") found"
    fi
}

started=0 cores_guest= cores_host=
# the guest commands of qnx-ci.sh itself (uname, the dumper folder) run with a time limit of 60 s, so
# that a guest that no longer answers cannot hold the run (tools/qnx-run ends ssh 30 s after -t)
finish() {
    if [ -n "$cores_guest" ]; then
        if "$QR" -t 60 sh -c "rm '$cores_guest' && mv '$cores_guest.qnx-ci' '$cores_guest'" >/dev/null 2>&1; then
            echo; echo "core files: the guest's dumper folder $cores_guest is restored"
        else
            echo; echo "core files: $cores_guest could not be restored (the old folder is $cores_guest.qnx-ci in the guest)"
        fi
    fi
    if [ "$started" = 1 ] && [ "${CI_KEEP_VM:-0}" != 1 ]; then
        echo; echo "== stop the VM: tools/qnx-vm stop"; "$QV" stop "$IMG" | hide
    fi
}
trap finish EXIT

echo "== $me: ${#SRCS[@]} project(s); ctest -j $([ "$COV" = 1 ] && echo "1 (coverage on: one test at a time)" || echo "$JOBS"); time limit $TLIM s per test (tools/qnx-run -t, a setting; --timeout=N of a project overrides it); coverage $([ "$COV" = 1 ] && echo on || echo off)"
echo "== boot the VM: tools/qnx-vm start IMAGE SHARE ${QNX_SSH_PORT:-2222}"
"$QV" status "$IMG" >/dev/null 2>&1 && die "a VM of $IMG already runs; stop it first (tools/qnx-vm stop)"
started=1   # from here on, the EXIT trap stops the VM (tools/qnx-vm start leaves it running on a time-out)
"$QV" start "$IMG" "$SHARE" "${QNX_SSH_PORT:-2222}" 2>&1 | grep -v 'QEMU started (pid' | hide
[ "${PIPESTATUS[0]}" = 0 ] || { echo "$me: the VM did not start" >&2; exit 2; }
export QNX_IMAGE=$IMG QNX_SHARE=$SHARE
echo "guest: $("$QR" -t 60 uname -sr)"
mkdir -p "$OUT"
# core files through the share (see the header)
if [ "$CORES" = 1 ]; then
    ddir=$("$QR" -t 60 pidin -p dumper -F '%A' 2>/dev/null | sed 1d | sed 's/^/ /' |
           sed -n 's/.*[[:space:]]-d[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
    if [ -z "$ddir" ]; then
        echo "core files: no dumper with a dump folder (-d) runs in the guest; crashed tests get no backtrace"
    elif mkdir -p "$SHARE/ci/cores" && chmod 777 "$SHARE/ci/cores" && rm -f "$SHARE/ci/cores/"*.core* &&
         "$QR" -t 60 sh -c "if [ -L '$ddir' ] && [ -d '$ddir.qnx-ci' ]; then rm '$ddir'; else mv '$ddir' '$ddir.qnx-ci'; fi && ln -s '$MOUNT/ci/cores' '$ddir'" >/dev/null 2>&1; then
        cores_guest=$ddir cores_host=$SHARE/ci/cores
        echo "core files: the guest's dumper folder $ddir is a link to $MOUNT/ci/cores (SHARE/ci/cores on the host) during this run"
    else
        echo "core files: $ddir could not be linked into the share; crashed tests get no backtrace"
    fi
fi
# the guest sees SHARE as MOUNT: GCOV_PREFIX_STRIP drops SHARE's components from each .gcda path
strip=$(printf '%s' "$SHARE" | tr -cd / | wc -c)

total=0 failed=0 bad=0 bt_total=0 built_only=0
for i in "${!SRCS[@]}"; do
    n=${NAMES[$i]} s=${SRCS[$i]} B=$SHARE/ci/${NAMES[$i]} pj=${PJOBS[$i]} tl=${PTLIM[$i]}
    [ "$COV" = 1 ] && pj=1   # coverage on: one test at a time (header, CI_COVERAGE)
    echo
    echo "== project $((i + 1)) of ${#SRCS[@]}: $n ($(echo "$s" | hide)); build folder $(echo "$B" | hide), seen as $MOUNT/ci/$n in the guest"
    emu_args=("$QR" -t "$tl" -e "LD_LIBRARY_PATH=$B")
    [ "$tl" != "$TLIM" ] && echo "time limit $tl s per test for this project (--timeout; tools/qnx-run -t $tl, a setting)"
    [ -n "${PUSER[$i]}" ] && { emu_args+=(-u "${PUSER[$i]}"); echo "tests run as the guest user ${PUSER[$i]} (tools/qnx-run -u)"; }
    flags=""
    if [ "$COV" = 1 ]; then
        emu_args+=(-e "GCOV_PREFIX=$MOUNT" -e "GCOV_PREFIX_STRIP=$strip")
        flags="-O0 -fprofile-arcs -ftest-coverage -fprofile-update=atomic"
    fi
    emu=$(IFS=';'; echo "${emu_args[*]}")
    mapfile -t copts < <(printf '%s' "${CMAKE_OPTS[$i]}")
    [ ${#copts[@]} -gt 0 ] && echo "CMake options: ${copts[*]}"
    rm -rf "$B"; rm -f "$B".configure.txt "$B".build.txt "$B".ctest.txt "$B".gcovr.txt "$B".stamp "$B".backtraces "$B".backtrace.*.txt
    mkdir -p "$B"
    rm -f "$OUT/$n.junit.xml" "$OUT/$n.coverage.txt" "$OUT/$n.cobertura.xml" "$OUT/$n.built.txt"   # no report of an earlier run
    if cmake -S "$s" -B "$B" -DCMAKE_TOOLCHAIN_FILE="$REPO/examples/qnx-unit/qnx-x86_64.cmake" \
            -DCMAKE_BUILD_TYPE=Debug ${flags:+-DCMAKE_C_FLAGS="$flags"} \
            -DCMAKE_CROSSCOMPILING_EMULATOR="$emu" "${copts[@]}" > "$B.configure.txt" 2>&1 &&
       cmake --build "$B" -j "$JOBS" > "$B.build.txt" 2>&1; then
        echo "configure and build with qcc: ok ($(grep -m1 'The C compiler identification' "$B.configure.txt" | sed 's/^-- //'))"
    else
        # last lines of both files, without the times that CMake prints after "Configuring done"
        echo "configure or build failed; last lines:"
        tail -n 15 "$B.configure.txt" "$B.build.txt" | sed -E 's/^(-- [A-Za-z]+ done) \([0-9.]+s\)$/\1/' | hide
        bad=$((bad + 1)); continue
    fi
    nreg=$(ctest --test-dir "$B" -N | sed -n 's/^Total Tests: //p')
    echo "tests registered: $nreg"
    if [ "${PBUILD[$i]}" = 1 ]; then
        echo "tests not run (--build-only)"
        echo "configured and built with qcc; tests registered: $nreg; tests not run (--build-only)" > "$OUT/$n.built.txt"
        built_only=$((built_only + 1)); continue
    fi
    route_tests "$B" "${emu_args[@]}"
    echo "tests started through tools/qnx-run: $n_emu ($n_wrapped of them registered without the emulator and changed in the build folder's CTestTestfile.cmake)"
    skip=()
    if [ ${#host_names[@]} -gt 0 ]; then
        echo "tests left out: ${#host_names[@]}; their command is not a program of the build folder, so they would run on Linux: ${host_names[*]}"
        re=$(printf '%s\n' "${host_names[@]}" | sed 's/[][\.*^$+?(){}|/]/\\&/g' | paste -sd'|')
        skip=(-E "^($re)\$")
    fi
    [ "$n_env" -gt 0 ] && echo "note: $n_env tests set variables with the ENVIRONMENT test property; tools/qnx-run does not pass them to the guest"
    J=$OUT/$n.junit.xml; rm -f "$J"
    sel=(); [ -n "${PTESTS[$i]}" ] && sel=(-R "${PTESTS[$i]}")
    echo "-- ctest --test-dir BUILD -j $pj --timeout $((tl + 60)) --output-on-failure --output-junit $(echo "$J" | hide)${sel:+ -R ${PTESTS[$i]}}${skip:+ -E (the tests left out)}"
    touch "$B.stamp"
    ctest --test-dir "$B" -j "$pj" --timeout $((tl + 60)) --test-output-size-passed 1048576 \
        --test-output-size-failed 1048576 --output-on-failure --output-junit "$J" ${sel[@]+"${sel[@]}"} ${skip[@]+"${skip[@]}"} > "$B.ctest.txt" 2>&1
    rc=$?
    # per-test lines and the summary, without the time values that ctest prints
    sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' "$B.ctest.txt" |
        grep -E 'Test +#|tests passed|tests failed|^The following tests|^\s+[0-9]+ - ' | hide
    echo "ctest exit status $rc"
    # a count, not a time: how many tests ctest had started when the first test ended
    echo "tests started before the first test ended: $(awk '/Test +#[0-9]+:/ { exit } /^ *Start +[0-9]+:/ { n++ } END { print n + 0 }' "$B.ctest.txt")"
    [ "$rc" = 0 ] || echo "full ctest output (with the failed tests' output): $(echo "$B.ctest.txt" | hide)"
    if [ -f "$J" ]; then
        tc=$(grep -c '<testcase' "$J")
        head=$(tr '\n\t' '  ' < "$J" | grep -o '<testsuite [^>]*')   # ctest writes one attribute per line
        tf=$(printf '%s' "$head" | grep -o 'failures="[0-9]*"' | grep -o '[0-9]\+')
        ts=$(printf '%s' "$head" | grep -o 'skipped="[0-9]*"' | grep -o '[0-9]\+')
        echo "JUnit file $(basename "$J"): $tc test cases, ${tf:-?} failures, ${ts:-?} skipped"
    else
        echo "JUnit file $(basename "$J"): missing"
    fi
    n_bt=0
    [ -n "$cores_host" ] && [ -f "$J" ] && [ "$rc" != 0 ] && backtraces "$B" "$s" "$J" "$B.stamp"
    bt_total=$((bt_total + n_bt))
    t=$(sed -n -E 's/.*tests? failed out of ([0-9]+).*/\1/p' "$B.ctest.txt" | tail -1)
    f=$(sed -n -E 's/.* ([0-9]+) tests? failed out of.*/\1/p' "$B.ctest.txt" | tail -1)
    total=$((total + ${t:-0})); failed=$((failed + ${f:-0}))
    [ "$rc" = 0 ] || bad=$((bad + 1))
    if [ "$COV" = 1 ]; then
        echo "-- coverage: $(find "$B" -name '*.gcda' | wc -l) .gcda files written by the guest into the build folder; gcovr with $GCOV"
        mapfile -t gopts < <(printf '%s' "${GCOVR_OPTS[$i]}")
        # search only the folders that hold .gcda files, that is, the object files of the programs
        # and libraries that ran in the guest (CMake's compiler check leaves a .gcno file without
        # a source file, which gcovr cannot resolve)
        mapfile -t dirs < <(find "$B" -name '*.gcda' -printf '%h\n' | sort -u)
        if [ ${#dirs[@]} -gt 0 ] &&
           $GCOVR --root "$s" --object-directory "$B" --gcov-executable "$GCOV" "${gopts[@]}" \
                --txt "$OUT/$n.coverage.txt" --cobertura "$OUT/$n.cobertura.xml" --print-summary "${dirs[@]}" \
                > "$B.gcovr.txt" 2>&1; then
            grep -E '^(lines|branches):' "$B.gcovr.txt"
            echo "files in $n.coverage.txt (lines: total, executed, percent):"
            grep -E '^[^ -]+ +[0-9]+ +[0-9]+ +[0-9]+%' "$OUT/$n.coverage.txt" |
                awk '{ printf "  %-28s %6s %6s %5s\n", $1, $2, $3, $4 }'
        else
            echo "gcovr failed:"; tail -5 "$B.gcovr.txt" | hide
        fi
    fi
done

echo
res="${#SRCS[@]} project(s), $total tests in the QNX guest with ctest, $failed failed"
[ "$built_only" -gt 0 ] && res+="; $built_only project(s) only built (--build-only)"
[ "$bad" -gt 0 ] && res+="; $bad project(s) with a build or test failure"
[ "$bt_total" -gt 0 ] && res+="; $bt_total crashed test(s) with a gdb backtrace in the JUnit file"
echo "RESULT: $res"
echo "reports: $(echo "$OUT" | hide)/"
[ "$bad" = 0 ]
