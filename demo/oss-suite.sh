#!/usr/bin/env bash
# demo/oss-suite.sh - existing open-source C projects, unmodified, run their own test suites in the
# QNX 8.0 guest. The script fetches each project at a fixed tag, builds it with qcc and runs its
# ctest suite in the guest with tools/qnx-ci.sh (every test program starts from the shared folder
# through tools/qnx-run). For comparison it builds the same sources with the host compiler and runs
# the same suite on Linux. No file of these projects is part of this repository, and no file of
# their sources is changed: the script prints the number of changed tracked files of each clone.
#
# usage: demo/oss-suite.sh IMAGE_DIR SHARE_FOLDER [NAME...]
#   IMAGE_DIR     image folder made by tools/make-image.sh (as for tools/qnx-ci.sh); no VM of it may
#                 run, because tools/qnx-ci.sh boots and stops it
#   SHARE_FOLDER  host folder that the guest sees at /mnt/host. Sources go to SHARE_FOLDER/oss-src/NAME
#                 (inside the share, because several suites read data files from their source
#                 tree), QNX builds to SHARE_FOLDER/ci/NAME, Linux builds to SHARE_FOLDER/oss-linux/NAME,
#                 JUnit files to SHARE_FOLDER/oss-results/{qnx,linux}/NAME.junit.xml
#   NAME          projects to run (default: all projects of the table below)
# Settings (environment): those of tools/qnx-ci.sh (QNX_SSH_PORT, QNX_SSH_KEY, CI_JOBS, CI_TIMEOUT;
#   this script sets CI_COVERAGE=0 and CI_TIMEOUT=1500 unless given), OSS_LINUX=0 to skip the Linux
#   runs, OSS_FETCH=0 to keep existing clones, OSS_QNX_OPTS=0 to build without the QNX-only
#   options of the table (shows why they are there), PYTHON (python 3 for the table, default python3).
# Needs: git, the QNX SDP 8.0 environment (qcc), a host C compiler, cmake and ctest 3.21 or newer,
#   QEMU, python 3, network access to the repositories (and to unicode.org: utf8proc's CMake file
#   downloads two Unicode data files for its tests).
# Output: per project the Linux result and the output of tools/qnx-ci.sh, then one table with the
#   counts of tests run, passed, failed and skipped on QNX and on Linux, the counts of the test
#   cases inside the programs where a program reports them (TAP lines; Check's "Checks:" line),
#   and the tests that failed only on QNX with the first lines of their output, then the CMake cache
#   entries named by "show:" options. No times. A copy
#   goes to tests/logs/oss_<date>.log. Before the runs the script deletes the JUnit files of the
#   selected projects from an earlier run (the Linux ones only when the Linux runs are on), so that
#   the table shows only this run. Paths in the output: the share, the repository, the image folder,
#   the SDP installation (the folder above $QNX_TARGET's target/) and $HOME are printed as SHARE,
#   REPO, IMAGE, <QNX> and HOME.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO=$PWD

