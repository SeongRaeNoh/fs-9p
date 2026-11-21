#!/usr/bin/env bash
# demo/trace-libxml2.sh - reproduce the libxml2 finding of demo/oss-suite.sh with one command:
# fetch libxml2 at the tag that the open-source suite uses, build it with qcc, run its testapi
# program in the QNX 8.0 guest from the shared folder, open the core file of the crash with the
# SDP's gdb on the host and print the backtrace, then print the libxml2 source line of each frame
# in libxml2. tools/qnx-ci.sh does the build, the run, the core file and the backtrace (option
# --tests=^testapi$; core files and backtraces as described in its header). No file of libxml2 is
# part of this repository, and nothing in the clone is changed.
#
# The finding (docs/oss-suite.md): testapi calls xmlParseDTD("foo", NULL); xmlSAX2ResolveEntity()
# then passes its null systemId as the argument of a "%s" conversion (SAX2.c line 432 at v2.13.5).
# The C standard requires a pointer to a string for %s, so a null pointer there is undefined
# behaviour; glibc prints "(null)", and in the QNX guest the program ends with SIGSEGV.
#
# usage: demo/trace-libxml2.sh IMAGE_DIR SHARE_FOLDER
#   IMAGE_DIR, SHARE_FOLDER  as for tools/qnx-ci.sh. libxml2 is cloned into
#                            SHARE_FOLDER/trace-src/libxml2 (inside the share, because libxml2's
#                            tests read files from the source tree)
# Settings (environment): those of tools/qnx-ci.sh (QNX_SSH_PORT, QNX_SSH_KEY, GDB, ...); this script
#   sets CI_COVERAGE=0 and CI_TIMEOUT=1500; LIBXML2_TAG (default v2.13.5), LIBXML2_URL (default
#   https://gitlab.gnome.org/GNOME/libxml2.git).
# Needs: git, the QNX SDP 8.0 environment (qcc, ntox86_64-gdb), cmake and ctest 3.21 or newer, QEMU.
# Output: the output of tools/qnx-ci.sh, the testapi test case of the JUnit file, the source lines of
#   the frames, and checks with a last line "RESULT: N passed, M failed"; a copy goes to
#   tests/logs/trace_libxml2_<date>.log. Exit status: 0 if every check passed.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO=$PWD
[ $# -eq 2 ] || { echo "usage: demo/trace-libxml2.sh IMAGE_DIR SHARE_FOLDER"; exit 2; }
IMG=$(cd "$1" && pwd -P) || exit 2
mkdir -p "$2" && SHARE=$(cd "$2" && pwd -P) || exit 2
TAG=${LIBXML2_TAG:-v2.13.5}
URL=${LIBXML2_URL:-https://gitlab.gnome.org/GNOME/libxml2.git}
SRC=$SHARE/trace-src/libxml2 OUT=$SHARE/ci/results J=$SHARE/ci/results/libxml2.junit.xml
mkdir -p "$REPO/tests/logs"
LOG=$REPO/tests/logs/trace_libxml2_$(date +%Y%m%d_%H%M%S).log
SDP=${QNX_TARGET:-}; SDP=${SDP%/target/*}; [ "$SDP" = "${QNX_TARGET:-}" ] && SDP=
hide_args=(-e "s|$SHARE|SHARE|g" -e "s|$REPO|REPO|g" -e "s|$IMG|IMAGE|g")
[ -n "$SDP" ] && hide_args+=(-e "s|$SDP|<QNX>|g")
hide() { sed "${hide_args[@]}"; }
pass=0 fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1"; fail=$((fail + 1)); fi; }
{
echo "# demo/trace-libxml2.sh, $(date -Iseconds), sources sha256 $(sh tests/srchash.sh) (tests/srchash.sh): libxml2 $TAG testapi in the QNX guest, core file, gdb backtrace"
echo
echo "== 1. fetch $URL at tag $TAG (shallow) into SHARE/trace-src/libxml2"
rm -rf "$SRC"; mkdir -p "$SHARE/trace-src"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" "$URL" "$SRC" || { echo "clone failed"; exit 1; }
echo "commit: $(git -C "$SRC" log -1 --format=%h)"
echo
echo "== 2. tools/qnx-ci.sh: build with qcc (the options of demo/oss-suite.sh), run testapi in the guest, backtrace of its core file"
CI_COVERAGE=0 CI_TIMEOUT=${CI_TIMEOUT:-1500} CI_OUT=$OUT tools/qnx-ci.sh "$IMG" "$SHARE" "$SRC" \
    -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_MODULES=OFF '--tests=^testapi$'
echo "tools/qnx-ci.sh exit status $? (1 expected: testapi fails)"
echo
echo "== 3. the testapi test case in the JUnit file (without ctest's time attribute; the output of testapi is cut to its last 5 lines here)"
tcase=$(awk '/<testcase / { p = index($0, "name=\"testapi\"") > 0 } p { print } /<\/testcase>/ { p = 0 }' "$J" 2>/dev/null | sed 's/ time="[^"]*"//')
printf '%s\n' "$tcase" | sed -n '/<testcase /,/<\/failure>/p'
printf '%s\n' "$tcase" | sed -n '/<system-out>/,/<\/system-out>/p' | tail -5
echo
echo "== 4. the libxml2 source line of each frame in libxml2 (clone at $TAG)"
printf '%s\n' "$tcase" | sed -n '/<failure /,/<\/failure>/p' | grep -E '^#[0-9]+ ' |
    sed -n -E "s|^#([0-9]+) +([^ ]+) .* at $SRC/([^ ]+):([0-9]+)\$|\\1 \\2 \\3 \\4|p" |
    while read -r num fn file line; do
        printf '#%-2s %-24s %s:%s:  %s\n' "$num" "$fn" "$file" "$line" "$(sed -n "${line}p" "$SRC/$file" | sed -e 's/^[[:space:]]*//' | cut -c1-110)"
    done
echo
echo "== checks"
printf '%s\n' "$tcase" | grep -q 'status="fail"' && printf '%s\n' "$tcase" | grep -q '<failure message="crashed with SIGSEGV; core file testapi.core; first frame in the project: [^"]*" type="crash">'
chk "testapi failed; the JUnit failure element names SIGSEGV and the core file testapi.core" $?
printf '%s\n' "$tcase" | grep -E -q '^#[0-9]+ +xmlSAX2ResolveEntity \(.*systemId=0x0\) at .*/SAX2\.c:[0-9]+$'
chk "the backtrace has xmlSAX2ResolveEntity with systemId=0x0, with file and line in SAX2.c" $?
printf '%s\n' "$tcase" | grep -E -q '^#[0-9]+ +xmlParseDTD \(ExternalID=0x[0-9a-f]+ &quot;foo&quot;, SystemID=0x0\) at .*/parser\.c:[0-9]+$'
chk "the backtrace has xmlParseDTD(\"foo\", NULL) with file and line in parser.c" $?
l=$(printf '%s\n' "$tcase" | sed -n -E 's/^#[0-9]+ +xmlSAX2ResolveEntity \(.* at .*\/SAX2\.c:([0-9]+)$/\1/p' | head -1)
[ -n "$l" ] && sed -n "${l}p" "$SRC/SAX2.c" | grep -q 'xmlWarnMsg(ctxt, XML_ERR_INVALID_URI,' && sed -n "$((l + 1))p" "$SRC/SAX2.c" | grep -q '"Can.t resolve URI: %s\\n", systemId'
chk "SAX2.c line ${l:-?} and the next line pass systemId to the format \"Can't resolve URI: %s\\n\"" $?
echo "RESULT: $pass passed, $fail failed"
} 2>&1 | hide | tee "$LOG"
echo "log: ${LOG#$REPO/}"
grep -q '^RESULT: [0-9]* passed, 0 failed$' "$LOG"
