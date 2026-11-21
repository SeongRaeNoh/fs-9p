#!/usr/bin/env bash
# tests/run_guest_tests.sh - run the fs-9p guest tests from the developer machine.
# Copies the sources to the machine that runs QEMU (BUILD_HOST, over ssh), runs tests/host_side.sh
# there and saves the output in tests/logs/. Settings come from tests/env.local (see tests/env.example).
# ssh runs quietly (-q); the remote command sends its stderr to stdout, and the local ssh's own
# stderr is dropped, so that text which a server prints at login does not reach the log.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.."
[ -f tests/env.local ] || { echo "tests/env.local missing; copy tests/env.example and edit it"; exit 2; }
. tests/env.local
: "${BUILD_HOST:?}" "${REMOTE_DIR:?}" "${SDP_ENV:?}" "${SHARE:?}" "${GUEST_SSH:?}" "${GUEST_SCP:?}" "${GUEST_DEST:?}"
mkdir -p tests/logs
LOG=tests/logs/guest_tests_$(date +%Y%m%d_%H%M%S).log
SRCHASH=$(sh tests/srchash.sh)
{
    echo "# fs-9p guest tests, $(date -Iseconds), sources sha256 $SRCHASH (tests/srchash.sh)"
    tar czf - --exclude=./build --exclude=./tests/logs --exclude=./tests/work --exclude=./tests/env.local --exclude=./tests/work_readme --exclude=./share --exclude=./share2 --exclude=./img --exclude=./evidence . |
        ssh -q "$BUILD_HOST" "mkdir -p '$REMOTE_DIR' && cd '$REMOTE_DIR' && tar xzf -" >/dev/null 2>&1 || { echo "copy to $BUILD_HOST failed"; exit 1; }
    ssh -q "$BUILD_HOST" "exec 2>&1; cd '$REMOTE_DIR' && SDP_ENV='$SDP_ENV' SHARE='$SHARE' GUEST_SSH='$GUEST_SSH' GUEST_SCP='$GUEST_SCP' GUEST_DEST='$GUEST_DEST' SHARE2='${SHARE2:-}' SLOW_SHARE='${SLOW_SHARE:-}' SLOW_TAG='${SLOW_TAG:-}' QEMU_ENV='${QEMU_ENV:-}' CMAKE_ENV='${CMAKE_ENV:-}' GCOVR='${GCOVR:-}' bash tests/host_side.sh" 2>/dev/null |
        sed -n '/^@@FS9P@@$/,$p' | sed 1d
} 2>&1 | tee "$LOG"
echo "log: $LOG"
grep -q '^RESULT: [0-9]* passed, 0 failed' "$LOG"