# NAME | repository | tag | options for both builds (CMake cache entries and the options below);
# an option that starts with "qnx:" is used only for the QNX build, because the project's CMake
# file assumes a Linux library layout (docs/oss-suite.md; OSS_QNX_OPTS=0 shows the build failure
# without them):
#   check   looks for clock_gettime() in librt and for struct itimerspec in <sys/time.h>; on QNX
#            the timer functions are in libc and struct itimerspec is in <time.h>.
#            -DCHECK_ENABLE_TIMEOUT_TESTS=OFF (check's own CMake option, both builds): check's
#            timing-dependent self-tests are disabled in this suite, on both platforms.
#   libxml2  v2.13.5 looks for dlopen() in libdl; on QNX it is in libc: build without the modules
#            feature. demo/trace-libxml2.sh uses this tag.
#   libuv    links its test programs without a math library; on QNX isinf() and isfinite() in
#            test/test-fs.c need libm: add -lm to every link command.
# --jobs=N, --tests=REGEX, --timeout=N and --build-only go to tools/qnx-ci.sh (ctest -j N, for
# example 1 for a suite whose tests use fixed TCP ports; ctest -R; time limit per test in seconds;
# build only) and apply to the Linux run too. --build-only: the library and its test programs are
# configured and built, and none of its tests run in this suite (libuv; its table row says "built,
# tests not run").
# libxml2-2.15 is libxml2 v2.15.4 with the modules feature on (its default) and no QNX-only option;
# libxml2 v2.15.0 changed the dlopen() check. An option that starts with "show:" names a CMake cache
# entry that section 6 prints from the QNX build folder (here the result of that check).
PROJECTS='
zlib     | https://github.com/madler/zlib.git            | v1.3.1  |
libyaml  | https://github.com/yaml/libyaml.git           | 0.2.5   |
libdeflate | https://github.com/ebiggers/libdeflate.git  | v1.24   | -DLIBDEFLATE_BUILD_TESTS=ON
utf8proc | https://github.com/JuliaStrings/utf8proc.git  | v2.10.0 | -DUTF8PROC_ENABLE_TESTING=ON
check    | https://github.com/libcheck/check.git         | 0.15.2  | -DCHECK_ENABLE_TIMEOUT_TESTS=OFF qnx:-DCMAKE_C_FLAGS=-DHAVE_LIBRT=1 qnx:-DHAVE_STRUCT_ITIMERSPEC_IT_VALUE=1
libxml2  | https://gitlab.gnome.org/GNOME/libxml2.git    | v2.13.5 | -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF qnx:-DLIBXML2_WITH_MODULES=OFF
libxml2-2.15 | https://gitlab.gnome.org/GNOME/libxml2.git | v2.15.4 | -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF show:LIBXML2_WITH_MODULES show:HAVE_DLOPEN
libuv    | https://github.com/libuv/libuv.git            | v1.53.0 | -DLIBUV_BUILD_TESTS=ON -DLIBUV_BUILD_BENCH=OFF --build-only qnx:-DCMAKE_C_STANDARD_LIBRARIES=-lm
'
[ $# -ge 2 ] || { echo "usage: demo/oss-suite.sh IMAGE_DIR SHARE_FOLDER [NAME...]"; exit 2; }
IMG=$(cd "$1" && pwd -P) || exit 2
mkdir -p "$2" && SHARE=$(cd "$2" && pwd -P) || exit 2
shift 2
PY=${PYTHON:-python3}
for c in git qcc cmake ctest "$PY"; do command -v "$c" >/dev/null || { echo "oss-suite: $c not found"; exit 2; }; done
export CI_COVERAGE=${CI_COVERAGE:-0} CI_TIMEOUT=${CI_TIMEOUT:-1500}
JOBS=${CI_JOBS:-4}
SRC=$SHARE/oss-src RES=$SHARE/oss-results LIN=$SHARE/oss-linux
mkdir -p "$REPO/tests/logs" "$SRC" "$RES/qnx" "$RES/linux" "$LIN"
LOG=$REPO/tests/logs/oss_$(date +%Y%m%d_%H%M%S).log
SDP=${QNX_TARGET:-}; SDP=${SDP%/target/*}; [ "$SDP" = "${QNX_TARGET:-}" ] && SDP=
hide_args=(-e "s|$SHARE|SHARE|g" -e "s|$REPO|REPO|g" -e "s|$IMG|IMAGE|g")
[ -n "$SDP" ] && hide_args+=(-e "s|$SDP|<QNX>|g")
hide_args+=(-e "s|$HOME|HOME|g")
# line-buffered where sed has -u (GNU sed), so that the log keeps every line if the run is stopped
SEDU=(); sed -u q </dev/null >/dev/null 2>&1 && SEDU=(-u)
hide() { sed ${SEDU[@]+"${SEDU[@]}"} "${hide_args[@]}"; }
field() { echo "$1" | cut -d'|' -f"$2" | sed -e 's/^ *//' -e 's/ *$//'; }

names=() urls=() tags=() opts=()
while IFS= read -r row; do
    [ -n "${row// /}" ] || continue
    n=$(field "$row" 1)
    if [ $# -gt 0 ]; then case " $* " in *" $n "*) ;; *) continue ;; esac; fi
    names+=("$n") urls+=("$(field "$row" 2)") tags+=("$(field "$row" 3)") opts+=("$(field "$row" 4)")
done <<< "$PROJECTS"
[ ${#names[@]} -gt 0 ] || { echo "oss-suite: no project selected"; exit 2; }
# no JUnit file of an earlier run may reach the table
for n in "${names[@]}"; do
    rm -f "$RES/qnx/$n.junit.xml" "$RES/qnx/$n.built.txt"
    [ "${OSS_LINUX:-1}" = 1 ] && rm -f "$RES/linux/$n.junit.xml" "$RES/linux/$n.built.txt"
done

{
echo "# demo/oss-suite.sh, $(date -Iseconds), sources sha256 $(sh "$REPO/tests/srchash.sh") (tests/srchash.sh): ${#names[@]} open-source projects, their own test suites on QNX 8.0 (guest) and on Linux (host)"
echo "host: $(uname -sm); host compiler: $(${CC:-cc} --version | head -1); $(cmake --version | head -1)"
echo
echo "== 1. fetch (shallow clone at a tag; nothing is changed in the clones)"
for i in "${!names[@]}"; do
    n=${names[$i]} d=$SRC/${names[$i]}
    if [ "${OSS_FETCH:-1}" = 1 ] || [ ! -d "$d/.git" ]; then
        rm -rf "$d"
        git -c advice.detachedHead=false clone -q --depth 1 --branch "${tags[$i]}" "${urls[$i]}" "$d" ||
            { echo "$n: clone of ${urls[$i]} failed"; continue; }
    fi
    echo "$n: ${urls[$i]} tag ${tags[$i]}, commit $(git -C "$d" log -1 --format=%h)"
done

if [ "${OSS_LINUX:-1}" = 1 ]; then
    echo
    echo "== 2. Linux: the same sources built with the host compiler, the same suites run on this host"
    for i in "${!names[@]}"; do
        n=${names[$i]} s=$SRC/${names[$i]} B=$LIN/${names[$i]}
        [ -d "$s/.git" ] || continue
        copts=() pj=$JOBS lsel=() lt=$CI_TIMEOUT lbo=0
        for o in ${opts[$i]}; do
            case $o in --jobs=*) pj=${o#*=} ;; --tests=*) lsel=(-R "${o#*=}") ;; --timeout=*) lt=${o#*=} ;;
                       --build-only) lbo=1 ;; qnx:*|show:*) ;; *) copts+=("$o") ;; esac
        done
        rm -rf "$B"; mkdir -p "$B"
        if cmake -S "$s" -B "$B" -DCMAKE_BUILD_TYPE=Debug ${copts[@]+"${copts[@]}"} > "$B.configure.txt" 2>&1 &&
           cmake --build "$B" -j "$JOBS" > "$B.build.txt" 2>&1; then
            if [ "$lbo" = 1 ]; then
                nreg=$(ctest --test-dir "$B" -N | sed -n 's/^Total Tests: //p')
                echo "configured and built; tests registered: $nreg; tests not run (--build-only)" > "$RES/linux/$n.built.txt"
                echo "$n: built; tests registered: $nreg; tests not run (--build-only)"
                continue
            fi
            ctest --test-dir "$B" -j "$pj" --timeout $((lt + 60)) --test-output-size-passed 1048576 \
                --test-output-size-failed 1048576 --output-junit "$RES/linux/$n.junit.xml" ${lsel[@]+"${lsel[@]}"} > "$B.ctest.txt" 2>&1
            echo "$n: ctest exit status $?; $(grep -E 'tests passed|tests failed' "$B.ctest.txt" | tail -1)"
        else
            echo "$n: Linux configure or build failed"
            tail -5 "$B.configure.txt" "$B.build.txt" | sed -E 's/^(-- [A-Za-z]+ done) \([0-9.]+s\)$/\1/'
        fi
    done
fi

echo
echo "== 3. QNX: tools/qnx-ci.sh boots the guest, builds every project with qcc, runs each suite in the guest, stops the guest"
args=()
for i in "${!names[@]}"; do
    [ -d "$SRC/${names[$i]}/.git" ] || continue
    args+=("$SRC/${names[$i]}")
    for o in ${opts[$i]}; do
        case $o in qnx:*) [ "${OSS_QNX_OPTS:-1}" = 1 ] && args+=("${o#qnx:}") ;; show:*) ;; *) args+=("$o") ;; esac
    done
