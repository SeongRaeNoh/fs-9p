#!/usr/bin/env bash
# demo/ci.sh - the team example: one call of tools/qnx-ci.sh, as a self-hosted test machine would
# make it, on two projects: examples/qnx-unit (QNX message passing and pulses) and cJSON
# (https://github.com/DaveGamble/cJSON, MIT licence; cloned, not part of this repository).
# tools/qnx-ci.sh boots the VM, runs both test suites in the guest with ctest --output-junit (one
# test at a time, because coverage is on), writes gcovr reports on the host and stops the VM.
#
# usage: demo/ci.sh IMAGE_DIR SHARE_FOLDER
#   IMAGE_DIR, SHARE_FOLDER  as for tools/qnx-ci.sh (an image of tools/make-image.sh; the host folder
#                            for the guest). cJSON is cloned into SHARE_FOLDER/ci-src/cJSON, because
#                            its tests read data files from the source tree.
# Settings (environment): those of tools/qnx-ci.sh (QNX_SSH_PORT, QNX_SSH_KEY, CI_JOBS, GCOVR, ...);
#   CJSON_TAG (default v1.7.18), CJSON_URL (default https://github.com/DaveGamble/cJSON.git).
# cJSON registers its tests with a path ("./parse_number"), and CMake applies
# CMAKE_CROSSCOMPILING_EMULATOR only to tests registered with a target name, so the three add_test
# lines are changed to use the target name: the same change as demo/cjson.sh, printed below.
# Output: the output of tools/qnx-ci.sh; a copy goes to tests/logs/ci_<date>.log.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO=$PWD
[ $# -eq 2 ] || { echo "usage: demo/ci.sh IMAGE_DIR SHARE_FOLDER"; exit 2; }
IMG=$(cd "$1" && pwd -P) || exit 2
mkdir -p "$2" && SHARE=$(cd "$2" && pwd -P) || exit 2
TAG=${CJSON_TAG:-v1.7.18}
URL=${CJSON_URL:-https://github.com/DaveGamble/cJSON.git}
SRC=$SHARE/ci-src/cJSON
mkdir -p "$REPO/tests/logs"
LOG=$REPO/tests/logs/ci_$(date +%Y%m%d_%H%M%S).log
hide() { sed -e "s|$SHARE|SHARE|g" -e "s|$REPO|REPO|g" -e "s|$IMG|IMAGE|g" -e "s|$HOME|HOME|g"; }
{
echo "# demo/ci.sh, $(date -Iseconds), sources sha256 $(sh "$REPO/tests/srchash.sh") (tests/srchash.sh): tools/qnx-ci.sh on examples/qnx-unit and cJSON $TAG"
echo
echo "== clone $URL at tag $TAG (shallow) into SHARE/ci-src/cJSON"
rm -rf "$SRC"; mkdir -p "$SHARE/ci-src"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" "$URL" "$SRC" || { echo "clone failed"; exit 1; }
echo "commit: $(git -C "$SRC" log --oneline -1)"
echo "== change to the clone (as in demo/cjson.sh): register the tests by target name"
sed -i 's|COMMAND "${CMAKE_CURRENT_BINARY_DIR}/${TEST_CJSON}")|COMMAND "${TEST_CJSON}")|' "$SRC/CMakeLists.txt"
sed -i -e 's|COMMAND "./${unity_test}")|COMMAND "${unity_test}")|' -e 's|COMMAND "./${cjson_utils_test}")|COMMAND "${cjson_utils_test}")|' "$SRC/tests/CMakeLists.txt"
echo "lines changed: $(git -C "$SRC" diff --numstat | awk '{ a += $1 } END { print a + 0 }')"
echo
echo "== tools/qnx-ci.sh IMAGE SHARE examples/qnx-unit SHARE/ci-src/cJSON -DENABLE_CJSON_UTILS=ON -DENABLE_CJSON_TEST=ON --filter=.../cJSON.c --filter=.../cJSON_Utils.c"
"$REPO/tools/qnx-ci.sh" "$IMG" "$SHARE" examples/qnx-unit \
    "$SRC" -DENABLE_CJSON_UTILS=ON -DENABLE_CJSON_TEST=ON "--filter=$SRC/cJSON\.c" "--filter=$SRC/cJSON_Utils\.c"
echo "tools/qnx-ci.sh exit status $?"
} 2>&1 | hide | tee "$LOG"
echo "log: ${LOG#$REPO/}"
grep -q '^tools/qnx-ci.sh exit status 0$' "$LOG"
