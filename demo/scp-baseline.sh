#!/usr/bin/env bash
# demo/scp-baseline.sh - what the shared folder saves, counted on a real test suite: cJSON's own
# tests run in the QNX guest through demo/scp-run.sh, a runner that copies files with scp instead of
# using fs-9p. The script clones and builds cJSON as demo/cjson.sh does (same tag, same 3-line
# change), but in a folder that the guest cannot see, runs ctest twice (plain, then with gcov
# counters), makes the coverage report from the .gcda files that the runner copied back, and counts
# the files copied into the guest, the files copied back and the paths that the runner translated.
# The output has counts only, no times.
#
# usage: demo/scp-baseline.sh WORK_DIR   (a folder outside the shared folder)
# Settings (environment): SCP_RUN_SSH, SCP_RUN_SCP, SCP_RUN_DEST, SCP_RUN_CORE (demo/scp-run.sh);
#   CJSON_TAG (default v1.7.18), CJSON_URL, GCOVR (default gcovr), QNX_SHARE (only to check that
#   WORK_DIR is outside it).
# Needs: QNX SDP 8.0 environment (qcc, ntox86_64-readelf, ntox86_64-gcov), cmake and ctest 3.21 or
# newer, git, a running guest.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO=$PWD
[ $# -eq 1 ] || { echo "usage: demo/scp-baseline.sh WORK_DIR   (outside the shared folder)"; exit 2; }
for c in qcc git cmake ctest ntox86_64-readelf; do command -v $c >/dev/null || { echo "scp-baseline: $c not found"; exit 2; }; done
: "${SCP_RUN_SSH:?set SCP_RUN_SSH}" "${SCP_RUN_SCP:?set SCP_RUN_SCP}"
mkdir -p "$1" && D=$(cd "$1" && pwd -P) || exit 2
if [ -n "${QNX_SHARE:-}" ]; then
    S=$(cd "$QNX_SHARE" && pwd -P); case "$D/" in "$S"/*) echo "scp-baseline: WORK_DIR must be outside the shared folder"; exit 2 ;; esac
fi
TAG=${CJSON_TAG:-v1.7.18}
URL=${CJSON_URL:-https://github.com/DaveGamble/cJSON.git}
GCOVR=${GCOVR:-gcovr}
SRC=$D/cJSON
mkdir -p tests/logs
LOG=$REPO/tests/logs/scp_baseline_$(date +%Y%m%d_%H%M%S).log
export SCP_RUN_LOG=$D/copies.txt
# the data files of cJSON's tests, written by hand from tests/parse_examples.c and json_patch_tests.c
export SCP_RUN_DATA="parse_examples:inputs json_patch_tests:json-patch-tests"
hide() { sed -e "s|$D|WORK|g" -e "s|$REPO|REPO|g" -e "s|$HOME|HOME|g"; }
RUN=$REPO/demo/scp-run.sh
read -r -a SSHC <<< "$SCP_RUN_SSH"

{
echo "# demo/scp-baseline.sh, $(date -Iseconds), sources sha256 $(sh tests/srchash.sh) (tests/srchash.sh): cJSON $TAG through demo/scp-run.sh (scp, no shared folder)"
echo
echo "== clone $URL at tag $TAG (shallow) into WORK/cJSON; WORK is outside the shared folder"
rm -rf "$SRC" "$D/build" "$D/build-cov" "$SCP_RUN_LOG"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" "$URL" "$SRC" || { echo "clone failed"; exit 1; }
echo "commit: $(git -C "$SRC" log --oneline -1)"
sed -i 's|COMMAND "${CMAKE_CURRENT_BINARY_DIR}/${TEST_CJSON}")|COMMAND "${TEST_CJSON}")|' "$SRC/CMakeLists.txt"
sed -i -e 's|COMMAND "./${unity_test}")|COMMAND "${unity_test}")|' -e 's|COMMAND "./${cjson_utils_test}")|COMMAND "${cjson_utils_test}")|' "$SRC/tests/CMakeLists.txt"
echo "lines changed (as in demo/cjson.sh): $(git -C "$SRC" diff --numstat | awk '{ a += $1 } END { print a + 0 }')"
"${SSHC[@]}" "rm -rf /tmp/scp-run" </dev/null

configure() {   # configure BUILD_DIR EXTRA_C_FLAGS EMULATOR_LIST
    cmake -S "$SRC" -B "$1" -DCMAKE_TOOLCHAIN_FILE="$REPO/examples/qnx-unit/qnx-x86_64.cmake" \
        -DENABLE_CJSON_UTILS=ON -DENABLE_CJSON_TEST=ON -DCMAKE_BUILD_TYPE=Debug \
        ${2:+-DCMAKE_C_FLAGS="$2"} -DCMAKE_CROSSCOMPILING_EMULATOR="$3" > "$1.configure.txt" 2>&1 &&
    cmake --build "$1" -j8 > "$1.build.txt" 2>&1
}
run_ctest() {   # run_ctest BUILD_DIR LABEL
    (cd "$1" && ctest 2>&1; echo "ctest exit status $?") | sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' > "$D/ctest_$2.txt"
    grep -E 'tests passed|^ctest exit status' "$D/ctest_$2.txt"
}
B=$D/build BC=$D/build-cov
echo
echo "== build with qcc; emulator demo/scp-run.sh with LD_LIBRARY_PATH=WORK/build"
configure "$B" "" "$RUN;-e;LD_LIBRARY_PATH=$B" && echo "build: ok" || { echo "build failed"; tail -20 "$B.build.txt"; exit 1; }
echo "test programs: $(cd "$B" && ctest -N | sed -n 's/^Total Tests: //p')"
echo
echo "== ctest: each test program is copied into the guest and run there"
run_ctest "$B" plain
cp "$SCP_RUN_LOG" "$D/copies_plain.txt"
echo
echo "== coverage build (-O0 -fprofile-arcs -ftest-coverage); emulator demo/scp-run.sh --coverage"
configure "$BC" "-O0 -fprofile-arcs -ftest-coverage -fprofile-update=atomic" "$RUN;--coverage;-e;LD_LIBRARY_PATH=$BC" && echo "build: ok" || { echo "build failed"; exit 1; }
: > "$SCP_RUN_LOG"
run_ctest "$BC" cov
echo "coverage: $(find "$BC" -name '*.gcda' | wc -l) .gcda files in WORK/build-cov, all copied back by the runner"
mapfile -t DIRS < <(find "$BC" -name '*.gcda' -printf '%h\n' | sort -u)
$GCOVR --root "$SRC" --object-directory "$BC" --gcov-executable ntox86_64-gcov \
    --filter "$SRC/cJSON\.c" --filter "$SRC/cJSON_Utils\.c" --txt-metric line "${DIRS[@]}" 2>&1 | grep -E '^(cJSON|TOTAL)' |
    awk '{ printf "  %-16s %9s %9s %6s\n", $1, $2, $3, $4 }'
cp "$SCP_RUN_LOG" "$D/copies_cov.txt"
"${SSHC[@]}" "rm -rf /tmp/scp-run" </dev/null

echo
echo "== counts (one line per file or path in the runner's log; plain run and coverage run of the 22 tests)"
summary() {   # summary LABEL FILE
    local f=$2
    printf '%s: copied into the guest %d files (programs %d, shared libraries %d, data files %d; %d different host files); copied back %d files (.gcda %d, core files %d); paths translated %d\n' "$1" \
        "$(grep -c '^in ' "$f")" "$(grep -c '^in program ' "$f")" "$(grep -c '^in library ' "$f")" "$(grep -c '^in data ' "$f")" \
        "$(grep '^in ' "$f" | sort -u | wc -l)" "$(grep -c '^back ' "$f")" "$(grep -c '^back gcda ' "$f")" "$(grep -c '^back core ' "$f")" "$(grep -c '^map ' "$f")"
}
summary "scp runner, plain run" "$D/copies_plain.txt"
summary "scp runner, coverage run" "$D/copies_cov.txt"
echo "paths translated, by kind (both runs): $(cat "$D/copies_plain.txt" "$D/copies_cov.txt" | awk '/^map / { n[$2]++ } END { for (k in n) printf "%s %d, ", k, n[k] }' | sed 's/, $//')"
echo "reports copied back: 0 (ctest writes its JUnit file on the host from the program's output; the Unity tests write no report file)"
echo "core files: 0 (no test crashed)"
echo "fs-9p (tools/qnx-run, demo/cjson.sh on the same tests): 0 files copied into the guest and 0 copied back; tools/qnx-run has no copy step and translates host paths with one rule (shared folder -> /mnt/host)"
echo
echo "RESULT: scp baseline, cJSON $TAG: plain run $(grep -h 'tests passed' "$D/ctest_plain.txt"); coverage run $(grep -h 'tests passed' "$D/ctest_cov.txt")"
} 2>&1 | hide | tee "$LOG"
echo "log: ${LOG#$REPO/}"