done
CI_OUT=$RES/qnx "$REPO/tools/qnx-ci.sh" "$IMG" "$SHARE" "${args[@]}"
echo "tools/qnx-ci.sh exit status $?"

echo
echo "== 4. sources unchanged: tracked files changed in each clone after both runs (zlib's own CMake"
echo "   file renames zconf.h in the source folder when it builds in another folder)"
for n in "${names[@]}"; do
    [ -d "$SRC/$n/.git" ] || continue
    ch=$(git -C "$SRC/$n" status --porcelain --untracked-files=no)
    echo "$n: $(printf '%s' "$ch" | grep -c .)${ch:+ ($(echo $ch))}"
done

echo
echo "== 5. table (counts from the JUnit files that ctest wrote; inner cases from the test output in them)"
"$PY" -I - "$RES" "${OSS_LINUX:-1}" "${names[@]}" <<'PYEOF'
import os, re, sys
import xml.etree.ElementTree as ET
res, linux_run, names = sys.argv[1], sys.argv[2] == "1", sys.argv[3:]
def built(kind, n):
    return os.path.exists(os.path.join(res, kind, n + ".built.txt"))
def load(kind, n):
    p = os.path.join(res, kind, n + ".junit.xml")
    if not os.path.exists(p):
        return None
    tests = {}
    for tc in ET.parse(p).getroot().iter("testcase"):
        st = tc.get("status", "")
        if tc.find("failure") is not None or st == "fail":
            st = "failed"
        elif tc.find("skipped") is not None or st in ("notrun", "disabled"):
            st = "skipped"
        else:
            st = "passed"
        tests[tc.get("name")] = (st, tc.findtext("system-out") or "")
    return tests
