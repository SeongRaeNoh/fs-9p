#!/usr/bin/env bash
# demo/ci-crash.sh - what tools/qnx-ci.sh reports when a test crashes in the QNX 8.0 guest. It runs
# tools/qnx-ci.sh on examples/ci-crash, whose four tests pass, crash on purpose, pass after a child
# process crashed on purpose, and fail without a crash. The test that crashed gets gdb's backtrace
# of its core file in its JUnit <failure> element; the other two do not.
#
# usage: demo/ci-crash.sh IMAGE_DIR SHARE_FOLDER
#   IMAGE_DIR, SHARE_FOLDER  as for tools/qnx-ci.sh (an image of tools/make-image.sh, whose guest
#                            runs dumper with a dump folder; the host folder for the guest)
# Settings (environment): those of tools/qnx-ci.sh (QNX_SSH_PORT, QNX_SSH_KEY, GDB, ...); this
#   script sets CI_COVERAGE=0.
# Output: the output of tools/qnx-ci.sh, the test cases of the JUnit file, the core files that the
#   guest wrote, and checks with a last line "RESULT: N passed, M failed"; a copy goes to
#   tests/logs/ci_crash_<date>.log. Exit status: 0 if every check passed.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO=$PWD
[ $# -eq 2 ] || { echo "usage: demo/ci-crash.sh IMAGE_DIR SHARE_FOLDER"; exit 2; }
IMG=$(cd "$1" && pwd -P) || exit 2
mkdir -p "$2" && SHARE=$(cd "$2" && pwd -P) || exit 2
mkdir -p "$REPO/tests/logs"
LOG=$REPO/tests/logs/ci_crash_$(date +%Y%m%d_%H%M%S).log
OUT=$SHARE/ci/results J=$SHARE/ci/results/ci-crash.junit.xml
SDP=${QNX_TARGET:-}; SDP=${SDP%/target/*}; [ "$SDP" = "${QNX_TARGET:-}" ] && SDP=
hide_args=(-e "s|$SHARE|SHARE|g" -e "s|$REPO|REPO|g" -e "s|$IMG|IMAGE|g")
[ -n "$SDP" ] && hide_args+=(-e "s|$SDP|<QNX>|g")
hide() { sed "${hide_args[@]}"; }
tc() { awk -v n="name=\"$1\"" '/<testcase / { p = index($0, n) > 0 } p { print } /<\/testcase>/ { p = 0 }' "$J"; }
pass=0 fail=0
chk() { if [ "$2" = 0 ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1"; fail=$((fail + 1)); fi; }
{
echo "# demo/ci-crash.sh, $(date -Iseconds), sources sha256 $(sh tests/srchash.sh) (tests/srchash.sh): tools/qnx-ci.sh on examples/ci-crash (one test crashes on purpose)"
echo
echo "== tools/qnx-ci.sh IMAGE SHARE examples/ci-crash (CI_COVERAGE=0)"
CI_COVERAGE=0 CI_OUT=$OUT tools/qnx-ci.sh "$IMG" "$SHARE" examples/ci-crash
echo "tools/qnx-ci.sh exit status $? (1 expected: two tests fail on purpose)"
echo
echo "== the test cases in the JUnit file $(basename "$J") (without ctest's time attributes)"
[ -f "$J" ] && sed -n '/<testcase /,/<\/testcase>/p' "$J" | sed 's/ time="[^"]*"//'
echo
echo "== core files that the guest's dumper wrote through the share during the run"
ls -1 "$SHARE/ci/cores" 2>/dev/null | sed 's/^/  /'
echo
echo "== checks"
tc parse_crash | grep -q 'status="fail"' && tc parse_crash | grep -q '<failure message="crashed with SIGSEGV; core file parse_crash.core; first frame in the project: read_value at src/record.c:[0-9]*" type="crash">'
chk "parse_crash: failed; failure message names SIGSEGV, the core file and read_value() in src/record.c" $?
tc parse_crash | grep -E -q '^#0 +read_value \(eq=0x0\) at .*/examples/ci-crash/src/record\.c:[0-9]+$' &&
  tc parse_crash | grep -E -q '^#1 +parse_record \(.*\) at .*/examples/ci-crash/src/record\.c:[0-9]+$' &&
  tc parse_crash | grep -E -q '^#2 +main \(\) at .*/examples/ci-crash/tests/parse_crash\.c:[0-9]+$'
chk "parse_crash: the backtrace in the JUnit file has read_value (eq=0x0), parse_record and main with file and line" $?
tc child_crash | grep -q 'status="run"' && ! tc child_crash | grep -q '<failure'
chk "child_crash: passed, no failure element (its child crashed on purpose)" $?
tc exit_one | grep -q '<failure' && ! tc exit_one | grep -q 'type="crash"'
chk "exit_one: failed without a crash; no backtrace" $?
tc parse_ok | grep -q 'status="run"' && ! tc parse_ok | grep -q '<failure'
chk "parse_ok: passed" $?
[ "$(grep -c 'type="crash"' "$J" 2>/dev/null)" = 1 ]
chk "exactly one backtrace in the JUnit file" $?
echo "RESULT: $pass passed, $fail failed"
} 2>&1 | hide | tee "$LOG"
echo "log: ${LOG#$REPO/}"
grep -q '^RESULT: [0-9]* passed, 0 failed$' "$LOG"
