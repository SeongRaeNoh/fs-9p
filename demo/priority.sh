#!/usr/bin/env bash
# demo/priority.sh - shows with pidin that fs-9p passes the priority of a waiting client on to its
# interrupt thread.
#
# QNX message passing runs the fs-9p server thread that receives a client's request at the client's
# priority. The device's reply is collected by fs-9p's interrupt thread, which receives no message and
# so inherits nothing. By default fs-9p raises the interrupt thread to the priority of the highest
# waiting client; with -f it keeps the base priority 21.
#   Part 1: pidin while a reader at priority 40 waits for a read, once with -f and once by default:
#           the reader (REPLY-blocked on fs-9p), the server thread (40, CONDVAR: waiting for the
#           device), and the interrupt thread (state INTR): 21 with -f, 40 by default.
#   Part 2: the same reader next to 8 CPU-bound loops at priority 30. The counters of fs-9p's
#           statistics lines show how many completions a waiting server thread had to collect itself
#           after its fallback wait, because the interrupt thread did not get the processor.
#   Part 3: fs-9p -n 1 (one request slot) on the throttled device; a reader at priority 10 reads a
#           3 MiB file, so one of its requests holds the slot almost all the time.
#           3a (default, no load): pidin while a reader at 40 waits for the slot: its server thread
#           is blocked on the slot's mutex (state MUTEX), and the slot's owner, the reader-at-10's
#           server thread, runs at 40 (priority inheritance of the mutex).
#           3b: 8 loops at 30 start while the reader at 10 holds the slot, then a reader at 40 reads
#           256 KiB into /dev/shmem (md5sum of it runs after the loops have ended, so that the read
#           waits for nothing outside fs-9p); with -f, -w (no priority inheritance through the slots, as in 0.9.0) and by
#           default. The count of loops that had ended when the read finished shows whether the
#           reader at 40 waited for work at priority 10.
# Counts and priorities only; the script prints no times.
#
# Part 1 needs a read request that stays in flight long enough for pidin to see it. It uses a third
# virtio-9p device whose reads QEMU throttles. QEMU options for it (on the machine that runs QEMU):
#   -fsdev local,id=fs2,path=$SLOW_SHARE,security_model=none,throttling.bps-read=262144
#   -device virtio-9p-pci,fsdev=fs2,mount_tag=slow
# Part 2 uses the normal shared folder (SHARE, mount tag hostshare).
#
# Runs on the developer machine with the settings of tests/env.local (see tests/env.example), plus
# SLOW_SHARE (host folder of the throttled device) and SLOW_TAG (its mount tag, default slow). The
# driver must be in the guest at GUEST_FS9P (default /tmp/fs9p/fs-9p, where tests/run_guest_tests.sh
# puts it). The script stops running fs-9p instances first and mounts SHARE at /mnt/host again at the
# end. Output: the terminal and tests/logs/priority_<date>.log. PAUSE=2 waits 2 s after each step.
# RUNS=N repeats parts 2 and 3b N times (default 1); the summary then gives the count of every run
# and the range, because the count with -f depends on how the scheduler places the loops and the
# reader.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.."
[ -f tests/env.local ] || { echo "tests/env.local missing; copy tests/env.example and edit it"; exit 2; }
. tests/env.local
: "${BUILD_HOST:?}" "${SHARE:?}" "${GUEST_SSH:?}" "${SLOW_SHARE:?set SLOW_SHARE in tests/env.local}"
SLOW_TAG=${SLOW_TAG:-slow}
SHARE_TAG=${SHARE_TAG:-hostshare}
GUEST_FS9P=${GUEST_FS9P:-/tmp/fs9p/fs-9p}
GD=$(dirname "$GUEST_FS9P")
PAUSE=${PAUSE:-0}
mkdir -p tests/logs
LOG=tests/logs/priority_$(date +%Y%m%d_%H%M%S).log
q() { printf '%q' "$1"; }
SRCHASH=$(sh tests/srchash.sh)

