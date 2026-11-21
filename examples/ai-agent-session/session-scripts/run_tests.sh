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
set -u
cd "$(dirname "$0")"
. ./env.local
q() { printf '%q' "$1"; }
args=""; for a in "$@"; do args="$args $(q "$a")"; done
D="$SHARE/$PROJ"
tar czf - CMakeLists.txt qnx-x86_64.cmake src tests |
    ssh -q "$BUILD_HOST" "exec 2>&1; mkdir -p $(q "$D") && cd $(q "$D") && rm -rf src tests && tar xzf -" 2>/dev/null || { echo "copy to the QEMU host failed"; exit 2; }
ssh -q "$BUILD_HOST" "exec 2>&1; . $(q "$SDP_ENV") >/dev/null; . $(q "$CMAKE_ENV") >/dev/null
export QNX_SHARE=$(q "$SHARE") QNX_SSH=$(q "$VM ssh $VM_NAME")
cd $(q "$D") || exit 2
echo '== configure and build'
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=qnx-x86_64.cmake -DCMAKE_CROSSCOMPILING_EMULATOR=$(q "$QNX_RUN") >build_configure.log 2>&1 || { cat build_configure.log; exit 2; }
cmake --build build 2>&1 | grep -v -E '^\[ *[0-9]+%\] (Building|Linking)|^Consolidate' ; [ \${PIPESTATUS[0]} = 0 ] || { echo 'build failed'; exit 2; }
echo '== ctest (each test runs in the QNX guest through tools/qnx-run)'
cd build && ctest --output-on-failure$args" 2>/dev/null |
    sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' -e "s,$SHARE,SHARE,g" -e "s,$QNX_RUN,tools/qnx-run,g" -e "s,$(dirname "$SDP_ENV"),SDP,g"
exit "${PIPESTATUS[0]}"
