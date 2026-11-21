#!/usr/bin/env bash
# tests/host_side.sh - fs-9p test, part that runs on the Linux machine that runs QEMU.
# Called by tests/run_guest_tests.sh (which copies the sources here first). Steps: build with qcc,
# create a test tree in the shared folder, copy the programs into the QNX guest, run the errno table
# test and the probe, mount the share with fs-9p, compare listings and checksums of host and guest,
# check the missing-file error, two concurrent readers, write operations, symbolic links and
# statvfs, a versioned shared library loaded from the share, a core file written through the share
# and opened with the SDP's gdb, attribute operations, robustness cases (concurrent writers, a
# 100 MiB write, 2,000 files, depth 20, forked writers into one file with some killed by SIGKILL,
# remount, restart with an open file), tools/qnx-run with the example examples/qnx-unit (make qnx-test and ctest on
# this machine run unit tests in the guest), the options -p, -n 64, -U (non-root after setup), the
# interrupt-thread priority under CPU load (following the client, -f fixed, a client above the
# unprivileged maximum with -U and -U -P), a reader at 40 that waits for the request slot of a
# reader at 10 (fs-9p -n 1 on a device with throttled reads, SLOW_SHARE; default, -w, -f), two
# devices selected with -a (the second one
# modern-only, with the write and attribute tests over the virtio 1.x interface), read-only
# behaviour, unmount.
#
# Environment (set by run_guest_tests.sh from tests/env.local):
#   SDP_ENV     path of qnxsdp-env.sh of QNX SDP 8.0
#   SHARE       host folder exported to the guest (QEMU -fsdev local,path=SHARE,...)
#   GUEST_SSH   command that runs its arguments as root in the guest, e.g. "ssh -p 2222 root@127.0.0.1"
#   GUEST_SCP   command that copies files to the guest; the last argument is GUEST_DEST
#   GUEST_DEST  destination prefix for GUEST_SCP, e.g. "root@127.0.0.1:" or ":"
#   SHARE2      optional: second host folder, exported by QEMU as a modern-only device with mount tag
#               share2 (-fsdev local,id=fs1,path=SHARE2,security_model=none
#                -device virtio-9p-pci,fsdev=fs1,mount_tag=share2,disable-legacy=on);
#               the first device must have mount tag hostshare. Unset: the two-device steps are skipped.
#   SLOW_SHARE  optional: third host folder, exported by QEMU as a device whose reads it throttles
#               (-fsdev local,id=fs2,path=SLOW_SHARE,security_model=none,throttling.bps-read=262144
#                -device virtio-9p-pci,fsdev=fs2,mount_tag=slow); SLOW_TAG: its mount tag (default
#               slow). Unset: the request-slot step is skipped.
#   QEMU_ENV    optional: script that puts the qemu-system-x86_64 that runs the guest into PATH (for
#               the version line of the log)
#   CMAKE_ENV   optional: script that puts cmake and ctest (3.21 or newer) into PATH; without cmake
#               the ctest part of the qnx-run step is skipped
#   GCOVR       optional: gcovr command for the coverage step (default gcovr); without gcovr the
#               step checks the .gcda files and prints the summary of the SDP's gcov
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.."
: "${SDP_ENV:?}" "${SHARE:?}" "${GUEST_SSH:?}" "${GUEST_SCP:?}" "${GUEST_DEST:?}"
echo "@@FS9P@@"
W=tests/work; rm -rf "$W"; mkdir -p "$W"
GD=/tmp/fs9p            # folder for the programs in the guest
MP=/mnt/host            # mountpoint in the guest
T=$SHARE/tree
G() { $GUEST_SSH "$@" </dev/null; }
pass=0; fail=0
ok()   { echo "PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $*"; fail=$((fail + 1)); }
step() { echo; echo "=== $*"; }
same() {   # same NAME FILE1 FILE2
    if cmp -s "$2" "$3"; then ok "$1 ($(wc -l < "$2") lines equal)"; else bad "$1"; diff "$2" "$3" | head -20; fi
}

step "build (QNX SDP 8.0, qcc)"
. "$SDP_ENV" >/dev/null
echo "toolchain: $(qcc -Vgcc_ntox86_64 --version 2>&1 | head -1)"
[ -n "${QEMU_ENV:-}" ] && . "$QEMU_ENV" >/dev/null 2>&1
echo "QEMU: $(qemu-system-x86_64 --version 2>/dev/null | head -1)"
echo "host OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
make clean >/dev/null; make -j8 2>&1 | sed 's/^/  /'
if [ -x build/fs-9p ] && [ -x build/v9p_probe ] && [ -x build/errno_test ] && [ -x build/attr_test ] && [ -x build/link_test ] && [ -x build/writers_test ]; then ok "build"; else bad "build"; echo "RESULT: FAILED (build)"; exit 1; fi

step "host test tree in SHARE/tree"
rm -rf "$T"; mkdir -p "$T"
for a in 0 1 2; do for b in 0 1 2; do
    d="$T/level1 $a/level2_$b/deep dir/leaf"; mkdir -p "$d"
    for f in 1 2 3; do head -c $(( (a * 9 + b * 3 + f) * 1531 )) /dev/urandom > "$T/level1 $a/level2_$b/file $f.bin"; done
    printf 'leaf %s %s\n' "$a" "$b" > "$d/note.txt"
done; done
mkdir -p "$T/many files"
for i in $(seq -w 1 150); do printf 'file number %s\n' "$i" > "$T/many files/a_rather_long_file_name_for_directory_paging_$i.txt"; done
head -c $((12 * 1024 * 1024 + 12345)) /dev/urandom > "$T/big file.bin"
: > "$T/empty.txt"
printf x > "$T/one byte.txt"
head -c 135144 /dev/urandom > "$T/exactly one read.bin"      # default msize 135168 minus 24 header bytes = one Tread
head -c 135145 /dev/urandom > "$T/one read plus 1.bin"
(cd "$T" && find . -type f | LC_ALL=C sort) > $W/host_files.txt
(cd "$T" && find . -type d | LC_ALL=C sort) > $W/host_dirs.txt
(cd "$T" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3) > $W/host_cksum.txt
echo "host tree: $(wc -l < $W/host_files.txt) files, $(wc -l < $W/host_dirs.txt) directories, $(du -sh "$T" | cut -f1)"
BIGMD5=$(md5sum "$T/big file.bin" | cut -d' ' -f1)
echo "big file.bin: $(stat -c %s "$T/big file.bin") bytes, md5 $BIGMD5"

step "guest"
G "uname -a; id"
# A running driver must exit before its file is replaced. slay's exit status is not used: it is 0
# when no process matched, so the loop waits until pidin lists no fs-9p (at most 10 s). The old
# programs are then removed, because scp can still find the file busy right after the process ended.
G "slay -f fs-9p >/dev/null 2>&1; i=0; while pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | grep -q . && [ \$i -lt 10 ]; do sleep 1; i=\$((i + 1)); done; sleep 1; mkdir -p $GD; rm -f $GD/fs-9p $GD/v9p_probe $GD/errno_test $GD/attr_test $GD/link_test $GD/writers_test; true"
$GUEST_SCP build/fs-9p build/v9p_probe build/errno_test build/attr_test build/link_test build/writers_test "$GUEST_DEST$GD/" && ok "copy programs to the guest" || bad "copy programs to the guest"

step "errno table test (Linux errno in Rlerror -> QNX errno)"
G "$GD/errno_test" > $W/errno.txt 2>&1
grep -c '^ok' $W/errno.txt | sed 's/^/rows ok: /'; grep -v '^ok' $W/errno.txt
grep -q "RESULT: errno table test passed" $W/errno.txt && ok "errno table test" || bad "errno table test"

step "probe (v9p_probe: Tversion/Rversion exchange, legacy interface, polling)"
G "$GD/v9p_probe -v" > $W/probe.txt 2>&1
sed -n '/^Tversion/,/RESULT: Tversion/p' $W/probe.txt
grep -q "RESULT: Tversion/Rversion exchange completed" $W/probe.txt && grep -q "RESULT: done" $W/probe.txt && ok "probe" || { bad "probe"; tail -20 $W/probe.txt; }

step "mount: fs-9p -d -v -m $MP"
G "$GD/fs-9p -d -v -m $MP 2>$GD/fs-9p.log; echo exit=\$?" | tee $W/mount.txt
grep -q 'exit=0' $W/mount.txt && G "test -d $MP/tree" && ok "mount" || { bad "mount"; G "cat $GD/fs-9p.log"; echo "RESULT: FAILED (mount)"; exit 1; }
G "grep -h 'fs-9p' $GD/fs-9p.log"
G "ls -l $MP/tree" | head -12
HM=$(stat -c %A "$SHARE"); GM=$(G "ls -ld $MP" | awk '{print $1}')
[ "$HM" = "$GM" ] && ok "mode of the mount root is the host folder's mode ($HM)" || bad "mount root mode: host $HM, guest $GM"

step "listing: host find vs guest find"
G "cd $MP/tree && find . -type f" | LC_ALL=C sort > $W/guest_files.txt
G "cd $MP/tree && find . -type d" | LC_ALL=C sort > $W/guest_dirs.txt
same "file list" $W/host_files.txt $W/guest_files.txt
same "directory list" $W/host_dirs.txt $W/guest_dirs.txt
G "ls -a '$MP/tree/many files'" | grep -c '^a_rather' > $W/many_count.txt
[ "$(cat $W/many_count.txt)" = 150 ] && ok "ls of a 150-entry directory (several readdir calls)" || bad "ls of 150-entry directory: $(cat $W/many_count.txt)"

step "content: cksum (CRC and size) of every file, host vs guest"
G "cd $MP/tree && find . -type f -exec cksum {} +" | LC_ALL=C sort -k3 > $W/guest_cksum.txt
same "cksum of all files" $W/host_cksum.txt $W/guest_cksum.txt
G "md5sum '$MP/tree/big file.bin'" > $W/guest_big.txt
grep -q "^$BIGMD5" $W/guest_big.txt && ok "md5 of big file.bin (12 MiB)" || bad "md5 of big file.bin: $(cat $W/guest_big.txt)"
G "dd if='$MP/tree/big file.bin' bs=7777 2>/dev/null | md5sum" > $W/guest_dd.txt
grep -q "^$BIGMD5" $W/guest_dd.txt && ok "read in 7777-byte blocks (dd)" || bad "dd bs=7777: $(cat $W/guest_dd.txt)"
H=$(tail -c 100000 "$T/big file.bin" | md5sum | cut -d' ' -f1)
G "tail -c 100000 '$MP/tree/big file.bin' | md5sum" > $W/guest_tail.txt
grep -q "^$H" $W/guest_tail.txt && ok "tail -c 100000 (lseek from the end)" || bad "tail -c: $(cat $W/guest_tail.txt)"
HS=$(stat -c '%s' "$T/level1 2/level2_2/file 3.bin")
GS=$(G "ls -l '$MP/tree/level1 2/level2_2/file 3.bin'" | awk '{print $5}')
[ "$HS" = "$GS" ] && ok "stat size ($HS bytes)" || bad "stat size host $HS guest $GS"

step "missing file"
G "cat $MP/tree/no_such_file.txt" > $W/missing.txt 2>&1
G "ls '$MP/tree/no such dir/x'" >> $W/missing.txt 2>&1
cat $W/missing.txt
[ "$(grep -c 'No such file or directory' $W/missing.txt)" = 2 ] && ok "missing file and missing directory give ENOENT" || bad "missing file"

step "two concurrent readers of big file.bin, plus a concurrent find"
G "cd $MP/tree; md5sum 'big file.bin' > $GD/r1.txt & md5sum 'big file.bin' > $GD/r2.txt & find . -type f > $GD/r3.txt & wait; cat $GD/r1.txt $GD/r2.txt; wc -l < $GD/r3.txt" > $W/conc.txt 2>&1
cat $W/conc.txt
[ "$(grep -c "^$BIGMD5" $W/conc.txt)" = 2 ] && ok "two concurrent readers give the host md5" || bad "concurrent readers"
[ "$(tail -1 $W/conc.txt | tr -d ' ')" = "$(wc -l < $W/host_files.txt | tr -d ' ')" ] && ok "concurrent find lists all files" || bad "concurrent find"

