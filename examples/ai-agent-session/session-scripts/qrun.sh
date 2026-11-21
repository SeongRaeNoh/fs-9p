#!/usr/bin/env bash
# qrun.sh PROGRAM [args...]
# Runs one program of the last build (path relative to this folder, for example build/test_large)
# inside the QNX 8.0 guest with tools/qnx-run and prints its output and exit status. Run
# ./run_tests.sh first, so that the build is up to date in the shared folder.
set -u
cd "$(dirname "$0")"
. ./env.local
q() { printf '%q' "$1"; }
[ $# -ge 1 ] || { sed -n 2,5p "$0"; exit 125; }
args=""; for a in "$@"; do args="$args $(q "$a")"; done
ssh -q "$BUILD_HOST" "exec 2>&1; export QNX_SHARE=$(q "$SHARE") QNX_SSH=$(q "$VM ssh $VM_NAME"); cd $(q "$SHARE/$PROJ") && $(q "$QNX_RUN")$args; echo \"exit status \$?\"" 2>/dev/null |
    sed -e "s,$SHARE,SHARE,g"