TAP = re.compile(r"^(not ok|ok) \d+ - (\S+)(.*)$")
CHK = re.compile(r"^\d+%: Checks: (\d+), Failures: (\d+), Errors: (\d+)")
def inner(tests):
    tap, chk = {}, []
    for name, (st, out) in tests.items():
        for line in out.splitlines():
            m = TAP.match(line)
            if m:
                s = "skipped" if "# SKIP" in m.group(3) else ("passed" if m.group(1) == "ok" else "failed")
                tap[name + ": " + m.group(2)] = s
            m = CHK.match(line)
            if m:
                chk.append(tuple(int(x) for x in m.groups()))
    return tap, chk
def counts(d):
    return [len(d), sum(v == "passed" for v in d.values()), sum(v == "failed" for v in d.values()),
            sum(v == "skipped" for v in d.values())]
def fmt_inner(tap, chk):
    parts = []
    if tap:
        c = counts(tap); parts.append("TAP %d: %d ok, %d not ok, %d skipped" % tuple(c))
    if chk:
        parts.append("Check %d checks, %d failures, %d errors" % tuple(map(sum, zip(*chk))))
    return "; ".join(parts) or "-"
rows, only = [], []
for n in names:
    q, l = load("qnx", n), load("linux", n)
    qc = counts({k: v[0] for k, v in q.items()}) if q is not None else None
    lc = counts({k: v[0] for k, v in l.items()}) if l is not None else None
    qi, li = inner(q or {}), inner(l or {})
    rows.append((n, qc, lc, fmt_inner(*qi), fmt_inner(*li), built("qnx", n), built("linux", n)))
    if q is None:
        continue
    for t, (st, out) in sorted(q.items()):
        if st == "failed" and l is not None and l.get(t, ("",))[0] == "passed":
            only.append((n, t, out))
    for t, st in sorted(qi[0].items()):
        if st == "failed" and li[0].get(t) == "passed":
            only.append((n, t, None))
f = lambda c, b: ("%d | %d | %d | %d" % tuple(c) if c else
                  "built, tests not run | - | - | -" if b else "build failed | - | - | -")
fl = lambda c, b: f(c, b) if c or linux_run else "not run | - | - | -"
print("| project | QNX run | passed | failed | skipped | Linux run | passed | failed | skipped |")
print("|---|---|---|---|---|---|---|---|---|")
for n, qc, lc, qi, li, qb, lb in rows:
    print("| %s | %s | %s |" % (n, f(qc, qb), fl(lc, lb)))
print()
print("test cases inside the programs (where the output reports them):")
for n, qc, lc, qi, li, qb, lb in rows:
    if qi != "-" or li != "-":
        print("  %s: QNX %s | Linux %s" % (n, qi, li))
tot = lambda k: [sum(r[k][j] for r in rows if r[k]) for j in range(4)]
print("total ctest tests: QNX %d run, %d passed, %d failed, %d skipped; Linux %d run, %d passed, %d failed, %d skipped"
      % tuple(tot(1) + tot(2)))
print()
print("failed on QNX and passed on Linux: %d" % len(only))
for n, t, out in only:
    print("  %s: %s" % (n, t))
    if out:
        lines = [x for x in out.splitlines() if x.strip()]
        for x in [x for x in lines if re.search(r"(?i)fail|error|assert|not ok", x)][:6]:
            print("      | " + x[:200])
PYEOF
for n in "${names[@]}"; do
    out=$(sed -n '/^not ok /,/^ok /p' "$SHARE/ci/$n.ctest.txt" 2>/dev/null | grep -E '^(not ok|# )' | head -60)
    [ -n "$out" ] && { echo; echo "QNX: lines of the failed TAP cases of $n (from the ctest output)"; echo "$out"; }
done
shown=0
for i in "${!names[@]}"; do
    for o in ${opts[$i]}; do
        case $o in show:*) ;; *) continue ;; esac
        [ $shown = 1 ] || { echo; echo "== 6. CMake cache entries of the QNX builds (options show:NAME of the table)"; shown=1; }
        v=$(grep -E "^${o#show:}:" "$SHARE/ci/${names[$i]}/CMakeCache.txt" 2>/dev/null | head -1)
        echo "${names[$i]}: ${v:-${o#show:} not in the cache (no QNX build folder or no such entry)}"
    done
done
} 2>&1 | hide | tee "$LOG"
echo "log: ${LOG#$REPO/}"
