#!/usr/bin/env bash
# run_tests.sh [ctest arguments...]
# Copies this project into the shared folder on the QEMU host, builds it there with qcc (CMake and
# qnx-x86_64.cmake), and runs ctest there. ctest starts every test binary inside the QNX 8.0 guest
# through tools/qnx-run (CMAKE_CROSSCOMPILING_EMULATOR); the guest runs it from /mnt/host, the
# fs-9p mount of the shared folder. Examples:
#   ./run_tests.sh                       all tests
#   ./run_tests.sh -R test_large -V      one test, with its output
# The guest must be running (./vm_ctl.sh start). Output: build messages and ctest's output; host
# paths of the shared folder are printed as SHARE; ctest's times are removed.
# Settings: env.local in this folder (copy env.example). With BUILD_HOST empty, the commands run on
# this machine; otherwise they run on BUILD_HOST over ssh.
# The copied files get the time of the copy (tar -m), so the build always compiles a changed file,
# also when it changed within the second of the previous build (tar keeps whole seconds).
# This is the reader version; session-scripts/run_tests.sh is the version that the session ran.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")"
[ -f env.local ] || { echo "env.local missing: copy env.example to env.local and edit it"; exit 2; }
. ./env.local
q() { printf '%q' "$1"; }
H() { if [ -n "${BUILD_HOST:-}" ]; then ssh -q "$BUILD_HOST" "$1"; else bash -c "$1"; fi; }
QNX_RUN=$REPO/tools/qnx-run
args=""; for a in "$@"; do args="$args $(q "$a")"; done
D="$SHARE/$PROJ"
tar czf - CMakeLists.txt qnx-x86_64.cmake src tests |
    H "exec 2>&1; mkdir -p $(q "$D") && cd $(q "$D") && rm -rf src tests && tar xzmf -" 2>/dev/null || { echo "copy to the QEMU host failed"; exit 2; }
H "exec 2>&1; . $(q "$SDP_ENV") >/dev/null; . $(q "${CMAKE_ENV:-/dev/null}") >/dev/null
export QNX_SHARE=$(q "$SHARE") QNX_SSH_PORT=$(q "$SSH_PORT") QNX_SSH_KEY=$(q "$SSH_KEY")
cd $(q "$D") || exit 2
echo '== configure and build'
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=qnx-x86_64.cmake -DCMAKE_CROSSCOMPILING_EMULATOR=$(q "$QNX_RUN") >build_configure.log 2>&1 || { cat build_configure.log; exit 2; }
cmake --build build 2>&1 | grep -v -E '^\[ *[0-9]+%\] (Building|Linking)|^Consolidate' ; [ \${PIPESTATUS[0]} = 0 ] || { echo 'build failed'; exit 2; }
echo '== ctest (each test runs in the QNX guest through tools/qnx-run)'
cd build && ctest --output-on-failure$args" 2>/dev/null |
    sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' -e "s,$SHARE,SHARE,g" -e "s,$QNX_RUN,tools/qnx-run,g" -e "s,$(dirname "$SDP_ENV"),SDP,g"
exit "${PIPESTATUS[0]}"