# The ssh calls send the remote stderr to stdout on the QEMU host and drop ssh's own stderr, so a
# login message of the QEMU host does not mix into the output.
# raw CMD: run CMD as root in the guest, print its output only
raw() { ssh -q "$BUILD_HOST" "exec 2>&1; $GUEST_SSH $(q "$1") </dev/null" 2>/dev/null; }
# guest SHOWN [CMD]: print SHOWN with a guest prompt, run CMD (default SHOWN) in the guest
guest() { printf '\nqnx# %s\n' "$1"; raw "${2:-$1}"; sleep "$PAUSE"; }
# host CMD: run CMD on the QEMU host (output only)
host() { ssh -q "$BUILD_HOST" "exec 2>&1; $1" 2>/dev/null; }
say() { printf '\n### %s\n' "$*"; }
# the interrupt thread is the thread of fs-9p in state INTR (blocked in InterruptWait())
irq_line() { grep -E ' INTR( |$)' "$1" | head -1; }
prio_of() { awk '{ sub(/[a-z]$/, "", $4); print $4 }'; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
{
echo "# fs-9p priority demo, $(date +%Y-%m-%d), sources sha256 $SRCHASH (tests/srchash.sh)"
echo "# guest: $(raw 'uname -sr'), $(raw "pidin info | grep -c '^Processor'") processors"

say "0. Stop running fs-9p instances; test files on the host: SLOW_SHARE/data.bin and SHARE/prio_demo/data.bin (2 MiB each)"
raw "slay -f fs-9p >/dev/null 2>&1; sleep 1; echo \"fs-9p processes running: \$(pidin -p fs-9p | grep -c fs-9p)\""
host "head -c 2097152 /dev/urandom > $(q "$SLOW_SHARE/data.bin"); mkdir -p $(q "$SHARE/prio_demo"); head -c 2097152 /dev/urandom > $(q "$SHARE/prio_demo/data.bin")"
SLOW_MD5=$(host "md5sum < $(q "$SLOW_SHARE/data.bin")" | cut -d' ' -f1)
DEMO_MD5=$(host "md5sum < $(q "$SHARE/prio_demo/data.bin")" | cut -d' ' -f1)
# guest helper for part 2: 8 loops at priority $1 that end by themselves, a 2 MiB read, a count of
# the loops that had ended when the read finished (the same steps as tests/host_side.sh)
cat > "$W/load_read.sh" <<EOF
rm -f $GD/loopend.*
i=0
while [ \$i -lt 8 ]; do on -p \$1 sh -c 'end=\$((SECONDS+8)); while [ \$SECONDS -lt \$end ]; do :; done; touch $GD/loopend.'\$i & i=\$((i+1)); done
sleep 1
dd if=/mnt/host/prio_demo/data.bin bs=131072 count=16 2>/dev/null | md5sum
echo "loops that had ended when the read finished: \$(ls $GD/loopend.* 2>/dev/null | wc -l | tr -d ' ') of 8"
wait
rm -f $GD/loopend.*
EOF
scp -q "$W/load_read.sh" "$BUILD_HOST:$(q "$SHARE/prio_demo/load_read.sh")" 2>/dev/null && host "$GUEST_SCP $(q "$SHARE/prio_demo/load_read.sh") $(q "$GUEST_DEST$GD/load_read.sh")"
# guest helper for part 3 (the same steps as the request-slot step of tests/host_side.sh):
# sh slot.sh A|B, run under "on -p 50", with fs-9p -n 1 mounted at /mnt/slow
MS=/mnt/slow
cat > "$W/slot.sh" <<EOF
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
scp -q "$W/slot.sh" "$BUILD_HOST:$(q "$SHARE/prio_demo/slot.sh")" 2>/dev/null && host "$GUEST_SCP $(q "$SHARE/prio_demo/slot.sh") $(q "$GUEST_DEST$GD/slot.sh")"
host "head -c 3145728 /dev/urandom > $(q "$SLOW_SHARE/low.bin"); head -c 262144 /dev/urandom > $(q "$SLOW_SHARE/high.bin")"
HI_MD5=$(host "md5sum < $(q "$SLOW_SHARE/high.bin")" | cut -d' ' -f1)

for mode in fixed follow; do
    if [ $mode = fixed ]; then opt="-f "; title="fixed interrupt-thread priority (-f)"; else opt=""; title="default: the interrupt thread follows the client"; fi
    say "1.$([ $mode = fixed ] && echo a || echo b). $title: pidin while a reader at priority 40 waits"
    guest "fs-9p -d -v $opt-a $SLOW_TAG -m /mnt/slow" "$GUEST_FS9P -d -v $opt-a $SLOW_TAG -m /mnt/slow 2>$GD/prio_demo_$mode.log; grep -h 'mounted at' $GD/prio_demo_$mode.log"
    printf '\nqnx# on -p 40 sh -c "dd if=/mnt/slow/data.bin bs=128k | md5sum" &   # a reader at priority 40\nqnx# pidin -p dd; pidin -p fs-9p\n'
    raw "on -p 40 sh -c 'dd if=/mnt/slow/data.bin bs=131072 2>/dev/null | md5sum > $GD/prio_md5.txt' </dev/null >/dev/null 2>&1 & sleep 1; pidin -p dd; pidin -p fs-9p; wait" > "$W/pidin_$mode.txt"
    cat "$W/pidin_$mode.txt"
    il=$(irq_line "$W/pidin_$mode.txt")
    eval "IRQ_$mode=\$(echo \"\$il\" | prio_of)"
    eval "echo \"# interrupt thread (the fs-9p thread in state INTR): priority \$IRQ_$mode\""
    sleep "$PAUSE"
    guest "cat prio_md5.txt   # md5sum of the data the reader got (the host's md5 in brackets)" "sed 's,  -\$,  (host: $SLOW_MD5),' $GD/prio_md5.txt; rm -f $GD/prio_md5.txt"
    guest "slay fs-9p   # unmount; fs-9p prints its statistics" "slay fs-9p; sleep 1; tail -2 $GD/prio_demo_$mode.log"
done

RUNS=${RUNS:-1}
for run in $(seq 1 "$RUNS"); do
for mode in fixed follow; do
    if [ $mode = fixed ]; then opt="-f "; else opt=""; fi
    say "2.$([ $mode = fixed ] && echo a || echo b)$([ "$RUNS" -gt 1 ] && echo ", run $run of $RUNS"). fs-9p $([ -n "$opt" ] && echo "-f" || echo "(default)"): a reader at priority 40 next to 8 CPU-bound loops at priority 30"
    guest "fs-9p -d -v $opt-a $SHARE_TAG -m /mnt/host" "$GUEST_FS9P -d -v $opt-a $SHARE_TAG -m /mnt/host 2>$GD/prio_load_$mode.log; grep -h 'mounted at' $GD/prio_load_$mode.log"
    guest "on -p 40 sh load_read.sh 30   # 8 loops at 30, then a 2 MiB read at 40" "cd $GD && on -p 40 sh load_read.sh 30 | sed 's,  -$,  (host: $DEMO_MD5),'" | tee "$W/load_$mode.txt"
    guest "slay fs-9p   # unmount; fs-9p prints its statistics" "slay fs-9p; sleep 1; tail -2 $GD/prio_load_$mode.log" | tee -a "$W/load_$mode.txt"
    eval "RW_$mode=\$(sed -n 's/.* \([0-9]*\) reaped by waiters.*/\1/p' \"\$W/load_$mode.txt\")"
    eval "NR_$mode=\$(sed -n 's/.*unmounting [^ ]* (\([0-9]*\) 9P requests.*/\1/p' \"\$W/load_$mode.txt\")"
    eval "HI_$mode=\$(sed -n 's/.*raised [0-9]* times, highest \([0-9]*\);.*/\1/p' \"\$W/load_$mode.txt\")"
    eval "ALL_$mode=\"\${ALL_$mode:-}\${RW_$mode:-?}/\${NR_$mode:-?} \""
done
done

# mutex_prios FILE: in the first pidin block with a thread of fs-9p in state MUTEX, the priority of
# that thread and of the thread it waits for (pidin's Blocked column: pid-tid), as "40r/40r"
mutex_prios() { awk '/^--$/ { if (w != "") exit; split("", p); next } $3 ~ /fs-9p$/ { p[$2 + 0] = $4 } $3 ~ /fs-9p$/ && $5 == "MUTEX" && w == "" { w = $4; split($7, a, "-"); o = a[2] + 0 } END { if (w != "") print w "/" p[o] }' "$1"; }
say "3a. fs-9p -n 1 (default): pidin while a reader at priority 40 waits for the request slot that a reader at priority 10 holds (no load)"
guest "fs-9p -d -v -n 1 -a $SLOW_TAG -m /mnt/slow" "$GUEST_FS9P -d -v -n 1 -a $SLOW_TAG -m /mnt/slow 2>$GD/slot_demo.log; grep -h -E 'mounted at|VQ: ' $GD/slot_demo.log"
guest "on -p 50 sh slot.sh A   # a reader at 10 reads 3 MiB; three 4 KiB reads at 40; pidin until a thread waits on the slot's mutex" "cd $GD && on -p 50 sh slot.sh A" | tee "$W/slotA.txt"
guest "slay fs-9p   # unmount; fs-9p prints its statistics" "slay fs-9p; sleep 1; tail -2 $GD/slot_demo.log" | tee -a "$W/slotA.txt"
SMA=$(sed -n 's/^reads at 40 during which pidin showed a thread of fs-9p blocked on a slot mutex: \([0-9]*\) of 3.*/\1/p' "$W/slotA.txt")
SOA=$(mutex_prios "$W/slotA.txt")
for run in $(seq 1 "$RUNS"); do
for mode in fixed nopi follow; do
    case $mode in fixed) opt="-f " t="-f" ;; nopi) opt="-w " t="-w (no priority inheritance through the slots, as in 0.9.0)" ;; *) opt="" t="(default)" ;; esac
    say "3b.$([ "$RUNS" -gt 1 ] && echo " run $run of $RUNS,") fs-9p -n 1 $t: a reader at 10 holds the request slot, 8 loops at 30 start, then a reader at 40 reads 256 KiB"
    guest "fs-9p -d -v ${opt}-n 1 -a $SLOW_TAG -m /mnt/slow" "$GUEST_FS9P -d -v ${opt}-n 1 -a $SLOW_TAG -m /mnt/slow 2>$GD/slot_demo.log; grep -h 'mounted at' $GD/slot_demo.log"
    guest "on -p 50 sh slot.sh B" "cd $GD && on -p 50 sh slot.sh B | sed 's,  -\$,  (host: $HI_MD5),'" | tee "$W/slotB_$mode.txt"
    guest "slay fs-9p   # unmount; fs-9p prints its statistics" "slay fs-9p; sleep 1; tail -2 $GD/slot_demo.log" | tee -a "$W/slotB_$mode.txt"
    le=$(sed -n 's/^loops that had ended when the read at 40 finished: \([0-9]*\) of 8.*/\1/p' "$W/slotB_$mode.txt")
    sa=$(sed -n 's/.* \([0-9]*\) by a client above every slot owner.*/\1/p' "$W/slotB_$mode.txt")
    sh_=$(sed -n 's/.* \([0-9]*\) slots handed over.*/\1/p' "$W/slotB_$mode.txt")
    sf=$(sed -n 's/.* \([0-9]*\) reaped by waiters.*/\1/p' "$W/slotB_$mode.txt")
    grep -q "^$HI_MD5" "$W/slotB_$mode.txt" && md=equal || md=different
    eval "LE3_$mode=\"\${LE3_$mode:-}${le:-?} \"; SA3_$mode=\"\${SA3_$mode:-}${sa:-?} \"; SH3_$mode=\"\${SH3_$mode:-}${sh_:-?} \"; SF3_$mode=\"\${SF3_$mode:-}${sf:-?} \"; MD3_$mode=\"\${MD3_$mode:-}$md \""
