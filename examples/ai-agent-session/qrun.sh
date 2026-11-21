#!/usr/bin/env bash
# qrun.sh PROGRAM [args...]
# Runs one program of the last build (path relative to this folder, for example build/test_large)
# inside the QNX 8.0 guest with tools/qnx-run and prints its output and exit status. Run
# ./run_tests.sh first, so that the build is up to date in the shared folder.
# Settings: env.local in this folder (copy env.example); BUILD_HOST empty: run on this machine.
# This is the reader version; session-scripts/qrun.sh is the version that the session ran.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")"
[ $# -ge 1 ] || { sed -n 2,5p "$0"; exit 125; }
[ -f env.local ] || { echo "env.local missing: copy env.example to env.local and edit it"; exit 2; }
. ./env.local
q() { printf '%q' "$1"; }
H() { if [ -n "${BUILD_HOST:-}" ]; then ssh -q "$BUILD_HOST" "$1"; else bash -c "$1"; fi; }
QNX_RUN=$REPO/tools/qnx-run
args=""; for a in "$@"; do args="$args $(q "$a")"; done
H "exec 2>&1; export QNX_SHARE=$(q "$SHARE") QNX_SSH_PORT=$(q "$SSH_PORT") QNX_SSH_KEY=$(q "$SSH_KEY"); cd $(q "$SHARE/$PROJ") && $(q "$QNX_RUN")$args; echo \"exit status \$?\"" 2>/dev/null |
    sed -e "s,$SHARE,SHARE,g"
