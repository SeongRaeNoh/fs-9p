#!/usr/bin/env bash
# demo/cjson.sh - an existing open-source project in the QNX guest: clone cJSON
# (https://github.com/DaveGamble/cJSON, MIT licence), build it with qcc through CMake on this
# machine, and run its own test suite with ctest; ctest starts every test program in the QNX guest
# from the shared folder through tools/qnx-run. Nothing of cJSON is part of this repository.
#
# usage: demo/cjson.sh WORK_DIR
#   WORK_DIR  a folder inside the shared folder; the script clones cJSON into WORK_DIR/cJSON and
#             builds in WORK_DIR/build (and in WORK_DIR/build-cov with COVERAGE=1)
# Settings (environment): those of tools/qnx-run (QNX_SHARE, or QNX_IMAGE of tools/qnx-vm; QNX_SSH,
# QNX_SSH_PORT, QNX_SSH_KEY, QNX_MOUNT), and
#   CJSON_TAG   git tag to test (default v1.7.18)
#   CJSON_URL   repository (default https://github.com/DaveGamble/cJSON.git)
#   COVERAGE=1  build a second time with gcov counters, run the tests again in the guest, and report
#               line and branch coverage of cJSON.c and cJSON_Utils.c (gcovr; GCOVR = command,
#               default gcovr), with examples of lines and branches of cJSON.c that no test executed
#   PYTHON      python 3 for those examples (default python3)
# Needs: the QNX SDP 8.0 environment (qcc, ntox86_64-gcov), cmake and ctest 3.21 or newer, git, a
# running guest with fs-9p mounted at QNX_MOUNT (default /mnt/host).
#
# cJSON is configured with ENABLE_CJSON_UTILS=ON (3 more test programs) and builds shared libraries
# with version links (libcjson.so -> libcjson.so.1 -> libcjson.so.1.7.18); the tests load them in
# the guest through LD_LIBRARY_PATH (tools/qnx-run -e maps the host build folder to the guest path).
# One change is made to the cloned copy, and the script prints it: cJSON registers its tests with
# a path ("./parse_number"); CMake applies CMAKE_CROSSCOMPILING_EMULATOR only to tests registered
# with a target name, so the three add_test lines are changed to use the target name.
# Output: ctest's result counts, without times. If a test fails, only the counts are printed (no
# test names and no test output). A copy goes to tests/logs/cjson_<date>.log.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO=$PWD
QR=$REPO/tools/qnx-run
[ $# -eq 1 ] || { echo "usage: demo/cjson.sh WORK_DIR   (inside the shared folder)"; exit 2; }
SHARE=${QNX_SHARE:-$(cat "${QNX_IMAGE:-/nonexistent}/qnx-vm/share" 2>/dev/null)}
[ -n "$SHARE" ] || { echo "cjson: set QNX_SHARE (or QNX_IMAGE of tools/qnx-vm)"; exit 2; }
SHARE=$(cd "$SHARE" && pwd -P) || exit 2
for c in qcc git cmake ctest; do command -v $c >/dev/null || { echo "cjson: $c not found"; exit 2; }; done
mkdir -p "$1" && D=$(cd "$1" && pwd -P) || exit 2
case "$D/" in "$SHARE"/*) ;; *) echo "cjson: WORK_DIR must be inside the shared folder $SHARE"; exit 2 ;; esac
TAG=${CJSON_TAG:-v1.7.18}
URL=${CJSON_URL:-https://github.com/DaveGamble/cJSON.git}
GCOVR=${GCOVR:-gcovr}
mkdir -p "$REPO/tests/logs"
LOG=$REPO/tests/logs/cjson_$(date +%Y%m%d_%H%M%S).log
hide() { sed -e "s|$D|WORK|g" -e "s|$SHARE|SHARE|g" -e "s|$REPO|REPO|g" -e "s|$HOME|HOME|g"; }
SRC=$D/cJSON

# run_ctest BUILD_DIR LABEL: ctest in BUILD_DIR; per-test lines only when every test passed
run_ctest() {
    local out=$D/ctest_$2.txt
    (cd "$1" && ctest 2>&1; echo "ctest exit status $?") | sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' > "$out"
    if grep -q '^100% tests passed' "$out"; then
        grep -E 'Test +#|tests passed|^ctest exit status' "$out"
    else
        grep -E 'tests passed|^ctest exit status' "$out"
    fi
    # each Unity test program prints "N Tests F Failures I Ignored"; sum them from ctest's own log
    awk '/^[0-9]+ Tests [0-9]+ Failures [0-9]+ Ignored/ { t += $1; f += $3; i += $5; n++ }
         END { printf "Unity test cases in %d programs: %d, failures %d, ignored %d\n", n, t, f, i }' "$1/Testing/Temporary/LastTest.log"
}

{
echo "# demo/cjson.sh, $(date -Iseconds), sources sha256 $(sh "$REPO/tests/srchash.sh") (tests/srchash.sh): cJSON $TAG, its own tests, run in the QNX guest through tools/qnx-run"
echo "guest: $("$QR" uname -sr)"
echo
echo "== clone $URL at tag $TAG (shallow) into WORK/cJSON"
rm -rf "$SRC" "$D/build" "$D/build-cov"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" "$URL" "$SRC" || { echo "clone failed"; exit 1; }
echo "commit: $(git -C "$SRC" log --oneline -1)"
echo
echo "== change to the clone: register the tests by target name, so that ctest runs them through the emulator"
sed -i 's|COMMAND "${CMAKE_CURRENT_BINARY_DIR}/${TEST_CJSON}")|COMMAND "${TEST_CJSON}")|' "$SRC/CMakeLists.txt"
sed -i -e 's|COMMAND "./${unity_test}")|COMMAND "${unity_test}")|' -e 's|COMMAND "./${cjson_utils_test}")|COMMAND "${cjson_utils_test}")|' "$SRC/tests/CMakeLists.txt"
git -C "$SRC" diff -U0 | grep -E '^[-+] '
echo "lines changed: $(git -C "$SRC" diff --numstat | awk '{ a += $1 } END { print a + 0 }')"

configure() {   # configure BUILD_DIR EXTRA_C_FLAGS EMULATOR_LIST
    cmake -S "$SRC" -B "$1" -DCMAKE_TOOLCHAIN_FILE="$REPO/examples/qnx-unit/qnx-x86_64.cmake" \
        -DENABLE_CJSON_UTILS=ON -DENABLE_CJSON_TEST=ON -DCMAKE_BUILD_TYPE=Debug \
        ${2:+-DCMAKE_C_FLAGS="$2"} -DCMAKE_CROSSCOMPILING_EMULATOR="$3" > "$1.configure.txt" 2>&1 &&
    cmake --build "$1" -j8 > "$1.build.txt" 2>&1
}
B=$D/build
echo
echo "== build with qcc (CMake toolchain file examples/qnx-unit/qnx-x86_64.cmake; ENABLE_CJSON_UTILS=ON)"
mkdir -p "$B"
if configure "$B" "" "$QR;-e;LD_LIBRARY_PATH=$B"; then echo "build: ok"; else echo "build failed:"; tail -20 "$B.build.txt" "$B.configure.txt"; exit 1; fi
grep -E 'The C compiler identification' "$B.configure.txt"
echo "test programs: $(cd "$B" && ctest -N | sed -n 's/^Total Tests: //p')"
echo "libraries: $(cd "$B" && ls libcjson* | tr '\n' ' ')"
echo "emulator in CTestTestfile.cmake: $(grep -c "$QR" "$B/CTestTestfile.cmake" "$B/tests/CTestTestfile.cmake" | awk -F: '{ s += $2 } END { print s }') tests run through tools/qnx-run"
echo
echo "== ctest: every test program runs in the QNX guest from $(echo "$B" | hide) seen as ${QNX_MOUNT:-/mnt/host}/..."
run_ctest "$B" plain

if [ "${COVERAGE:-0}" = 1 ]; then
    BC=$D/build-cov
    strip=$(printf '%s' "$SHARE" | tr -cd / | wc -c)
    echo
    echo "== coverage: build again with gcov counters (-O0 -fprofile-arcs -ftest-coverage); the guest writes the .gcda files through the share"
    mkdir -p "$BC"
    if configure "$BC" "-O0 -fprofile-arcs -ftest-coverage -fprofile-update=atomic" \
        "$QR;-e;LD_LIBRARY_PATH=$BC;-e;GCOV_PREFIX=${QNX_MOUNT:-/mnt/host};-e;GCOV_PREFIX_STRIP=$strip"; then echo "build: ok"; else echo "build failed:"; tail -20 "$BC.build.txt"; exit 1; fi
    run_ctest "$BC" cov
    echo "coverage: $(find "$BC" -name '*.gcda' | wc -l) .gcda files written by the guest"
    echo
    echo "== coverage of the library code under test (cJSON.c, cJSON_Utils.c): gcovr with the SDP's gcov, over all test programs"
    echo "   (cJSON's unit tests compile cJSON.c into each test program with #include; gcovr adds the counts of all programs per source file)"
    mapfile -t DIRS < <(find "$BC" -name '*.gcda' -printf '%h\n' | sort -u)
    for m in line branch; do
        $GCOVR --root "$SRC" --object-directory "$BC" --gcov-executable ntox86_64-gcov \
            --filter "$SRC/cJSON\.c" --filter "$SRC/cJSON_Utils\.c" --txt-metric $m "${DIRS[@]}" 2>&1 | grep -E '^(File|cJSON|TOTAL)' |
            awk '{ printf "  %-16s %9s %9s %6s\n", $1, $2, $3, $4 }'
    done
    $GCOVR --root "$SRC" --object-directory "$BC" --gcov-executable ntox86_64-gcov \
        --filter "$SRC/cJSON\.c" --json "$D/cov.json" "${DIRS[@]}" >/dev/null 2>&1
    echo
    echo "== examples from the merged counts of cJSON.c: the first lines that no test executed, and the first executed line with a branch never taken"
    ${PYTHON:-python3} -I - "$D/cov.json" "$SRC/cJSON.c" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
src = open(sys.argv[2], errors="replace").read().split("\n")
for f in d["files"]:
    if not f["file"].endswith("cJSON.c"):
        continue
    lines = [l for l in f["lines"] if not l.get("gcovr/noncode")]
    for l in [l for l in lines if l["count"] == 0][:3]:
        print("  line %d never executed: %s" % (l["line_number"], src[l["line_number"] - 1].strip()))
    for l in lines:
        b = l.get("branches", [])
        n0 = sum(1 for x in b if x["count"] == 0)
        if l["count"] > 0 and n0:
            print("  line %d executed, %d of its %d branches never taken: %s" % (l["line_number"], n0, len(b), src[l["line_number"] - 1].strip()))
            break
PY
fi
echo
echo "RESULT: cJSON $TAG: $(grep -h -E 'tests passed' "$D/ctest_plain.txt")"
} 2>&1 | hide | tee "$LOG"
echo "log: ${LOG#$REPO/}"
grep -q '^RESULT: cJSON .*100% tests passed' "$LOG"