done
done

say "Summary (counts and priorities from the output above)"
echo "reader at priority 40, interrupt thread while the read waited (pidin): ${IRQ_fixed:-?} with -f, ${IRQ_follow:-?} by default"
echo "with 8 loops at priority 30$([ "$RUNS" -gt 1 ] && echo ", run $RUNS"): ${RW_fixed:-?} of ${NR_fixed:-?} 9P requests were completed by the waiting server thread's fallback wait instead of the interrupt thread with -f (highest interrupt-thread priority ${HI_fixed:-?}); ${RW_follow:-?} of ${NR_follow:-?} by default (highest ${HI_follow:-?})"
if [ "$RUNS" -gt 1 ]; then
    range() { tr ' ' '\n' | sed -n 's,^\([0-9]*\)/.*,\1,p' | sort -n | sed -n '1p;$p' | tr '\n' ' ' | awk '{ print $1 " to " $2 }'; }
    echo "fallback completions per run (completed by the fallback wait / 9P requests), $RUNS runs: with -f: ${ALL_fixed:-}(range $(echo "${ALL_fixed:-}" | range)); by default: ${ALL_follow:-}(range $(echo "${ALL_follow:-}" | range))"
fi
nrange() { tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '1p;$p' | tr '\n' ' ' | awk '{ print $1 " to " ($2 == "" ? $1 : $2) }'; }
echo "part 3a (fs-9p -n 1, default, no load): reads at 40 during which a server thread waited on the slot's mutex: ${SMA:-?} of 3; priority of the waiting thread / of the slot's owner (the reader-at-10's server thread) in the first such pidin: ${SOA:-?}"
echo "part 3b (fs-9p -n 1, reader at 10 holds the slot, 8 loops at 30, a 256 KiB read at 40), $RUNS run(s) per mode; loops that had ended when the read at 40 finished (of 8), per run: with -f: ${LE3_fixed:-}(range $(echo "${LE3_fixed:-}" | nrange)); with -w: ${LE3_nopi:-}(range $(echo "${LE3_nopi:-}" | nrange)); by default: ${LE3_follow:-}(range $(echo "${LE3_follow:-}" | nrange))"
echo "part 3b, waits for a free slot by a client above every slot owner, per run: -f: ${SA3_fixed:-}; -w: ${SA3_nopi:-}; default: ${SA3_follow:-}| slots handed over: -f: ${SH3_fixed:-}; -w: ${SH3_nopi:-}; default: ${SH3_follow:-}| fallback completions: -f: ${SF3_fixed:-}; -w: ${SF3_nopi:-}; default: ${SF3_follow:-}| md5 of the read at 40 against the host: -f: ${MD3_fixed:-}; -w: ${MD3_nopi:-}; default: ${MD3_follow:-}"
echo "fallback wait: a server thread that waits for the device looks at the ring itself every 200 ms, in case the interrupt thread did not run (a constant in src/virtq.c, not a measurement); the counts say how often that check, not the interrupt thread, completed a request"

say "Mount the shared folder again (default options)"
guest "fs-9p -d -a $SHARE_TAG -m /mnt/host" "$GUEST_FS9P -d -a $SHARE_TAG -m /mnt/host 2>&1 | grep 'mounted at'; rm -f $GD/load_read.sh $GD/slot.sh"
host "rm -rf $(q "$SHARE/prio_demo") $(q "$SLOW_SHARE/data.bin") $(q "$SLOW_SHARE/low.bin") $(q "$SLOW_SHARE/high.bin")"
} 2>&1 | sed -e "s,$SLOW_SHARE,SLOW_SHARE,g" -e "s,$SHARE,SHARE,g" | tee "$LOG"
echo "log: $LOG"
