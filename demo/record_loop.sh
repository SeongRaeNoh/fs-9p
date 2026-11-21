#!/usr/bin/env bash
# demo/record_loop.sh - record the edit-build-run loop in two real terminals as text frames.
# Runs on the Linux machine with QNX SDP 8.0 and QEMU (needs tmux). One tmux window, two panes:
# left a host shell in SHARE/demo, right the guest's serial console started by tools/qnx-share.sh
# with the image of tools/make-image.sh (the image starts a shell on that console). The script types the loop:
# the host builds hello.c with qcc into the share, the guest runs it from /mnt/host/demo, the host
# edits the source and builds again, the guest runs the new program and writes a result file that
# the host reads. After each step it saves the text of both panes (tmux capture-pane) as one frame
# in OUT/frame_NN.left.txt and OUT/frame_NN.right.txt. demo/render_frames.py turns the frames into
# a GIF. Nothing in the frames is edited.
#
# The README picture docs/loop.gif was not made with this script. It was cut from the terminal
# recording of the same loop that the video uses (fs-9p 0.8.0); in that recording the right pane
# is a root shell in the guest over ssh, not the serial console. docs/video_script.md, section
# "README picture", gives the steps (clip, crop, scale, colour palette).
#
# Environment: SDP_ENV, IMAGE (built by tools/make-image.sh), SHARE, SSH_PORT, OUT (frame folder),
#              QEMU_ENV (optional)
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.."
: "${SDP_ENV:?}" "${IMAGE:?}" "${SHARE:?}" "${SSH_PORT:?}" "${OUT:?}"
TOP=$PWD
S=fs9p-rec-$$
TM="tmux -L $S"
rm -rf "$OUT"; mkdir -p "$OUT" "$SHARE/demo"; rm -f "$SHARE/demo/"*
cat > "$SHARE/demo/hello.c" <<'EOF'
#include <stdio.h>
#include <sys/utsname.h>

int main(void)
{
    struct utsname u;
    uname(&u);
    printf("Hello from %s %s, version 1\n", u.sysname, u.release);
    return 0;
}
EOF
cat > "$OUT/host_rc" <<EOF
. '$SDP_ENV' >/dev/null
cd '$SHARE/demo'
PS1='host:~/qnx-share/demo\$ '
EOF
QPRE=""; [ -n "${QEMU_ENV:-}" ] && QPRE=". '$QEMU_ENV' >/dev/null 2>&1; "

pane() { $TM capture-pane -p -J -t "$S:0.$1" 2>/dev/null; }
waitfor() {   # waitfor PANE REGEX SECONDS
    local t=0
    while [ "$t" -lt "$3" ]; do pane "$1" | grep -q -E -- "$2" && return 0; sleep 1; t=$((t + 1)); done
    echo "record_loop: timeout waiting for '$2' in pane $1" >&2; return 1
}
typein() { $TM send-keys -t "$S:0.$1" -l -- "$2"; $TM send-keys -t "$S:0.$1" Enter; }
n=0
frame() { n=$((n + 1)); local f; f=$(printf '%s/frame_%02d' "$OUT" "$n"); pane 0 > "$f.left.txt"; pane 1 > "$f.right.txt"; }

$TM start-server \; new-session -d -s "$S" -x 172 -y 26 "bash --rcfile '$OUT/host_rc' -i" \; \
    split-window -h -t "$S:0" "${QPRE}tools/qnx-share.sh '$IMAGE' '$SHARE' '$SSH_PORT'; sleep 5"
$TM resize-pane -t "$S:0.0" -x 82
waitfor 1 'Startup complete' 300; sleep 2
typein 1 'clear'; sleep 1
typein 1 'cd /mnt/host/demo'; sleep 1
typein 0 'clear'; sleep 1
frame
typein 0 'grep printf hello.c'; sleep 1; frame
typein 0 'qcc -Vgcc_ntox86_64 -o hello hello.c && ls'; waitfor 0 'hello +hello\.c' 60; sleep 1; frame
typein 1 './hello'; waitfor 1 'version 1' 30; frame
typein 0 "sed -i 's/version 1/version 2/' hello.c && grep printf hello.c"; sleep 1; frame
typein 0 'qcc -Vgcc_ntox86_64 -o hello hello.c'; sleep 4; frame
typein 1 './hello'; waitfor 1 'version 2' 30; frame
typein 1 './hello > result.txt; uname -a'; sleep 2; frame
typein 0 'cat result.txt'; waitfor 0 '^Hello from QNX' 20; sleep 1; frame
$TM send-keys -t "$S:0.1" C-a x; sleep 3
$TM kill-server 2>/dev/null
echo "record_loop: $n frames in $OUT"