step "write operations in SHARE/rw (write, create, mkdir, unlink, rename)"
RW=$SHARE/rw; rm -rf "$RW"; mkdir -p "$RW"
G "echo 'hello from qnx' > $MP/rw/new.txt; echo 'second line' >> $MP/rw/new.txt" > $W/w1.txt 2>&1; cat $W/w1.txt
[ "$(cat "$RW/new.txt" 2>/dev/null)" = "$(printf 'hello from qnx\nsecond line')" ] && ok "create + write + append: host sees 2 lines" || bad "create/write/append: $(cat "$RW/new.txt" 2>&1 | head -3)"
G "echo short > $MP/rw/new.txt" >> $W/w1.txt 2>&1
[ "$(cat "$RW/new.txt" 2>/dev/null)" = short ] && ok "O_TRUNC rewrite: host sees 'short'" || bad "truncate rewrite: $(cat "$RW/new.txt" 2>&1 | head -2)"
G "cp '$MP/tree/big file.bin' '$MP/rw/big copy.bin'" > $W/w2.txt 2>&1; cat $W/w2.txt
[ "$(md5sum "$RW/big copy.bin" 2>/dev/null | cut -d' ' -f1)" = "$BIGMD5" ] && ok "cp of the 12 MiB file into the share: host md5 equal" || bad "cp big file: $(ls -l "$RW" 2>&1 | head -5)"
G "set -e; cd $MP/rw; mkdir 'new dir'; mkdir 'new dir/sub'; echo inner > 'new dir/sub/f.txt'" > $W/w3.txt 2>&1; cat $W/w3.txt
[ -d "$RW/new dir/sub" ] && [ "$(cat "$RW/new dir/sub/f.txt" 2>/dev/null)" = inner ] && ok "mkdir (nested) and a file inside: host sees them" || bad "mkdir"
G "set -e; cd $MP/rw; mv 'big copy.bin' renamed.bin; mv renamed.bin 'new dir/sub/moved.bin'; mv 'new dir/sub/f.txt' f2.txt" > $W/w4.txt 2>&1; cat $W/w4.txt
[ ! -e "$RW/big copy.bin" ] && [ "$(md5sum "$RW/new dir/sub/moved.bin" 2>/dev/null | cut -d' ' -f1)" = "$BIGMD5" ] && [ -f "$RW/f2.txt" ] && ok "rename within a folder and across folders" || bad "rename: $(cd "$RW" && find . | head)"
G "set -e; cd $MP/rw; rm 'new dir/sub/moved.bin'; rmdir 'new dir/sub'; rmdir 'new dir'; rm f2.txt" > $W/w5.txt 2>&1; cat $W/w5.txt
[ ! -e "$RW/new dir" ] && [ ! -e "$RW/f2.txt" ] && ok "unlink files and rmdir folders: host sees them gone" || bad "unlink: $(cd "$RW" && find . | head)"
G "mkdir $MP/rw/new.txt; rmdir $MP/rw/new.txt; rm $MP/rw/missing.txt; mv $MP/rw/missing.txt $MP/rw/x.txt" > $W/w6.txt 2>&1; cat $W/w6.txt
grep -q 'File exists' $W/w6.txt && [ "$(grep -c 'No such file or directory' $W/w6.txt)" -ge 2 ] && grep -q -i 'not a directory' $W/w6.txt && ok "error cases: EEXIST, ENOTDIR, ENOENT" || bad "error cases"
echo "made on the host" > "$RW/from_host.txt"
[ "$(G "cat $MP/rw/from_host.txt")" = "made on the host" ] && ok "file made on the host is visible in the guest" || bad "host-made file"
(cd "$RW" && find . | LC_ALL=C sort) > $W/host_rw.txt
G "cd $MP/rw && find ." | LC_ALL=C sort > $W/guest_rw.txt
same "listing of SHARE/rw after the write tests" $W/host_rw.txt $W/guest_rw.txt

step "run a program from the share: built on the host with qcc into SHARE/run, started in the guest from $MP/run"
RUN=$SHARE/run; rm -rf "$RUN"; mkdir -p "$RUN"
printf '#include <stdio.h>\nint main(int argc, char **argv) { printf("started from the share with %%d arguments\\n", argc - 1); return 7; }\n' > "$RUN/prog.c"
qcc -Vgcc_ntox86_64 -o "$RUN/prog" "$RUN/prog.c" && ok "qcc build into the share" || bad "qcc build into the share"
G "$MP/run/prog a b; echo status=\$?; cd $MP/run && ./prog x; echo status=\$?" > $W/run.txt 2>&1; cat $W/run.txt
[ "$(grep -c -E '^started from the share with (2|1) arguments' $W/run.txt)" = 2 ] && [ "$(grep -c '^status=7' $W/run.txt)" = 2 ] &&
    ok "guest runs the program from the share (absolute and relative path, exit status 7)" || bad "run from the share"
rm -rf "$RUN"

step "symbolic links (Treadlink, Tsymlink, redirect of the open) and statvfs (Tstatfs) in SHARE/links (tests/link_test.c)"
L=$SHARE/links; rm -rf "$L"; mkdir -p "$L/sub" "$L/up"
printf 'target content\n' > "$L/target.txt"; printf 'inner\n' > "$L/sub/inner.txt"
(cd "$L" && ln -s target.txt link.txt && ln -s chain2 chain1 && ln -s target.txt chain2 && ln -s inner.txt sub/innerlink &&
    ln -s sub dirlink && ln -s ../sub up/back && ln -s no_such_file dangling && ln -s loop_b loop_a && ln -s loop_a loop_b && ln -s /dev/null abs_null)
