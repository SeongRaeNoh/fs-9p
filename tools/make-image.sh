#!/bin/sh
# tools/make-image.sh - build a QNX 8.0 QEMU image (x86_64) with mkqnximage that starts fs-9p at
# boot, so that the guest has the host folder at /mnt/host after login.
#
# usage: tools/make-image.sh IMAGE_DIR [more mkqnximage options]
#   IMAGE_DIR  folder for the image (created if missing; mkqnximage writes local/ and output/)
# Needs: build/fs-9p (run make first) and the QNX SDP 8.0 environment (source qnxsdp-env.sh).
# The script writes two mkqnximage snippet files into IMAGE_DIR/local/snippets/:
#   system_files.fs-9p  puts build/fs-9p into the system partition as /system/bin/fs-9p, and the
#                       OpenSSH helper sshd-auth of the SDP target tree as /system/bin/sshd-auth
#   post_start.fs-9p    starts it at the end of system start-up (copy of image/post_start.fs-9p)
# Then it runs mkqnximage in IMAGE_DIR. Start the image with tools/qnx-share.sh.
# SSH_IDENT: a public key file that mkqnximage puts into the image (--ssh-ident) for ssh logins as
# root without a password; tools/qnx-run and tools/qnx-vm use such a login. Default: the first of
# ~/.ssh/id_ed25519.pub, ~/.ssh/id_ecdsa.pub, ~/.ssh/id_rsa.pub that exists. SSH_IDENT=none builds
# an image without such a login.
# The image also gets /system/bin/fs-9p-supervise (copy of image/fs-9p-supervise), which the boot
# script uses to start fs-9p again when a signal ends it.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR=${1:?usage: tools/make-image.sh IMAGE_DIR [mkqnximage options]}
shift
[ -x "$REPO/build/fs-9p" ] || { echo "make-image: $REPO/build/fs-9p is missing; run make first" >&2; exit 1; }
command -v mkqnximage >/dev/null 2>&1 || { echo "make-image: mkqnximage not found; source qnxsdp-env.sh of QNX SDP 8.0 first" >&2; exit 1; }
mkdir -p "$DIR/local/snippets"
{
    printf '[uid=0 gid=0 perms=0755] bin/fs-9p=%s\n' "$REPO/build/fs-9p"
    printf '[uid=0 gid=0 perms=0755] bin/sshd-auth=usr/libexec/sshd-auth\n'
    printf '[uid=0 gid=0 perms=0755] bin/fs-9p-supervise=%s\n' "$REPO/image/fs-9p-supervise"
} > "$DIR/local/snippets/system_files.fs-9p"
cp "$REPO/image/post_start.fs-9p" "$DIR/local/snippets/post_start.fs-9p"
cd "$DIR"
# --force: the folder is not empty (it holds the snippets)
if [ -z "${SSH_IDENT:-}" ]; then
    for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
        [ -f "$k" ] && { SSH_IDENT=$k; break; }
    done
    [ -n "${SSH_IDENT:-}" ] && echo "make-image: ssh key for root logins: $SSH_IDENT" ||
        echo "make-image: no ~/.ssh/id_*.pub found; the image has no key login (tools/qnx-run needs one; set SSH_IDENT)" >&2
fi
if [ -n "${SSH_IDENT:-}" ] && [ "$SSH_IDENT" != none ]; then
    [ -f "$SSH_IDENT" ] || { echo "make-image: SSH_IDENT=$SSH_IDENT is not a file" >&2; exit 1; }
    IDENT=$(cd "$(dirname "$SSH_IDENT")" && pwd)/$(basename "$SSH_IDENT")
else
    IDENT=none
fi
mkqnximage --type=qemu --arch=x86_64 --force --noprompt --ssh-ident="$IDENT" "$@"
[ -f output/ifs.bin ] && [ -f output/disk-qemu.vmdk ] || { echo "make-image: output/ifs.bin or output/disk-qemu.vmdk missing" >&2; exit 1; }
echo "make-image: image ready in $DIR/output; start it with: tools/qnx-vm start $DIR SHARE_FOLDER (background) or tools/qnx-share.sh $DIR SHARE_FOLDER (console in this terminal)"