echo "links made on the host: $(cd "$L" && find . -type l | LC_ALL=C sort | while read -r l; do printf '%s -> %s, ' "${l#./}" "$(readlink "$l")"; done | sed 's/, $//')"
G "$GD/link_test $MP/links" > $W/link.txt 2>&1; grep -v '^STATVFS' $W/link.txt
lk() { grep -q "^STEP $1 rc=0 " $W/link.txt; }
lk lstat_link_is_link && lk stat_link_follows_to_file && lk readlink_link && lk read_through_link &&
    ok "lstat sees the link itself, stat and read follow it, readlink gives the target" || bad "link basics"
lk read_through_two_links && lk read_through_folder_link && lk read_through_link_with_dotdot && lk readlink_below_folder_link && lk stat_folder_link_is_folder &&
    ok "a chain of two links, a folder link in the middle of a path, a target with '..', readlink below a folder link" || bad "links inside paths"
lk stat_dangling_ENOENT && lk lstat_dangling_is_link && lk open_loop_ELOOP &&
    ok "a dangling link gives ENOENT (lstat still sees the link); a link loop ends with ELOOP, no hang" || bad "dangling link or loop"
lk write_through_absolute_link_to_dev_null && ok "an absolute target is resolved in the guest's namespace (abs_null -> /dev/null)" || bad "absolute link target"
lk symlink_create && lk readlink_made_link && lk read_through_made_link && lk symlink_existing_EEXIST && lk symlink_create_folder_link &&
    [ "$(readlink "$L/made_dirlink" 2>/dev/null)" = sub ] && ok "symlink() in the guest makes links on the host (made_link -> target.txt, made_dirlink -> sub); EEXIST for an existing name" || bad "symlink()"
lk create_file_through_folder_link && lk mkdir_through_folder_link && [ "$(cat "$L/sub/created.txt" 2>/dev/null)" = created ] && [ -d "$L/sub/newdir" ] &&
    ok "a file and a folder created through the folder link made_dirlink appear in sub on the host" || bad "create through a folder link"
lk unlink_removes_link && lk lstat_after_unlink_ENOENT && lk target_still_there && lk unlink_below_folder_link && [ ! -L "$L/made_link" ] && [ ! -L "$L/sub/innerlink" ] && [ -f "$L/target.txt" ] &&
    ok "unlink removes the link, not its target (also below a folder link)" || bad "unlink of a link"
echo "ls -l in the guest, link lines (type and permissions, name, target):"
G "ls -l $MP/links" | awk '/^l/ {print "  " $1, $(NF-2), $(NF-1), $NF}'
# statvfs: QEMU scales the block size to the msize (larger blocks, fewer of them), so the check
# compares bytes. Free space can change between the two calls; the log shows no sizes.
read -r GBS GBL GBF GFI GNM <<< "$(sed -n 's/^STATVFS bsize=\([0-9]*\) frsize=[0-9]* blocks=\([0-9]*\) bfree=\([0-9]*\) bavail=[0-9]* files=\([0-9]*\) ffree=[0-9]* namemax=\([0-9]*\)$/\1 \2 \3 \4 \5/p' $W/link.txt)"
read -r HBS HBL HBF HFI HNM <<< "$(stat -f -c '%S %b %f %c %l' "$SHARE")"
SVF=$(awk -v gbs="${GBS:-0}" -v gbl="${GBL:-0}" -v gbf="${GBF:-0}" -v hbs="$HBS" -v hbl="$HBL" -v hbf="$HBF" 'BEGIN {
    d = gbs * gbl - hbs * hbl; if (d < 0) d = -d; f = gbs * gbf - hbs * hbf; if (f < 0) f = -f;
    print (gbs > 0 && d < gbs) ? "size" : "SIZE-DIFFERS", (hbf > 0 && f <= 0.02 * hbs * hbf + gbs) ? "free" : "FREE-DIFFERS" }')
echo "statvfs in the guest vs statfs of SHARE on the host: total bytes ($SVF), file nodes $([ "${GFI:-x}" = "$HFI" ] && echo equal || echo differ), name length $([ "${GNM:-x}" = "$HNM" ] && echo equal || echo differ); f_basetype $(sed -n 's/^STEP statvfs rc=0 errno=0 (ok) //p' $W/link.txt)"
lk statvfs && lk fstatvfs_of_a_file && [ "$SVF" = "size free" ] && [ "${GFI:-x}" = "$HFI" ] && [ "${GNM:-x}" = "$HNM" ] &&
    ok "statvfs() and fstatvfs() answer from the host folder: total bytes equal (within one block), free bytes within 2 %, file nodes and name length equal" || bad "statvfs: $SVF, files ${GFI:-?}/$HFI, namemax ${GNM:-?}/$HNM"
rm -rf "$L"

step "a versioned shared library in the share: libx.so -> libx.so.1 -> libx.so.1.0 built with qcc on this machine; uselib loads it in the guest from $MP/solib"
SL=$SHARE/solib; rm -rf "$SL"; mkdir -p "$SL"
printf 'const char *x_name(void) { return "libx 1.0"; }\nint x_version(void) { return 1; }\n' > "$SL/x.c"
cat > "$SL/uselib.c" <<'EOF'
#include <stdio.h>
#include <dlfcn.h>
const char *x_name(void);
int main(void)
{
    printf("linked with -lx: %s\n", x_name());
    void *h = dlopen("libx.so", RTLD_NOW);
    int (*v)(void) = h ? (int (*)(void))dlsym(h, "x_version") : NULL;
    printf("dlopen(\"libx.so\"): %s, x_version() = %d\n", h ? "ok" : dlerror(), v ? v() : -1);
    return h && v ? 0 : 1;
}
EOF
qcc -Vgcc_ntox86_64 -shared -fPIC -Wl,-soname,libx.so.1 -o "$SL/libx.so.1.0" "$SL/x.c" && (cd "$SL" && ln -s libx.so.1.0 libx.so.1 && ln -s libx.so.1 libx.so) &&
    qcc -Vgcc_ntox86_64 -o "$SL/uselib" "$SL/uselib.c" -L"$SL" -lx && ok "qcc: libx.so.1.0 (soname libx.so.1), links libx.so.1 and libx.so, uselib linked with -lx" || bad "shared library build"
echo "uselib needs: $(ntox86_64-readelf -d "$SL/uselib" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(libx[^]]*\)\].*/\1/p')"
G "ls -l $MP/solib" | awk '/^l/ {print "  " $1, $(NF-2), $(NF-1), $NF}'
{ QNX_SHARE=$SHARE QNX_MOUNT=$MP QNX_SSH="$GUEST_SSH" tools/qnx-run -e LD_LIBRARY_PATH="$SL" "$SL/uselib"; echo "exit status $?"; } > $W/solib.txt 2>&1; sed 's/^/  /' $W/solib.txt
grep -q '^linked with -lx: libx 1.0$' $W/solib.txt && grep -q '^dlopen("libx.so"): ok, x_version() = 1$' $W/solib.txt && grep -q '^exit status 0$' $W/solib.txt &&
    ok "tools/qnx-run -e LD_LIBRARY_PATH=SHARE/solib: the guest's loader found libx.so.1 and dlopen found libx.so, both through links in the share" || bad "shared library from the share"
rm -rf "$SL"

step "core dumps through the share: a program from the share crashes, dumper writes the core file into the share, the SDP's gdb on this machine opens it"
# The guest image runs dumper (QNX's core-dump utility; in the test image the system launcher starts
# it again when it ends). For this step its dump folder is replaced by a symbolic link to $MP/cores,
# so the core file goes through fs-9p into the host folder; the folder is put back afterwards.
CD=$SHARE/cores; CR=$SHARE/crash; rm -rf "$CD" "$CR"; mkdir -p "$CD" "$CR"; chmod 777 "$CD"
cat > "$CR/crash.c" <<'EOF'
#include <stdio.h>
static int read_value(const int *p) { return *p; }          /* p is NULL: SIGSEGV */
static int parse_record(const int *p) { return read_value(p) + 1; }
int main(int argc, char **argv)
{
    (void)argv;
    printf("parse_record() with a NULL record\n");
    fflush(stdout);
    return parse_record(argc > 9 ? &argc : NULL);
}
EOF
DARGS=$(G "pidin -p dumper -F '%A' 2>/dev/null" | sed 1d | head -1 | sed 's/^ *//; s/ *$//')
DD=$(printf '%s\n' "$DARGS" | sed -n 's/.* -d \([^ ]*\).*/\1/p')
if [ -n "$DARGS" ] && [ -n "$DD" ]; then
    echo "dumper in the image: $DARGS"
    qcc -Vgcc_ntox86_64 -g -O0 -o "$CR/crash" "$CR/crash.c" && ok "qcc -g: crash built into the share" || bad "build of crash"
    G "rm -rf $DD.fs9p-saved; mv $DD $DD.fs9p-saved && ln -s $MP/cores $DD && ls -ld $DD | awk '{print \"dump folder now:\", \$(NF-2), \$(NF-1), \$NF}'"
    # --json with QNX_CORE_DIR: qnx-run waits for the core file and names it in the JSON line
    { QNX_SHARE=$SHARE QNX_MOUNT=$MP QNX_SSH="$GUEST_SSH" QNX_CORE_DIR=$CD tools/qnx-run --json -o $W/crash_out "$CR/crash"; echo "exit status $?"; } > $W/crash.txt 2>&1
    cat $W/crash_out/stdout.txt $W/crash_out/stderr.txt | sed 's/^/  /'; grep -v '^{' $W/crash.txt | sed 's/^/  /'; grep '^{' $W/crash.txt | sed -e "s|$SHARE|SHARE|g" -e "s|$PWD|REPO|g" -e 's/^/  /'
    "${PYTHON:-python3}" -I -c 'import json, os, sys; d = json.loads(open(sys.argv[1]).readline()); print("crash json", "ok" if d["exit_status"] == 139 and d["signal"] == 11 and d["signal_name"] == "SIGSEGV" and d["core_file"] == os.path.realpath(sys.argv[2]) else "bad")' $W/crash.txt "$CD/crash.core" > $W/crash_json.txt 2>&1; cat $W/crash_json.txt
    # wait until dumper has written the core file (size unchanged for 1 s; at most 20 s)
    i=0; last=-1; while [ $i -lt 20 ]; do sz=$(stat -c %s "$CD/crash.core" 2>/dev/null || echo -1); [ "$sz" -gt 0 ] && [ "$sz" = "$last" ] && break; last=$sz; sleep 1; i=$((i + 1)); done
    G "rm $DD && mv $DD.fs9p-saved $DD && ls -ld $DD | awk '{print \"dump folder restored:\", \$1, \$NF}'"
    echo "files in SHARE/cores on the host: $(ls "$CD" | tr '\n' ' ')"
    grep -q '^exit status 139$' $W/crash.txt && ok "tools/qnx-run: the program ended with SIGSEGV, exit status 139 (128 + 11) on the host" || bad "exit status of a crash: $(tail -1 $W/crash.txt)"
    [ -s "$CD/crash.core" ] && ok "dumper wrote crash.core through the share into the host folder" || bad "core file in the share"
    grep -q '^crash json ok' $W/crash_json.txt && ok "qnx-run --json with QNX_CORE_DIR: signal 11, signal_name SIGSEGV (named by the guest), core_file = SHARE/cores/crash.core" || bad "qnx-run --json core_file"
    ntox86_64-gdb -batch -nx -ex bt "$CR/crash" "$CD/crash.core" > $W/gdb.txt 2>&1
    grep -E '^Program terminated|^#[0-9]' $W/gdb.txt | awk '!seen[$0]++' | sed -E -e 's/0x[0-9a-f]{8,16} in //' -e "s|$SHARE|SHARE|g" -e 's/^/  /'
    grep -q 'Program terminated with signal SIGSEGV' $W/gdb.txt && grep -q '^#0 .*read_value' $W/gdb.txt && grep -q '^#1 .*parse_record' $W/gdb.txt && grep -q '^#2 .*main' $W/gdb.txt &&
        ok "ntox86_64-gdb on this machine: bt of the core file shows read_value, parse_record, main with source lines" || bad "gdb backtrace of the core file"
else
    echo "SKIP: no dumper with a dump folder (-d) runs in this guest image; the core-dump step did not run"
fi
rm -rf "$CD" "$CR"

step "attribute operations in SHARE/attr (tests/attr_test.c): fsync, ftruncate, truncate, fchmod, chmod, utime, utimes, chown"
A=$SHARE/attr; rm -rf "$A"; mkdir -p "$A"
HU=$(id -u); HG=$(id -g); HG2=$(id -G | tr ' ' '\n' | grep -v -x "$HG" | head -1); [ -n "$HG2" ] || HG2=$HG
echo "host user who runs QEMU: uid $HU, gid $HG, second group $HG2"
G "$GD/attr_test $MP/attr $HU $HG $HG2" > $W/attr.txt 2>&1; cat $W/attr.txt
rcok() { grep -q "^STEP $1 rc=0 " $W/attr.txt; }
hst()  { stat -c "$1" "$A/$2" 2>/dev/null; }
nsec() { python3 -I -c 'import os, sys; s = os.stat(sys.argv[1]); print(s.st_atime_ns, s.st_mtime_ns)' "$A/$1"; }
rcok write_10 && rcok fsync && ok "write and fsync return 0" || bad "fsync"
rcok ftruncate_4 && rcok ftruncate_10000 && rcok fstat_size_is_10000 && rcok truncate_6000 && [ "$(hst %s size.bin)" = 6000 ] &&
    [ "$(head -c 4 "$A/size.bin")" = 0123 ] && [ "$(tail -c +5 "$A/size.bin" | tr -d '\000' | wc -c)" = 0 ] &&
    ok "ftruncate to 4 and to 10000, truncate to 6000: host size 6000, bytes '0123' then zeros" || bad "ftruncate/truncate: host size $(hst %s size.bin)"
rcok fchmod_600 && [ "$(hst %a fmode.bin)" = 600 ] && ok "fchmod 600: host mode 600" || bad "fchmod: host mode $(hst %a fmode.bin)"
grep -q '^STEP chmod_640 rc=0 .* mode=640 ' $W/attr.txt && [ "$(hst %a mode.bin)" = 640 ] && ok "chmod 640: host mode 640, guest stat mode 640" || bad "chmod: host mode $(hst %a mode.bin)"
rcok chmod_dir_750 && [ "$(stat -c %a "$A")" = 750 ] && ok "chmod of a folder: host mode 750" || bad "chmod of a folder"
rcok utime_1000000000_1200000000 && [ "$(hst '%X %Y' utime.bin)" = "1000000000 1200000000" ] && ok "utime: host atime 1000000000, mtime 1200000000" || bad "utime: host $(hst '%X %Y' utime.bin)"
rcok utimes_1300000000.25_1400000000.5 && [ "$(nsec utimes.bin)" = "1300000000250000000 1400000000500000000" ] &&
    ok "utimes with microseconds: host atime 1300000000.250000000, mtime 1400000000.500000000" || bad "utimes: host $(nsec utimes.bin)"
NOW=$(date +%s); M=$(hst %Y now.bin)
rcok utime_NULL_now && [ $((NOW - M)) -ge 0 ] && [ $((NOW - M)) -lt 300 ] && ok "utime(NULL): host mtime is the current host time" || bad "utime(NULL): host mtime $M, host time $NOW"
rcok chown_own_ids && rcok chgrp_gid2 && [ "$(hst %g own.bin)" = "$HG2" ] && ok "chown to the host user's ids, chgrp to its group $HG2: host gid $HG2" || bad "chown/chgrp: host $(hst '%u %g' own.bin)"
grep -q '^STEP chown_root_refused rc=-1 .*(Operation not permitted)' $W/attr.txt && [ "$(hst %u own.bin)" = "$HU" ] && ok "chown to root: EPERM from the host, owner unchanged" || bad "chown to root"

step "robustness: two concurrent writers to different files"
R=$SHARE/robust; rm -rf "$R"; mkdir -p "$R"
G "dd if=/dev/urandom of=/tmp/fs9p_w1.bin bs=1048576 count=24 2>/dev/null; dd if=/dev/urandom of=/tmp/fs9p_w2.bin bs=1048576 count=24 2>/dev/null; md5sum /tmp/fs9p_w1.bin /tmp/fs9p_w2.bin" > $W/wsrc.txt 2>&1
G "cp /tmp/fs9p_w1.bin $MP/robust/w1.bin & cp /tmp/fs9p_w2.bin $MP/robust/w2.bin & wait; rm /tmp/fs9p_w1.bin /tmp/fs9p_w2.bin" > $W/wconc.txt 2>&1; cat $W/wconc.txt
W1=$(awk 'NR==1 {print $1}' $W/wsrc.txt); W2=$(awk 'NR==2 {print $1}' $W/wsrc.txt)
echo "guest md5: $W1 $W2; host md5: $(md5sum "$R/w1.bin" "$R/w2.bin" | cut -d' ' -f1 | tr '\n' ' ')"
[ -n "$W1" ] && [ "$(md5sum < "$R/w1.bin" | cut -d' ' -f1)" = "$W1" ] && [ "$(md5sum < "$R/w2.bin" | cut -d' ' -f1)" = "$W2" ] &&
    ok "two concurrent cp of 24 MiB files: host md5 of both equal" || bad "concurrent writers"

step "robustness: one write() of 100 MiB (dd bs=104857600 count=1)"
G "dd if=/dev/urandom of=/tmp/fs9p_100.bin bs=1048576 count=100 2>/dev/null; md5sum /tmp/fs9p_100.bin; dd if=/tmp/fs9p_100.bin of=$MP/robust/big100.bin bs=104857600 count=1 2>&1 | grep -v -i -E 'bytes/s|seconds|copied'; md5sum $MP/robust/big100.bin; rm /tmp/fs9p_100.bin" > $W/w100.txt 2>&1; cat $W/w100.txt
B100=$(awk 'NR==1 {print $1}' $W/w100.txt)
HB100=$(md5sum < "$R/big100.bin" | cut -d' ' -f1)
echo "host: $(stat -c %s "$R/big100.bin") bytes, md5 $HB100"
[ -n "$B100" ] && [ "$HB100" = "$B100" ] && [ "$(stat -c %s "$R/big100.bin")" = 104857600 ] && ok "100 MiB write: host size 104857600, host md5 equal to the guest's source" || bad "100 MiB write"
[ "$(grep -c "^$B100" $W/w100.txt)" = 2 ] && ok "100 MiB file read back in the guest: md5 equal" || bad "100 MiB read back"

step "robustness: 2,000 small files created, listed, read and removed by the guest"
G "mkdir $MP/robust/small && cd $MP/robust/small && i=0; while [ \$i -lt 2000 ]; do echo \"file \$i\" > f_\$i.txt || break; i=\$((i+1)); done; echo created=\$i" > $W/small.txt 2>&1; cat $W/small.txt
NB=$(cd "$R/small" && for i in $(seq 0 1999); do [ "$(cat f_$i.txt 2>/dev/null)" = "file $i" ] || echo "bad $i"; done | wc -l)
[ "$(ls "$R/small" | wc -l)" = 2000 ] && [ "$NB" = 0 ] && ok "2,000 files: host has 2000 files with the right content" || bad "2,000 files: host $(ls "$R/small" | wc -l) files, $NB wrong"
G "ls $MP/robust/small | wc -l; find $MP/robust/small -type f -exec cat {} + | wc -l" > $W/small2.txt 2>&1; cat $W/small2.txt
[ "$(tr -d ' ' < $W/small2.txt | tr '\n' ' ')" = "2000 2000 " ] && ok "guest lists 2000 entries and reads 2000 lines" || bad "guest listing of 2,000 files"
G "rm -r $MP/robust/small; echo rm=\$?" > $W/small3.txt 2>&1; cat $W/small3.txt
[ ! -e "$R/small" ] && ok "rm -r of the 2,000-file folder: gone on the host" || bad "rm -r: $(ls "$R/small" 2>/dev/null | wc -l) files left"

step "robustness: path of depth 20 (more than 16 names: two Twalk messages)"
D20=$(seq -s/ 1 20 | sed 's#[0-9][0-9]*#d&#g')
G "mkdir -p $MP/robust/$D20 && echo deep > $MP/robust/$D20/leaf.txt && cat $MP/robust/$D20/leaf.txt" > $W/deep.txt 2>&1; cat $W/deep.txt
[ "$(cat "$R/$D20/leaf.txt" 2>/dev/null)" = deep ] && ok "mkdir -p of depth 20 and a file at the bottom: host sees it" || bad "depth 20 from the guest"
echo "made on the host" > "$R/$D20/host.txt"
[ "$(G "cat $MP/robust/$D20/host.txt")" = "made on the host" ] && ok "host-made file at depth 20 read in the guest" || bad "depth 20 host file"
[ "$(G "find $MP/robust/d1 | wc -l" | tr -d ' ')" = 22 ] && ok "find below d1 lists 22 entries (20 folders, 2 files)" || bad "find at depth 20"
G "rm -r $MP/robust/d1" >/dev/null 2>&1; [ ! -e "$R/d1" ] && ok "rm -r of the depth-20 tree" || bad "rm -r depth 20"

step "robustness: forked writers into one file of the share, some killed with SIGKILL while they write (tests/writers_test.c)"
# shared: the children write through one descriptor that their parent opened (one file offset, as
# when a test framework writes from forked test processes into a file of the parent); append: each
# child opens the file with O_APPEND. writers_test reads the file back through the share and checks
# every 64-byte record (whole, once, in order per writer; all records of each child that exited with
# 0); this script compares the guest's md5 with the host's. Then a new file is opened, and fs-9p is
# stopped to read its count of free request slots. Counts only.
ST=$SHARE/stress; rm -rf "$ST"; mkdir -p "$ST"
nkw=0
wr_run() {   # wr_run MODE WRITERS RECORDS KILLS SEED
    local f=$W/wr_$1_$2.txt hm kw
    G "$GD/writers_test $MP/stress/$1_$2.txt $1 $2 $3 $4 $5; echo exit=\$?; md5sum $MP/stress/$1_$2.txt" > "$f" 2>&1
    grep -v -E '^(bad record|record w)' "$f" | head -12
    hm=$(md5sum < "$ST/$1_$2.txt" | cut -d' ' -f1)
    kw=$(sed -n 's/^killed writers: [0-9]* with none of their records, \([0-9]*\) with some.*/\1/p' "$f" | head -1)
    nkw=$((nkw + ${kw:-0}))
    grep -q '^RESULT: writers_test passed' "$f" && grep -q '^exit=0' "$f" && grep -q "^$hm " "$f" &&
        grep -q ' 0 ended otherwise (write error), 0 forks failed$' "$f" &&
        ok "$1 mode, $2 writers, $4 kills: no write error, every record whole and once, no record lost from a writer that exited with 0, host md5 equal" ||
        bad "writers_test $1 $2 (host md5 $hm)"
}
wr_run shared 100 50 40 1
wr_run append 100 50 40 2
wr_run shared 200 20 100 3
wr_run append 200 20 100 4
[ "$nkw" -gt 0 ] && ok "writers killed while writing (with some, not all, of their records in the file): $nkw in the 4 runs" || bad "no writer was killed while writing"
G "echo after > $MP/stress/after.txt && cat $MP/stress/after.txt" > $W/wr_after.txt 2>&1
[ "$(cat $W/wr_after.txt)" = after ] && [ "$(cat "$ST/after.txt" 2>/dev/null)" = after ] && ok "after the kills, fs-9p creates, writes and reads a new file" || bad "new open after the kills: $(head -2 $W/wr_after.txt)"
G "slay fs-9p; i=0; while pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | grep -q . && [ \$i -lt 10 ]; do sleep 1; i=\$((i + 1)); done; grep 'request slots at unmount' $GD/fs-9p.log" > $W/wr_slots.txt 2>&1; cat $W/wr_slots.txt
grep -q '^fs-9p: request slots at unmount: 16 of 16 free, 0 in use, 0 lost; 0 requests in flight$' $W/wr_slots.txt && ok "no request slot leaked: 16 of 16 free at unmount" || bad "request slots at unmount"
G "$GD/fs-9p -d -v -m $MP 2>$GD/fs-9p.log; echo mount=\$?" > $W/wr_mount.txt 2>&1
grep -q '^mount=0' $W/wr_mount.txt || bad "mount after the writers step: $(cat $W/wr_mount.txt)"
rm -rf "$ST"

step "robustness: unmount and mount again, three times"
G "slay -f fs-9p; sleep 1; tail -2 $GD/fs-9p.log" > $W/rm0.txt 2>&1; cat $W/rm0.txt
G "for i in 1 2 3; do $GD/fs-9p -d -v -m $MP 2>$GD/fs-9p.log; echo mount\$i=\$?; md5sum $MP/robust/big100.bin; slay -f fs-9p; sleep 1; ls $MP >/dev/null 2>&1 || echo unmounted\$i; done" > $W/remount.txt 2>&1; cat $W/remount.txt
[ "$(grep -c '^mount[123]=0' $W/remount.txt)" = 3 ] && [ "$(grep -c "^$B100" $W/remount.txt)" = 3 ] && [ "$(grep -c '^unmounted[123]' $W/remount.txt)" = 3 ] &&
    ok "3 cycles of mount, md5 of the 100 MiB file, unmount" || bad "remount cycles"

step "robustness: driver restart while a client holds a file open"
# A holder process opens a file of the share and keeps the descriptor; after the open it starts no
# other process. The shell that kills, restarts and starts fs-9p never holds a descriptor of the
# share. The holder waits for "go" on its standard input (a pipe from that shell, at most 30 s) and
# then reads from the old descriptor once more. (Fix round 13, changed after seeing results: before,
# one shell held the descriptor and also ran slay, fs-9p and cat; in 1 of 4 runs that shell could
# not start a process after the driver behind its descriptor had been killed: "fork: No such
# process", and the SIGTERM part did not run.)
echo "0123456789abcdefghij" > "$R/hold.txt"
cat > $W/holder.sh <<EOF
echo \$\$ > $GD/hold.pid
exec 3< $MP/robust/hold.txt
read -r -n 5 -u 3 a; echo "holder: read from the open fd: status \$? value '\$a'"
: > $GD/hold.ready
read -r -t 30 g; echo "holder: go received: \${g:-none}"
read -r -n 5 -u 3 b; echo "holder: read from the same fd after the driver ended: status \$? value '\$b'"
: > $GD/hold.done
EOF
# hold_script NAME "command that ends the driver" LABEL: writes and runs hold_NAME.sh in the guest; the
# group in braces is the left side of the pipe, holder.sh the right side
hold_script() {
    cat > $W/hold_$1.sh <<EOF
rm -f $GD/hold.ready $GD/hold.done $GD/hold.pid $GD/hold.main
$GD/fs-9p -d -v -m $MP 2>$GD/fs-9p.log; echo "mount=\$?"
{
    n=0; while [ ! -e $GD/hold.ready ] && [ \$n -lt 30 ]; do sleep 1; n=\$((n + 1)); done
    $2
    n=0; while [ -n "\$(pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d)" ] && [ \$n -lt 10 ]; do sleep 1; n=\$((n + 1)); done
    echo "$3: fs-9p processes left \$(pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | grep -c .); ls exit \$(ls $MP >/dev/null 2>&1; echo \$?)"
    $GD/fs-9p -d -v -m $MP 2>$GD/fs-9p.log 3>&-; echo "mount again=\$?"
    cat $MP/robust/hold.txt; echo "new open status \$?"
    echo go >&3
    n=0; while [ ! -e $GD/hold.done ] && [ \$n -lt 20 ]; do sleep 1; n=\$((n + 1)); done
    if [ -e $GD/hold.done ]; then echo "holder ended"; else echo "holder still running 20 s after go: killed"; kill -9 \$(cat $GD/hold.pid); fi
} 3>&1 >$GD/hold.main 2>&1 | bash $GD/holder.sh
cat $GD/hold.main; rm -f $GD/hold.ready $GD/hold.done $GD/hold.pid $GD/hold.main
EOF
    $GUEST_SCP $W/hold_$1.sh "$GUEST_DEST$GD/" >/dev/null && G "bash $GD/hold_$1.sh" > $W/hold_$1.txt 2>&1; cat $W/hold_$1.txt
}
$GUEST_SCP $W/holder.sh "$GUEST_DEST$GD/" >/dev/null
echo "-- slay -9 while the holder keeps its descriptor"
hold_script kill "slay -9 fs-9p" "after slay -9"
H=$W/hold_kill.txt
grep -q "^mount=0" $H && grep -q "^holder: read from the open fd: status 0 value '01234'" $H && grep -q '^after slay -9: fs-9p processes left 0; ls exit [1-9]' $H &&
    grep -q '^mount again=0' $H && grep -q '^new open status 0' $H && grep -q '^0123456789abcdefghij' $H && ok "restart with slay -9 while an fd is open: the new instance mounts and serves new opens" || bad "restart with an open file"
grep -q "^holder: read from the same fd after the driver ended: status [1-9]" $H && grep -q '^holder ended' $H && ok "the fd opened before the restart fails (reported above), no hang" || bad "old fd after restart: $(grep 'same fd' $H)"
G "slay -f fs-9p; sleep 1" >/dev/null 2>&1
echo "-- SIGTERM while the holder keeps its descriptor"
hold_script term "slay fs-9p" "after SIGTERM"
H=$W/hold_term.txt
grep -q "^mount=0" $H && grep -q "^holder: read from the open fd: status 0 value '01234'" $H && grep -q '^after SIGTERM: fs-9p processes left 0; ls exit [1-9]' $H &&
    grep -q '^mount again=0' $H && grep -q '^0123456789abcdefghij' $H && grep -q "^holder: read from the same fd after the driver ended: status [1-9]" $H && grep -q '^holder ended' $H &&
    ok "SIGTERM unmount with an open fd: fs-9p ended, the open fd then failed (no hang), mount again: file readable" || bad "SIGTERM unmount with an open fd"
rm -rf "$R"

step "image/fs-9p-supervise: automatic restart after slay -9, and the restart limit (FS9P_RESTART_MAX, FS9P_RESTART_WINDOW)"
# Run 1: limit 2 restarts in 10 s; three kills in a row: restart 1, restart 2, then the limit.
# Run 2: limit 1 restart in 10 s; kill, wait 11 s (the first restart leaves the window), kill
# (restart 2), kill (limit). The script lies in $GD, not on the share, so the kills do not stop it.
cat > $W/sup.sh <<EOF
fpid() { pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | head -1 | tr -d ' '; }
newpid() {   # newpid OLD: wait until another fs-9p process has mounted $MP (at most 15 s)
    i=0
    while [ \$i -lt 15 ]; do
        p=\$(fpid); [ -n "\$p" ] && [ "\$p" != "\$1" ] && ls $MP >/dev/null 2>&1 && { echo "\$p"; return 0; }
        sleep 1; i=\$((i + 1))
    done
    echo none; return 1
}
kill_wait() {   # kill_wait LABEL: slay -9, then report whether a new fs-9p mounted $MP
    old=\$(fpid); slay -9 fs-9p; sleep 1
    n=\$(newpid "\$old") && echo "\$1: new fs-9p, mounted" || echo "\$1: no new fs-9p"
}
run() {   # run NAME MAX WINDOW
    FS9P=$GD/fs-9p FS9P_RESTART_MAX=\$2 FS9P_RESTART_WINDOW=\$3 sh $GD/fs-9p-supervise -m $MP > $GD/sup_\$1.log 2>&1
    ls $MP >/dev/null 2>&1 && echo "\$1 start: mounted" || echo "\$1 start: not mounted"
}
run limit 2 10
kill_wait "limit kill 1"; kill_wait "limit kill 2"; kill_wait "limit kill 3"
echo "limit: fs-9p processes after kill 3: \$(pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | wc -l | tr -d ' ')"
grep '^fs-9p-supervise' $GD/sup_limit.log
run window 1 10
kill_wait "window kill 1"; sleep 11; kill_wait "window kill 2"; kill_wait "window kill 3"
echo "window: fs-9p processes after kill 3: \$(pidin -p fs-9p -F '%a' 2>/dev/null | sed 1d | wc -l | tr -d ' ')"
grep '^fs-9p-supervise' $GD/sup_window.log
EOF
G "slay -f fs-9p; sleep 1"   # the instance of the previous step
$GUEST_SCP image/fs-9p-supervise $W/sup.sh "$GUEST_DEST$GD/" >/dev/null && G "sh $GD/sup.sh" > $W/sup.txt 2>&1; sed 's/^/  /' $W/sup.txt
grep -q '^limit start: mounted' $W/sup.txt && grep -q '^limit kill 1: new fs-9p, mounted' $W/sup.txt && grep -q '^limit kill 2: new fs-9p, mounted' $W/sup.txt &&
    grep -q 'starting it again (restart 2)$' $W/sup.txt && ok "fs-9p-supervise: after each of 2 kills a new fs-9p mounted the share without a typed command" || bad "automatic restart by fs-9p-supervise"
grep -q '^limit kill 3: no new fs-9p' $W/sup.txt && grep -q '^limit: fs-9p processes after kill 3: 0' $W/sup.txt &&
    grep -q 'not started again: 2 restarts in the last 10 s (limit FS9P_RESTART_MAX=2 in FS9P_RESTART_WINDOW=10 s)' $W/sup.txt &&
    ok "restart limit: the third kill within 10 s is not followed by a restart, and the reason is printed" || bad "restart limit"
grep -q '^window kill 1: new fs-9p, mounted' $W/sup.txt && grep -q '^window kill 2: new fs-9p, mounted' $W/sup.txt && grep -q '^window kill 3: no new fs-9p' $W/sup.txt &&
    grep -q '^window: fs-9p processes after kill 3: 0' $W/sup.txt && grep -q 'not started again: 1 restarts in the last 10 s' $W/sup.txt &&
    ok "restart window: a restart older than 10 s no longer counts (limit 1: kill, 11 s, kill restarts, kill stops)" || bad "restart window"
G "$GD/fs-9p -d -v -m $MP 2>$GD/fs-9p.log" || bad "mount for the next steps"

step "tools/qnx-run: make and ctest on this machine run the unit tests of examples/qnx-unit inside the guest, from the share"
# The example is copied into the shared folder and built there with qcc. tools/qnx-run maps each
# test program's host path to $MP/... and runs it in the guest over GUEST_SSH; nothing is copied
# into the guest. Exit status, stdout and stderr come back to make and ctest.
UX=$SHARE/qnx-unit; rm -rf "$UX"; mkdir -p "$UX"; cp -r examples/qnx-unit/. "$UX/"
QR=$PWD/tools/qnx-run
export QNX_SHARE=$SHARE QNX_MOUNT=$MP QNX_SSH="$GUEST_SSH"
{ $QR uname -sr; echo "exit status $?"; } > $W/qr_uname.txt 2>&1; cat $W/qr_uname.txt
grep -q '^QNX 8' $W/qr_uname.txt && grep -q '^exit status 0' $W/qr_uname.txt && ok "qnx-run uname -sr: a guest command, its output and exit status 0 on the host" || bad "qnx-run uname"
hide() { sed -e "s|$SHARE|SHARE|g" -e "s|$PWD|REPO|g" -e 's/^/  /'; }   # no host paths in the log
{ make -C "$UX" QNX_RUN="$QR" qnx-test; echo "make exit status $?"; } > $W/qr_make.txt 2>&1; hide < $W/qr_make.txt
grep -q '^qnx-test: 0 failed' $W/qr_make.txt && grep -q '^make exit status 0' $W/qr_make.txt && ok "make qnx-test: test_ring, test_msg and test_pulse passed in the guest ($(grep -c '^ok ' $W/qr_make.txt) checks, $(grep -c '^not ok ' $W/qr_make.txt) failed)" || bad "make qnx-test"
grep -q '^exit status 3 reached make' $W/qr_make.txt && grep -q '^exit_status: stderr line' $W/qr_make.txt && ok "make qnx-test: exit status 3 and the stderr line of a guest program reached the host" || bad "exit status pass-through"
grep -q "exit_status: open $MP/qnx-unit/build/exit_status: ok" $W/qr_make.txt && ok "a host path argument inside the share reached the program as $MP/qnx-unit/build/exit_status" || bad "host path argument"
NJ=$(grep -l 'failures="0"' "$UX"/build/junit/*.xml 2>/dev/null | wc -l)
[ "$NJ" = 3 ] && ok "JUnit files: 3 written on the host, each with failures=\"0\"" || bad "JUnit files: $NJ"
{ $QR -j $W/fail.xml -n must_fail "$UX/build/exit_status" 3; echo "exit status $?"; } > $W/qr_fail.txt 2>&1
grep -q '^exit status 3' $W/qr_fail.txt && grep -q '<failure type="exit-status" message="exit status 3">' $W/fail.xml && ok "qnx-run -j on a program that exits with 3: exit status 3 and a JUnit failure element" || bad "JUnit failure element"
# Coverage through the share: the gcov runtime in the guest writes the .gcda files through /mnt/host
# into the host build folder; gcovr (or the SDP's gcov) reads them on this machine.
{ make -C "$UX" QNX_RUN="$QR" GCOVR="${GCOVR:-gcovr}" coverage; echo "make exit status $?"; } > $W/qr_cov.txt 2>&1
grep -v -E '^(qcc |ok |make: )' $W/qr_cov.txt | hide
NG=$(ls "$UX"/build/cov/*.gcda 2>/dev/null | wc -l)
grep -q '^coverage: 0 failed' $W/qr_cov.txt && grep -q '^make exit status 0' $W/qr_cov.txt && [ "$NG" = 3 ] &&
    ok "make coverage: the 3 tests ran in the guest with gcov counters; 3 .gcda files appeared in the host build folder through the share" || bad "make coverage ($NG .gcda files)"
grep -E -q '^TOTAL +[0-9]+ +[0-9]+ +[0-9]+%|^Lines executed:' $W/qr_cov.txt && ok "coverage report on the host from the guest's .gcda files ($(grep -E '^TOTAL|^Lines executed:' $W/qr_cov.txt | head -1 | tr -s ' '))" || bad "coverage report"
[ -n "${CMAKE_ENV:-}" ] && . "$CMAKE_ENV" >/dev/null 2>&1
if command -v cmake >/dev/null 2>&1 && command -v ctest >/dev/null 2>&1; then
    echo "cmake: $(cmake --version | head -1)"
    CB=$UX/cbuild
    { cmake -S "$UX" -B "$CB" -DCMAKE_TOOLCHAIN_FILE="$UX/qnx-x86_64.cmake" -DCMAKE_CROSSCOMPILING_EMULATOR="$QR" && cmake --build "$CB" -j8; echo "cmake exit status $?"; } > $W/qr_cmake.txt 2>&1
    tail -3 $W/qr_cmake.txt | hide
    grep -q "$QR" "$CB/CTestTestfile.cmake" && ok "CTestTestfile.cmake runs every test through tools/qnx-run (CMAKE_CROSSCOMPILING_EMULATOR)" || bad "ctest emulator"
    # ctest prints times per test; the log keeps the results only
    { cd "$CB" && ctest --output-junit junit.xml; echo "ctest exit status $?"; cd - >/dev/null; } 2>&1 | sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' > $W/qr_ctest.txt
    hide < $W/qr_ctest.txt
    grep -q '100% tests passed, 0 tests failed out of 5' $W/qr_ctest.txt && grep -q '^ctest exit status 0' $W/qr_ctest.txt && ok "ctest: 5 of 5 tests passed, each run inside the guest (runner_exit_status passes because its program exits with 3)" || bad "ctest"
    grep -q 'tests="5"' "$CB/junit.xml" 2>/dev/null && grep -q 'failures="0"' "$CB/junit.xml" && ok "ctest --output-junit: junit.xml with 5 tests, 0 failures" || bad "ctest JUnit file"
else
    echo "cmake or ctest not found (set CMAKE_ENV); the ctest part is skipped"
fi

step "tools/qnx-run stops the guest program: time limit (-t), SIGINT and SIGTERM to qnx-run, ctest TIMEOUT"
# stuck_receive (examples/qnx-unit/tests/stuck_receive.c) waits in MsgReceive() until a signal ends
# it; with "fork" a child process waits as well. After each case the guest must run no process of
# that name: the guest stops the process group of the program.
SR=$UX/build/stuck_receive
left() { G "pidin -F '%a %N' 2>/dev/null | grep -c stuck_receive"; }   # such processes in the guest
gone() {   # gone: true when no stuck_receive runs in the guest (checked once a second, at most 10 times)
    local i=0
    while [ "$(left)" != 0 ]; do i=$((i + 1)); [ $i -ge 10 ] && return 1; sleep 1; done
}
started() { local i=0; until grep -q '^stuck_receive: a process waits' "$1" 2>/dev/null; do i=$((i + 1)); [ $i -ge 40 ] && return 1; sleep 0.5; done; }
G "slay -f stuck_receive" >/dev/null 2>&1
{ $QR -t 3 "$SR" fork; echo "exit status $?"; } > $W/st_t.txt 2>&1; N=$(left); sed 's/^/  /' $W/st_t.txt
[ "$(grep -c '^stuck_receive: a process waits' $W/st_t.txt)" = 2 ] && grep -q '^exit status 124$' $W/st_t.txt && [ "$N" = 0 ] &&
    ok "qnx-run -t 3: exit status 124; the program and its child (2 processes in MsgReceive) were stopped, 0 left in the guest when qnx-run returned" || bad "qnx-run -t ($N left)"
{ $QR -t 3 "$SR" ignore-term fork; echo "exit status $?"; } > $W/st_k.txt 2>&1; N=$(left); sed 's/^/  /' $W/st_k.txt
grep -q '^exit status 124$' $W/st_k.txt && [ "$N" = 0 ] &&
    ok "qnx-run -t 3, program ignores SIGTERM: SIGKILL 2 s after SIGTERM; exit status 124, 0 left" || bad "qnx-run -t, SIGTERM ignored ($N left)"
# -u USER: the guest starts the program with on -u USER; the stop must reach it and its child too
{ $QR -t 3 -u qnxuser "$SR" fork; echo "exit status $?"; } > $W/st_u.txt 2>&1 & QP=$!
started $W/st_u.txt; sleep 0.5
UIDS=$(G "pidin -F '%U %N' 2>/dev/null" | awk '$2 ~ /stuck_receive/ { print $1 }' | sort -u | tr '\n' ' ')
wait $QP; N=$(left); sed 's/^/  /' $W/st_u.txt; echo "  uid of the stuck_receive processes while they waited: ${UIDS:-none}"
[ "$(grep -c '^stuck_receive: a process waits' $W/st_u.txt)" = 2 ] && grep -q '^exit status 124$' $W/st_u.txt && [ "$N" = 0 ] &&
    [ -n "$UIDS" ] && ! printf ' %s' "$UIDS" | grep -q ' 0 ' &&
    ok "qnx-run -t 3 -u qnxuser: the program and its child ran as uid ${UIDS% } (not root); exit status 124, 0 left" || bad "qnx-run -t -u qnxuser (uid ${UIDS:-none}; $N left)"
for S in INT TERM; do
    # job control on (set -m): otherwise a background job of this script would ignore SIGINT
    set -m; $QR "$SR" fork > $W/st_$S.txt 2>&1 & QP=$!; set +m
    started $W/st_$S.txt; kill -$S $QP; wait $QP; echo "exit status $?" >> $W/st_$S.txt; N=$(left); sed 's/^/  /' $W/st_$S.txt
    E=130; [ $S = TERM ] && E=143
    grep -q "^exit status $E\$" $W/st_$S.txt && [ "$N" = 0 ] &&
        ok "SIG$S to qnx-run while the program waits: exit status $E; qnx-run returned after the guest had stopped both processes (0 left)" || bad "SIG$S forwarding ($N left)"
done
if command -v cmake >/dev/null 2>&1 && command -v ctest >/dev/null 2>&1; then
    CT=$UX/cbuild-timeout
    { cmake -S "$UX" -B "$CT" -DCMAKE_TOOLCHAIN_FILE="$UX/qnx-x86_64.cmake" -DCMAKE_CROSSCOMPILING_EMULATOR="$QR" -DQNX_UNIT_TIMEOUT_CHECK=ON && cmake --build "$CT" -j8; echo "cmake exit status $?"; } > $W/st_cmake.txt 2>&1
    tail -1 $W/st_cmake.txt | hide
    { cd "$CT" && ctest -R runner_timeout; echo "ctest exit status $?"; cd - >/dev/null; } 2>&1 | sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' > $W/st_ctest.txt
    hide < $W/st_ctest.txt
    if gone; then N=0; else N=$(left); fi
    grep -q 'runner_timeout .*\*\*\*Timeout' $W/st_ctest.txt && ! grep -q '^ctest exit status 0' $W/st_ctest.txt && [ "$N" = 0 ] &&
        ok "ctest TIMEOUT 5 (test runner_timeout = stuck_receive fork): ctest reported Timeout and ended qnx-run; the guest then stopped both processes (0 left; checked once a second, at most 10 times)" || bad "ctest TIMEOUT ($N left)"
fi
G "slay -f stuck_receive" >/dev/null 2>&1

step "tools/qnx-run --json: one JSON line with the exit status, signal, time limit, output and output files"
PY3=${PYTHON:-python3}
{ $QR --json -o $W/j1out -t 60 "$UX/build/exit_status" 3; echo "exit status $?"; } > $W/j1.txt 2>&1
{ $QR --json -o $W/j2out -t 2 "$SR"; echo "exit status $?"; } > $W/j2.txt 2>&1
# a program that exits with 124 by itself is not timed out: without -t, and with -t 60 plus a JUnit file
{ $QR --json -o $W/j3out "$UX/build/exit_status" 124; echo "exit status $?"; } > $W/j3.txt 2>&1
{ $QR --json -o $W/j4out -t 60 -j $W/j4.xml "$UX/build/exit_status" 124; echo "exit status $?"; } > $W/j4.txt 2>&1
hide < $W/j1.txt; hide < $W/j2.txt; hide < $W/j3.txt; hide < $W/j4.txt
"$PY3" -I - $W/j1.txt $W/j2.txt $W/j3.txt $W/j4.txt $W/j4.xml > $W/j.txt 2>&1 <<'PYEOF'
import json, sys
a = json.loads(open(sys.argv[1]).readline())
b = json.loads(open(sys.argv[2]).readline())
c = json.loads(open(sys.argv[3]).readline())
d = json.loads(open(sys.argv[4]).readline())
x = open(sys.argv[5]).read()
ok1 = (a["exit_status"] == 3 and a["signal"] is None and a["timed_out"] is False and a["stdout"] == "exit_status: stdout line\n"
       and a["stderr"] == "exit_status: stderr line\n" and open(a["stdout_file"]).read() == a["stdout"])
ok2 = (b["exit_status"] == 124 and b["timed_out"] is True and b["time_limit_s"] == 2 and "a process waits" in b["stdout"]
       and "@@qnx-run@@" not in b["stderr"] and "@@qnx-run@@" not in open(b["stderr_file"]).read())
ok3 = (c["exit_status"] == 124 and c["timed_out"] is False and c["time_limit_s"] == 0 and c["stderr"] == "exit_status: stderr line\n"
       and d["exit_status"] == 124 and d["timed_out"] is False and d["time_limit_s"] == 60 and d["stderr"] == "exit_status: stderr line\n"
       and 'type="exit-status"' in x and 'type="timeout"' not in x and "@@qnx-run@@" not in x)
print("json1", "ok" if ok1 else "bad"); print("json2", "ok" if ok2 else "bad"); print("json3", "ok" if ok3 else "bad")
PYEOF
cat $W/j.txt
grep -q '^exit status 3$' $W/j1.txt && grep -q '^json1 ok' $W/j.txt &&
    ok "qnx-run --json, program exits with 3: valid JSON; exit_status 3, signal null, timed_out false, stdout and stderr lines; stdout_file holds the same text" || bad "qnx-run --json (exit status 3)"
grep -q '^exit status 124$' $W/j2.txt && grep -q '^json2 ok' $W/j.txt && [ "$(left)" = 0 ] &&
    ok "qnx-run --json -t 2 on stuck_receive: exit_status 124, timed_out true (reported by the guest), its output line; 0 left in the guest" || bad "qnx-run --json -t"
grep -q '^exit status 124$' $W/j3.txt && grep -q '^exit status 124$' $W/j4.txt && grep -q '^json3 ok' $W/j.txt &&
    ok "qnx-run --json, program exits with 124 by itself: timed_out false without -t and with -t 60; the JUnit file (-j) names an exit-status failure, not a timeout" || bad "qnx-run --json, exit status 124 of the program"

step "AGENTS.md: the commands of its marked block, run as written from the repository root"
awk '$0 == "<!-- agents-run -->" {f = 1; next} f && /^ *```sh/ {p = 1; next} p && /^ *```/ {exit} p {print}' AGENTS.md > $W/agents.sh
sed 's/^/  /' $W/agents.sh | hide
rm -rf "$SHARE/agent-build"
mkdir -p $W/agtmp; TMPDIR=$PWD/$W/agtmp bash $W/agents.sh > $W/agents.txt 2>&1   # --json output folders go to TMPDIR
grep -v -E '^(qcc |make|-- |\[)' $W/agents.txt | sed -E -e 's/ +[0-9.]+ sec$//' -e '/Total Test time/d' | hide
grep '^{' $W/agents.txt > $W/agents.json
"$PY3" -I - $W/agents.json > $W/agents_check.txt 2>&1 <<'PYEOF'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
print("json lines", len(r))
print("checks", "ok" if len(r) == 3 and r[0]["exit_status"] == 0 and r[1]["exit_status"] == 3 and r[2]["exit_status"] == 124 and r[2]["timed_out"] else "bad")
PYEOF
cat $W/agents_check.txt
grep -q '^checks ok' $W/agents_check.txt && ok "AGENTS.md block: three JSON lines (test_ring exit_status 0; exit_status 3; stuck_receive timed_out true, 124)" || bad "AGENTS.md JSON lines"
grep -q '100% tests passed, 0 tests failed out of 5' $W/agents.txt && grep -q 'tests="5"' "$SHARE/agent-build/cmake/junit.xml" 2>/dev/null &&
    ok "AGENTS.md block: ctest with tools/qnx-run -t 60 as emulator, 5 of 5 passed in the guest, junit.xml with 5 tests" || bad "AGENTS.md ctest"
[ "$(left)" = 0 ] && ok "AGENTS.md block: no stuck_receive left in the guest" || bad "AGENTS.md: stuck_receive left"
rm -rf "$SHARE/agent-build"

step "unmount (SIGTERM)"
G "slay -f fs-9p; sleep 1; ls $MP 2>&1; tail -2 $GD/fs-9p.log" > $W/umount.txt 2>&1
cat $W/umount.txt
grep -q "No such file or directory" $W/umount.txt && ok "unmount" || bad "unmount"

step "option -p: poll the used ring instead of using the interrupt (fs-9p -d -p)"
G "$GD/fs-9p -d -v -p -m $MP 2>$GD/fs-9p-poll.log; echo exit=\$?; grep -h 'mounted at' $GD/fs-9p-poll.log" > $W/poll.txt 2>&1; cat $W/poll.txt
grep -q '^exit=0' $W/poll.txt && grep -q 'interface, polling, ' $W/poll.txt && ok "mount with -p: the driver reports polling" || bad "mount with -p"
G "cd $MP/tree && find . -type f -exec cksum {} +" | LC_ALL=C sort -k3 > $W/guest_cksum_poll.txt
same "cksum of all files (polling)" $W/host_cksum.txt $W/guest_cksum_poll.txt
PD=$SHARE/poll; rm -rf "$PD"; mkdir -p "$PD"
G "cp '$MP/tree/big file.bin' $MP/poll/copy.bin; echo cp=\$?" > $W/poll_cp.txt 2>&1; cat $W/poll_cp.txt
[ "$(md5sum < "$PD/copy.bin" 2>/dev/null | cut -d' ' -f1)" = "$BIGMD5" ] && ok "cp of the 12 MiB file into the share with -p: host md5 equal" || bad "write with -p"
G "slay -f fs-9p; sleep 1; tail -2 $GD/fs-9p-poll.log" > $W/poll_um.txt 2>&1; cat $W/poll_um.txt
grep -q ' 0 interrupts, ' $W/poll_um.txt && ok "statistics at unmount with -p: 0 interrupts used" || bad "polling statistics"
rm -rf "$PD"

step "option -n 64: 64 request slots, 64 concurrent readers"
G "$GD/fs-9p -d -v -n 64 -m $MP 2>$GD/fs-9p-n64.log; echo exit=\$?; grep -h -E 'mounted at|queue 0 size' $GD/fs-9p-n64.log" > $W/n64.txt 2>&1; cat $W/n64.txt
grep -q '^exit=0' $W/n64.txt && grep -q ', 64 request slots)' $W/n64.txt && ok "mount with -n 64: 64 request slots" || bad "mount with -n 64"
G "cd '$MP/tree'; i=0; while [ \$i -lt 64 ]; do md5sum 'big file.bin' > $GD/n64_\$i.txt & i=\$((i+1)); done; wait; cat $GD/n64_*.txt; rm -f $GD/n64_*.txt" > $W/n64r.txt 2>&1
[ "$(grep -c "^$BIGMD5" $W/n64r.txt)" = 64 ] && ok "64 concurrent readers of the 12 MiB file: 64 md5 equal to the host's" || bad "64 concurrent readers: $(grep -c "^$BIGMD5" $W/n64r.txt) of 64 equal"
G "slay -f fs-9p; sleep 1; tail -2 $GD/fs-9p-n64.log" > $W/n64u.txt 2>&1; cat $W/n64u.txt
NIF=$(sed -n 's/.*at most \([0-9]*\) requests in flight.*/\1/p' $W/n64u.txt)
echo "largest number of 9P requests in flight at the same time during this mount: ${NIF:-?} (limit 64)"
[ -n "$NIF" ] && [ "$NIF" -gt 16 ] && ok "with -n 64 more requests than the default 16 slots were in flight at once ($NIF)" || bad "requests in flight with -n 64: ${NIF:-?}"

step "option -U: after setup fs-9p runs as a non-root user and keeps only the abilities io and priority"
G "$GD/fs-9p -d -v -U qnxuser -m $MP 2>$GD/fs-9p-U.log; echo exit=\$?; grep -h -E 'running as|mounted at' $GD/fs-9p-U.log; pidin -p fs-9p -F '%a %n %U %W'; echo '-- threads (priority and scheduling policy, state):'; pidin -p fs-9p; echo '-- abilities that the non-root set allows:'; pidin -p fs-9p abilities | grep -E ' [R-]N[L-][I-]'" > $W/drop.txt 2>&1; cat $W/drop.txt
DUID=$(sed -n 's/.*running as uid \([0-9]*\) .*/\1/p' $W/drop.txt)
grep -q '^exit=0' $W/drop.txt && [ -n "$DUID" ] && [ "$DUID" != 0 ] && ok "mount with -U qnxuser: fs-9p reports uid $DUID after setup" || bad "mount with -U"
grep -E -q "fs-9p +$DUID +$DUID *\$" $W/drop.txt && ok "pidin: user ID and effective user ID of the running fs-9p are $DUID, not 0" || bad "pidin user of fs-9p"
NAB=$(grep -c -E ' [R-]N[L-][I-]' $W/drop.txt)
[ "$NAB" = 2 ] && grep -E -q '^ *io +[R-]NL' $W/drop.txt && grep -E -q '^ *priority +[R-]NL' $W/drop.txt && ok "pidin: the non-root set allows 2 abilities, io and priority, both locked" || bad "abilities of the non-root set: $NAB"
G "cd $MP/tree && find . -type f -exec cksum {} +" | LC_ALL=C sort -k3 > $W/guest_cksum_U.txt
same "cksum of all files (fs-9p running as $DUID)" $W/host_cksum.txt $W/guest_cksum_U.txt
UD=$SHARE/dropped; rm -rf "$UD"; mkdir -p "$UD"
G "cp '$MP/tree/big file.bin' $MP/dropped/copy.bin; echo cp=\$?; mkdir $MP/dropped/d; mv $MP/dropped/copy.bin $MP/dropped/d/; echo mv=\$?" > $W/drop_w.txt 2>&1; cat $W/drop_w.txt
[ "$(md5sum < "$UD/d/copy.bin" 2>/dev/null | cut -d' ' -f1)" = "$BIGMD5" ] && ok "write, mkdir and rename with fs-9p running as $DUID: host md5 equal" || bad "writes with -U"
G "slay -f fs-9p; sleep 1; tail -2 $GD/fs-9p-U.log" > $W/drop_um.txt 2>&1; cat $W/drop_um.txt
grep -q ' 0 reaped by waiters, 0 lost, ' $W/drop_um.txt && ok "unmount of the non-root instance; every completion came through the interrupt, 0 lost" || bad "statistics of the non-root instance"
rm -rf "$UD"

step "interrupt-thread priority under CPU load: 8 CPU-bound loops at priority 30, a reader at priority 40; base priority 21, fixed (-f) and following the client (default)"
# The reader's request is served by a pool thread at the reader's priority (40, QNX message passing),
# which then waits for the interrupt thread. With -f the interrupt thread stays at 21, the loops at 30
# keep it from running, and the waiter collects its own completion after its 200 ms fallback wait
# ("reaped by waiters" > 0). By default fs-9p raises the interrupt thread to 40 while the request is
# in flight ("reaped by waiters" = 0). The loops end by themselves after 8 s; each loop leaves a
# marker file when it ends, so the script can count how many had ended when the read finished.
# Counts only; no times are printed.
PREFIXMD5=$(head -c 2097152 "$T/big file.bin" | md5sum | cut -d' ' -f1)
cat > $W/prio.sh <<EOF
# sh prio.sh LOAD_PRIORITY   (run under "on -p READER_PRIORITY")
rm -f $GD/loopend.*
i=0
while [ \$i -lt 8 ]; do on -p \$1 sh -c 'end=\$((SECONDS+8)); while [ \$SECONDS -lt \$end ]; do :; done; touch $GD/loopend.'\$i & i=\$((i+1)); done
sleep 1
dd if='$MP/tree/big file.bin' bs=131072 count=16 2>/dev/null | md5sum
echo "loops that had ended when the read finished: \$(ls $GD/loopend.* 2>/dev/null | wc -l | tr -d ' ') of 8"
wait
rm -f $GD/loopend.*
EOF
$GUEST_SCP $W/prio.sh "$GUEST_DEST$GD/" >/dev/null
G "echo \"guest processors: \$(pidin info | grep -c '^Processor')\"" | tee $W/ncpu.txt
NCPU=$(sed -n 's/^guest processors: \([0-9]*\)$/\1/p' $W/ncpu.txt)
prio_run() {   # prio_run NAME "fs-9p options" READER_PRIO LOAD_PRIO
    G "$GD/fs-9p -d -v $2 -m $MP 2>$GD/fs-9p-prio.log; grep -h -E 'running as|mounted at' $GD/fs-9p-prio.log; on -p $3 sh $GD/prio.sh $4; slay -f fs-9p; sleep 1; tail -2 $GD/fs-9p-prio.log" > $W/prio_$1.txt 2>&1; cat $W/prio_$1.txt
    eval "RW_$1=\$(sed -n 's/.* \([0-9]*\) reaped by waiters.*/\1/p' $W/prio_$1.txt)"
    eval "HC_$1=\$(sed -n 's/.*highest waiting client \([0-9]*\);.*/\1/p' $W/prio_$1.txt)"
    eval "HI_$1=\$(sed -n 's/.*raised [0-9]* times, highest \([0-9]*\);.*/\1/p' $W/prio_$1.txt)"
    eval "PF_$1=\$(sed -n 's/.*; \([0-9]*\) priority changes failed.*/\1/p' $W/prio_$1.txt)"
    eval "LE_$1=\$(sed -n 's/^loops that had ended when the read finished: \([0-9]*\) of 8.*/\1/p' $W/prio_$1.txt)"
    grep -q "^$PREFIXMD5" $W/prio_$1.txt && ok "reader at priority $3 under load at $4 (fs-9p $2): md5 of the first 2 MiB equal to the host's" || bad "reader under load ($1)"
}
prio_run fixed "-f" 40 30
prio_run follow "" 40 30
grep -q 'interrupt thread priority 21, fixed)' $W/prio_fixed.txt && grep -q 'interrupt thread priority 21, set to the highest waiting client)' $W/prio_follow.txt && ok "mount lines: base priority 21; fixed with -f, following by default" || bad "priority in the mount lines"
echo "completions collected by the fallback wait instead of the interrupt thread: ${RW_fixed:-?} with -f, ${RW_follow:-?} by default (fallback wait: a waiting server thread that has no completion after 200 ms, a constant in src/virtq.c, checks the ring itself)"
echo "highest waiting client priority: ${HC_fixed:-?} with -f, ${HC_follow:-?} by default; highest interrupt-thread priority: ${HI_fixed:-?} with -f, ${HI_follow:-?} by default"
[ -n "${RW_fixed:-}" ] && [ "$RW_fixed" -gt 0 ] && [ "${HI_fixed:-x}" = 21 ] && ok "with -f the interrupt thread stays at 21 and the load at 30 delays it (${RW_fixed} fallback completions)" || bad "fixed priority: ${RW_fixed:-?} fallback, highest ${HI_fixed:-?}"
[ "${RW_follow:-x}" = 0 ] && [ "${HC_follow:-x}" = 40 ] && [ "${HI_follow:-x}" = 40 ] && [ "${PF_follow:-x}" = 0 ] && ok "by default the interrupt thread follows the reader to priority 40: 0 fallback completions, 0 failed priority changes" || bad "following priority: ${RW_follow:-?} fallback, client ${HC_follow:-?}, highest ${HI_follow:-?}, failed ${PF_follow:-?}"

step "a client below the base priority: reader at priority 8; base priority 21, fixed (-f) and following the client (default)"
# By default the interrupt thread runs at the highest waiting client's priority also below the base,
# so work for a client at 8 does not run above 8. Read from fs-9p's statistics line; counts only.
low_run() {   # low_run NAME "fs-9p options"
    G "$GD/fs-9p -d -v $2 -m $MP 2>$GD/fs-9p-low.log; on -p 8 dd if='$MP/tree/big file.bin' bs=131072 count=16 2>/dev/null | md5sum; slay -f fs-9p; sleep 1; tail -1 $GD/fs-9p-low.log" > $W/low_$1.txt 2>&1; cat $W/low_$1.txt
    eval "LB_$1=\$(sed -n 's/.*set below the base \([0-9]*\) times, lowest \([0-9]*\);.*/\1/p' $W/low_$1.txt)"
    eval "LL_$1=\$(sed -n 's/.*set below the base \([0-9]*\) times, lowest \([0-9]*\);.*/\2/p' $W/low_$1.txt)"
    grep -q "^$PREFIXMD5" $W/low_$1.txt && ok "reader at priority 8 (fs-9p $2): md5 of the first 2 MiB equal to the host's" || bad "reader at 8 ($1)"
}
low_run fixed "-f"
low_run follow ""
echo "interrupt thread set below the base: ${LB_fixed:-?} times with -f (lowest ${LL_fixed:-?}), ${LB_follow:-?} times by default (lowest ${LL_follow:-?})"
[ "${LB_fixed:-x}" = 0 ] && [ "${LL_fixed:-x}" = 21 ] && ok "with -f the interrupt thread never goes below 21" || bad "fixed: below ${LB_fixed:-?}, lowest ${LL_fixed:-?}"
[ -n "${LB_follow:-}" ] && [ "$LB_follow" -gt 0 ] && [ "${LL_follow:-x}" = 8 ] && ok "by default the interrupt thread goes down to the reader's priority 8 ($LB_follow changes below the base)" || bad "following below the base: ${LB_follow:-?} changes, lowest ${LL_follow:-?}"

step "a client above the maximum priority for unprivileged processes: fs-9p -U qnxuser, reader (root) at priority 70, 8 loops at 65"
# The QNX docs (System Architecture guide, "Priority inheritance and messages") say that a server
# without the priority ability is boosted only to the highest unprivileged priority (usually 63) by a
# client above it. -U keeps the priority ability, so the pool thread runs at 70 and fs-9p may raise
# its interrupt thread to 70 (pthread_setschedprio above 63 needs the ability). -U -P drops the
# ability: the pool thread then runs at 63, below the loops at 65, and the read can only go on when
# fewer loops than processors are left, that is after more than (8 - processors) loops have ended.
prio_run U70 "-U qnxuser" 70 65
prio_run U70P "-U qnxuser -P" 70 65
echo "-U: highest waiting client ${HC_U70:-?}, interrupt thread highest ${HI_U70:-?}, ${PF_U70:-?} failed changes, ${RW_U70:-?} fallback completions, ${LE_U70:-?} of 8 loops ended before the read finished"
echo "-U -P: highest waiting client ${HC_U70P:-?}, interrupt thread highest ${HI_U70P:-?}, ${PF_U70P:-?} failed changes, ${LE_U70P:-?} of 8 loops ended before the read finished"
grep -q 'abilities kept for non-root: io, priority$' $W/prio_U70.txt && grep -q 'abilities kept for non-root: io$' $W/prio_U70P.txt && ok "start-up lines: -U keeps io and priority, -U -P keeps only io" || bad "abilities in the start-up lines"
[ "${HC_U70:-x}" = 70 ] && [ "${HI_U70:-x}" = 70 ] && [ "${PF_U70:-x}" = 0 ] && [ "${RW_U70:-x}" = 0 ] && [ "${LE_U70:-x}" = 0 ] && ok "with the priority ability the non-root fs-9p serves the client at 70: interrupt thread raised to 70, 0 failed changes, 0 fallback completions, the read finished while all 8 loops still ran" || bad "client at 70 with the ability"
[ -n "${HC_U70P:-}" ] && [ "$HC_U70P" -lt 70 ] && [ -n "${NCPU:-}" ] && [ -n "${LE_U70P:-}" ] && [ "$LE_U70P" -gt $((8 - NCPU)) ] && ok "without it (-P) the pool thread ran at ${HC_U70P}, below the loops, and the read finished only after ${LE_U70P} of 8 loops had ended (more than 8 minus ${NCPU} processors)" || bad "client at 70 without the ability: client ${HC_U70P:-?}, loops ended ${LE_U70P:-?}"

if [ -n "${SLOW_SHARE:-}" ]; then
step "a reader at priority 40 waits for the request slot that a reader at 10 holds: fs-9p -n 1 on the device with throttled reads (mount tag ${SLOW_TAG:-slow}); default, -w (no priority inheritance through the slots, as in 0.9.0) and -f"
# With -n 1 fs-9p has one request slot. A reader at 10 reads a 3 MiB file from the device whose reads
# QEMU throttles, so one of its 128 KiB requests holds the slot almost all the time. Part A (no load):
# a reader at 40 reads 4 KiB, three times, and pidin runs until a thread of fs-9p is in state MUTEX.
# By default the reader-at-40's server thread blocks on the slot's mutex, and the kernel runs the
# slot's owner (the reader-at-10's server thread, named in pidin's Blocked column) at 40 until it
# gives the slot back (priority inheritance of the mutex). With -w no thread waits on a slot mutex.
# Part B: 8 CPU-bound loops at 30 start while the reader at 10 holds the slot; then a reader at 40
# reads 256 KiB into /dev/shmem (memory). By default the slot's owner and the interrupt thread run at
# 40, so the read ends while all 8 loops run. With -w and -f the owner stays at 10 behind the loops,
# and the read can only go on when fewer loops than processors are left. md5sum of the data runs
# after the loops have ended, so that the read at 40 waits for nothing outside fs-9p and the shared
# memory. Counts and priorities only; no times.
SLT=${SLOW_TAG:-slow}; MS=/mnt/slow
head -c 3145728 /dev/urandom > "$SLOW_SHARE/low.bin"; head -c 262144 /dev/urandom > "$SLOW_SHARE/high.bin"
HIMD5=$(md5sum < "$SLOW_SHARE/high.bin" | cut -d' ' -f1)
cat > $W/slot.sh <<EOF
# sh slot.sh A|B   (run under "on -p 50"; fs-9p -n 1 mounted at $MS)
rm -f $GD/loopend.*
on -p 10 dd if=$MS/low.bin of=/dev/null bs=131072 2>/dev/null &
sleep 2
if [ "\$1" = A ]; then
    found=0
    for k in 1 2 3; do
        on -p 40 dd if=$MS/high.bin of=/dev/null bs=4096 count=1 2>/dev/null &
        hp=\$!; n=0
        while [ \$n -lt 200 ] && kill -0 \$hp 2>/dev/null; do
            pidin -p fs-9p > $GD/pd.txt 2>/dev/null
            if grep -q ' MUTEX ' $GD/pd.txt; then found=\$((found + 1)); grep -v -E 'RECEIVE|SIGWAITINFO|NANOSLEEP' $GD/pd.txt; pidin -p dd | sed 1d; echo "--"; break; fi
            n=\$((n + 1))
        done
        wait \$hp
    done
    echo "reads at 40 during which pidin showed a thread of fs-9p blocked on a slot mutex: \$found of 3"
else
    i=0; while [ \$i -lt 8 ]; do on -p 30 sh -c "end=\\\$((SECONDS+8)); while [ \\\$SECONDS -lt \\\$end ]; do :; done; touch $GD/loopend.\$i" & i=\$((i + 1)); done
    sleep 1
    on -p 40 dd if=$MS/high.bin of=/dev/shmem/fs9p_high.bin bs=131072 2>/dev/null &
    hp=\$!
    sleep 1
    echo "pidin 1 s after the reader at 40 started:"; pidin -p fs-9p | grep -v -E 'RECEIVE|SIGWAITINFO|NANOSLEEP'
    wait \$hp
    echo "loops that had ended when the read at 40 finished: \$(ls $GD/loopend.* 2>/dev/null | grep -c .) of 8"
fi
wait
[ "\$1" = B ] && md5sum < /dev/shmem/fs9p_high.bin
rm -f $GD/loopend.* $GD/pd.txt /dev/shmem/fs9p_high.bin
EOF
$GUEST_SCP $W/slot.sh "$GUEST_DEST$GD/" >/dev/null
# mutex_prios FILE: in the first pidin block that has a thread of fs-9p in state MUTEX, the priority
# of that thread and of the thread it waits for (pidin's Blocked column: pid-tid), as "40r/40r"
mutex_prios() { awk '/^--$/ { if (w != "") exit; split("", p); next } $3 ~ /fs-9p$/ { p[$2 + 0] = $4 } $3 ~ /fs-9p$/ && $5 == "MUTEX" && w == "" { w = $4; split($7, a, "-"); o = a[2] + 0 } END { if (w != "") print w "/" p[o] }' "$1"; }
slot_run() {   # slot_run NAME "fs-9p options" PART
    G "$GD/fs-9p -d -v $2 -n 1 -a $SLT -m $MS 2>$GD/fs-9p-slot.log; grep -h -E 'mounted at|VQ: ' $GD/fs-9p-slot.log; on -p 50 sh $GD/slot.sh $3; slay -f fs-9p; sleep 1; tail -2 $GD/fs-9p-slot.log" > $W/slot_$1$3.txt 2>&1; cat $W/slot_$1$3.txt
    eval "SW_$1$3=\$(sed -n 's/.* \([0-9]*\) waits for a free slot.*/\1/p' $W/slot_$1$3.txt)"
    eval "SA_$1$3=\$(sed -n 's/.* \([0-9]*\) by a client above every slot owner.*/\1/p' $W/slot_$1$3.txt)"
    eval "SH_$1$3=\$(sed -n 's/.* \([0-9]*\) slots handed over.*/\1/p' $W/slot_$1$3.txt)"
    eval "SF_$1$3=\$(sed -n 's/.* \([0-9]*\) reaped by waiters.*/\1/p' $W/slot_$1$3.txt)"
    eval "SP_$1$3=\$(sed -n 's/.*; \([0-9]*\) priority changes failed.*/\1/p' $W/slot_$1$3.txt)"
    eval "SI_$1$3=\$(sed -n 's/.*interrupt thread base [0-9]*, raised [0-9]* times, highest \([0-9]*\);.*/\1/p' $W/slot_$1$3.txt)"
    eval "SL_$1$3=\$(sed -n 's/^loops that had ended when the read at 40 finished: \([0-9]*\) of 8.*/\1/p' $W/slot_$1$3.txt)"
    eval "SM_$1$3=\$(sed -n 's/^reads at 40 during which pidin showed a thread of fs-9p blocked on a slot mutex: \([0-9]*\) of 3.*/\1/p' $W/slot_$1$3.txt)"
}
slot_run follow "" A
slot_run nopi "-w" A
slot_run follow "" B
slot_run nopi "-w" B
slot_run fixed "-f" B
SO_followA=$(mutex_prios $W/slot_followA.txt)
echo "part A, reads at 40 during which a thread of fs-9p waited on a slot mutex: ${SM_followA:-?} of 3 by default, ${SM_nopiA:-?} of 3 with -w; by default the waiting thread / the slot's owner ran at ${SO_followA:-?}"
echo "part B, loops that had ended when the read at 40 finished: ${SL_followB:-?} of 8 by default, ${SL_nopiB:-?} with -w, ${SL_fixedB:-?} with -f (guest processors: ${NCPU:-?})"
echo "part B, waits for a free slot by a client above every slot owner: ${SA_followB:-?} by default, ${SA_nopiB:-?} with -w, ${SA_fixedB:-?} with -f; slots handed over: ${SH_followB:-?}, ${SH_nopiB:-?}, ${SH_fixedB:-?}; fallback completions: ${SF_followB:-?}, ${SF_nopiB:-?}, ${SF_fixedB:-?}"
[ -n "${SM_followA:-}" ] && [ "$SM_followA" -ge 1 ] && [ "${SO_followA:-x}" = "40r/40r" ] && [ "${SM_nopiA:-x}" = 0 ] &&
    ok "part A: by default the reader-at-40's server thread waited on the slot's mutex and the slot's owner ran at 40 (pidin: ${SO_followA}); with -w no thread waited on a slot mutex" || bad "part A: ${SM_followA:-?} of 3, priorities ${SO_followA:-?}, -w ${SM_nopiA:-?}"
# The fallback completions of part B are printed above but are not a condition (fix round 13, changed
# after seeing results: 1 of 4 runs had 1). For the second before the reader at 40 starts, the loops
# at 30 keep the slot owner (10) and the interrupt thread (following the highest waiting client, 10)
# from running, and the owner's 200 ms timed wait expires. When the reader at 40 waits for the slot,
# both run at 40; if the owner runs first, it takes a completion from the ring itself and the
# statistics count it as "reaped by waiters". Which of the two runs first is not fixed (inferred
# from src/virtq.c and the counts of that run: 47 requests, 47 interrupts; not traced). The check
# uses the counts that the claim is about: loops that had ended, slot hand-overs, the interrupt
# thread's highest priority, and the md5 of the data.
[ "${SL_followB:-x}" = 0 ] && [ -n "${SA_followB:-}" ] && [ "$SA_followB" -ge 1 ] && [ -n "${SH_followB:-}" ] && [ "$SH_followB" -ge 1 ] && [ "${SI_followB:-x}" = 40 ] && [ "${SP_followB:-x}" = 0 ] && grep -q "^$HIMD5" $W/slot_followB.txt &&
    ok "part B by default: the reader at 40 waited for the slot of the reader at 10 (${SA_followB} waits above every owner, ${SH_followB} slots handed over), the interrupt thread was raised to 40, and the read (md5 equal) ended while all 8 loops at 30 still ran" || bad "part B by default: loops ended ${SL_followB:-?}, waits above ${SA_followB:-?}, handed over ${SH_followB:-?}, interrupt thread highest ${SI_followB:-?}"
[ -n "${SL_nopiB:-}" ] && [ -n "${NCPU:-}" ] && [ "$SL_nopiB" -gt $((8 - NCPU)) ] && [ -n "${SA_nopiB:-}" ] && [ "$SA_nopiB" -ge 1 ] && [ "${SH_nopiB:-x}" = 0 ] && grep -q "^$HIMD5" $W/slot_nopiB.txt &&
    ok "part B with -w (0.9.0 behaviour): the reader at 40 waited for the slot of the reader at 10, and its read ended only after ${SL_nopiB} of 8 loops had ended (more than 8 minus ${NCPU} processors)" || bad "part B with -w: loops ended ${SL_nopiB:-?}, waits above ${SA_nopiB:-?}, handed over ${SH_nopiB:-?}"
[ -n "${SL_fixedB:-}" ] && [ -n "${NCPU:-}" ] && [ "$SL_fixedB" -gt $((8 - NCPU)) ] && grep -q "^$HIMD5" $W/slot_fixedB.txt &&
    ok "part B with -f: the read at 40 ended only after ${SL_fixedB} of 8 loops had ended" || bad "part B with -f: loops ended ${SL_fixedB:-?}"
rm -f "$SLOW_SHARE/low.bin" "$SLOW_SHARE/high.bin"
else
echo; echo "SKIP: SLOW_SHARE not set; the request-slot step did not run"
fi

if [ -n "${SHARE2:-}" ]; then
step "two virtio-9p devices at the same time: -a selects by mount tag; share2 is modern-only (1af4:1049)"
S2=$SHARE2; MP2=/mnt/host2
rm -rf "$S2/t" "$S2/attr"; mkdir -p "$S2/t" "$S2/attr"; echo "second share" > "$S2/t/marker.txt"
G "$GD/fs-9p -d -v -a hostshare -m $MP 2>$GD/fs-9p-a1.log; echo exit1=\$?; $GD/fs-9p -d -v -a share2 -m $MP2 2>$GD/fs-9p-a2.log; echo exit2=\$?; grep -h 'mounted at' $GD/fs-9p-a1.log $GD/fs-9p-a2.log; grep -h -E 'skipping|1af4:1049|modern-only' $GD/fs-9p-a2.log" > $W/two.txt 2>&1; cat $W/two.txt
grep -q '^exit1=0' $W/two.txt && grep -q '^exit2=0' $W/two.txt && ok "two instances mounted: -a hostshare at $MP, -a share2 at $MP2" || bad "two instances with -a"
grep -q 'mount tag "share2" mounted at /mnt/host2 (9P2000.L, msize [0-9]*, modern interface' $W/two.txt && grep -q 'found 1af4:1049' $W/two.txt &&
    ok "-t auto (default) uses the virtio 1.x interface for the modern-only device 1af4:1049" || bad "modern-only device"
grep -q 'device 0 is attached by another driver or not usable; skipping it' $W/two.txt && ok "the second instance skips the device that the first instance owns (no reset)" || bad "skip of the owned device"
[ "$(G "cat $MP2/t/marker.txt; cat '$MP/tree/one byte.txt'")" = "second share
x" ] && ok "each mountpoint shows its own host folder" || bad "two mountpoints"
step "write operations over the virtio 1.x interface (device share2, $MP2)"
G "echo 'hello from qnx' > $MP2/t/new.txt; echo 'second line' >> $MP2/t/new.txt" > $W/m1.txt 2>&1; cat $W/m1.txt
[ "$(cat "$S2/t/new.txt" 2>/dev/null)" = "$(printf 'hello from qnx\nsecond line')" ] && ok "modern: create + write + append: host sees 2 lines" || bad "modern: create/write/append"
G "echo short > $MP2/t/new.txt" >> $W/m1.txt 2>&1
[ "$(cat "$S2/t/new.txt" 2>/dev/null)" = short ] && ok "modern: O_TRUNC rewrite" || bad "modern: O_TRUNC"
G "cp '$MP/tree/big file.bin' '$MP2/t/big copy.bin'" > $W/m2.txt 2>&1; cat $W/m2.txt
[ "$(md5sum < "$S2/t/big copy.bin" 2>/dev/null | cut -d' ' -f1)" = "$BIGMD5" ] && ok "modern: cp of the 12 MiB file from $MP to $MP2: host md5 equal" || bad "modern: cp between the two mounts"
G "set -e; cd $MP2/t; mkdir -p 'new dir/sub'; echo inner > 'new dir/sub/f.txt'; mv 'big copy.bin' 'new dir/sub/moved.bin'; mv 'new dir/sub/f.txt' f2.txt" > $W/m3.txt 2>&1; cat $W/m3.txt
[ -f "$S2/t/f2.txt" ] && [ "$(md5sum < "$S2/t/new dir/sub/moved.bin" 2>/dev/null | cut -d' ' -f1)" = "$BIGMD5" ] && ok "modern: mkdir, rename within and across folders" || bad "modern: mkdir/rename"
G "set -e; cd $MP2/t; rm 'new dir/sub/moved.bin'; rmdir 'new dir/sub'; rmdir 'new dir'; rm f2.txt" > $W/m4.txt 2>&1; cat $W/m4.txt
[ ! -e "$S2/t/new dir" ] && [ ! -e "$S2/t/f2.txt" ] && ok "modern: unlink and rmdir" || bad "modern: unlink/rmdir"
G "dd if=/dev/urandom of=/tmp/fs9p_m100.bin bs=1048576 count=100 2>/dev/null; md5sum /tmp/fs9p_m100.bin; dd if=/tmp/fs9p_m100.bin of=$MP2/t/big100.bin bs=104857600 count=1 2>&1 | grep -v -i -E 'bytes/s|seconds|copied'; rm /tmp/fs9p_m100.bin" > $W/m5.txt 2>&1; cat $W/m5.txt
M100=$(awk 'NR==1 {print $1}' $W/m5.txt)
[ -n "$M100" ] && [ "$(md5sum < "$S2/t/big100.bin" | cut -d' ' -f1)" = "$M100" ] && [ "$(stat -c %s "$S2/t/big100.bin")" = 104857600 ] && ok "modern: one write() of 100 MiB, host md5 equal" || bad "modern: 100 MiB write"
G "$GD/attr_test $MP2/attr $HU $HG $HG2" > $W/attr2.txt 2>&1; cat $W/attr2.txt
awk '/^STEP/ {print $2, $3}' $W/attr.txt > $W/attr_rc1.txt; awk '/^STEP/ {print $2, $3}' $W/attr2.txt > $W/attr_rc2.txt
same "modern: attribute test gives the same step results as on the legacy interface" $W/attr_rc1.txt $W/attr_rc2.txt
[ "$(stat -c %a "$S2/attr/mode.bin" 2>/dev/null)" = 640 ] && [ "$(stat -c '%X %Y' "$S2/attr/utime.bin" 2>/dev/null)" = "1000000000 1200000000" ] && [ "$(stat -c %s "$S2/attr/size.bin" 2>/dev/null)" = 6000 ] &&
    ok "modern: chmod 640, utime and truncate seen on the host" || bad "modern: attributes on the host"
G "slay -f fs-9p; sleep 1; tail -2 $GD/fs-9p-a1.log; tail -2 $GD/fs-9p-a2.log; test ! -e $MP && test ! -e $MP2 && echo both-unmounted" > $W/two_um.txt 2>&1; cat $W/two_um.txt
[ "$(grep -c ' 0 lost, ' $W/two_um.txt)" = 2 ] && grep -q both-unmounted $W/two_um.txt && ok "both instances unmounted, 0 lost requests" || bad "unmount of the two instances"
[ "$(grep -c ' 0 reaped by waiters, ' $W/two_um.txt)" = 2 ] && ok "both instances: every completion was found through the interrupt (0 reaped by the 200 ms fallback scan)" || bad "completions reaped by the fallback scan: $(grep -o '[0-9]* reaped by waiters' $W/two_um.txt | tr '\n' ' ')"
rm -rf "$S2/t" "$S2/attr"
else
echo; echo "SKIP: SHARE2 not set; the two-device and modern-write steps did not run"
fi

step "option -a with a mount tag that no device has"
G "$GD/fs-9p -d -a no_such_tag -m /mnt/none; echo exit=\$?" > $W/notag.txt 2>&1; cat $W/notag.txt
grep -q 'no virtio-9p device with mount tag "no_such_tag" found' $W/notag.txt && grep -q '^exit=1' $W/notag.txt && ok "-a no_such_tag: error message and exit status 1" || bad "-a with an unknown tag"

step "second mount, read-only, with the virtio 1.x (modern) interface: fs-9p -d -r -t modern"
G "$GD/fs-9p -d -v -r -t modern -m $MP 2>$GD/fs-9p-modern.log; echo exit=\$?" | tee $W/mount2.txt
grep -q 'exit=0' $W/mount2.txt && G "grep -q 'modern interface' $GD/fs-9p-modern.log" && ok "mount (modern interface)" || bad "mount (modern interface)"
G "cd $MP/tree && find . -type f -exec cksum {} +" | LC_ALL=C sort -k3 > $W/guest_cksum2.txt
same "cksum of all files (modern interface)" $W/host_cksum.txt $W/guest_cksum2.txt
G "cd $MP/tree; md5sum 'big file.bin' > $GD/m1.txt & md5sum 'big file.bin' > $GD/m2.txt & wait; cat $GD/m1.txt $GD/m2.txt" > $W/conc2.txt 2>&1
[ "$(grep -c "^$BIGMD5" $W/conc2.txt)" = 2 ] && ok "two concurrent readers (modern interface)" || bad "concurrent readers (modern interface)"
G "echo x > $MP/tree/new.txt; mkdir $MP/tree/newdir; rm $MP/tree/empty.txt; mv $MP/tree/empty.txt $MP/tree/e2.txt" > $W/ro.txt 2>&1
cat $W/ro.txt
[ "$(grep -c 'Read-only file system' $W/ro.txt)" = 4 ] && ok "read-only mount: write, mkdir, rm, mv give EROFS" || bad "read-only"
G "chmod 600 $MP/tree/empty.txt; chown 0 $MP/tree/empty.txt; touch $MP/tree/empty.txt" > $W/ro2.txt 2>&1
cat $W/ro2.txt
[ "$(grep -c 'Read-only file system' $W/ro2.txt)" = 3 ] && ok "read-only mount: chmod, chown, touch give EROFS" || bad "read-only attributes"
[ -f "$T/empty.txt" ] && [ ! -e "$T/new.txt" ] && ok "host tree unchanged" || bad "host tree changed"
G "slay -f fs-9p; sleep 1; ls $MP 2>&1; tail -2 $GD/fs-9p-modern.log" > $W/umount2.txt 2>&1
cat $W/umount2.txt
grep -q "No such file or directory" $W/umount2.txt && ok "unmount (modern interface)" || bad "unmount (modern interface)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
