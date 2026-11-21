#!/usr/bin/env bash
# demo/scp-run.sh - the baseline runner of demo/scp-baseline.sh. It runs a host program in the QNX
# guest without the shared folder, the way a CMAKE_CROSSCOMPILING_EMULATOR script built on scp and
# ssh must: for every run it copies the program, the shared libraries that the program needs from
# the folders of LD_LIBRARY_PATH (and the libraries those need), and the data files that
# SCP_RUN_DATA names for the program into a new guest folder, and runs the program there over ssh.
# With --coverage the gcov runtime writes into a guest folder, and every .gcda file that the run
# wrote is copied back to its host path. After a crash, the core file is copied back. Each copied
# file and each translated path is one line in SCP_RUN_LOG; demo/scp-baseline.sh counts them.
#
# usage: demo/scp-run.sh [--coverage] [-e NAME=VALUE]... program [args...]
# Settings (environment):
#   SCP_RUN_SSH   command that runs a shell command in the guest (like QNX_SSH of tools/qnx-run)
#   SCP_RUN_SCP   command that copies host files into the guest; its last argument is the guest
#                 destination, written as SCP_RUN_DEST followed by the guest path
#   SCP_RUN_DEST  destination prefix (default ":")
#   SCP_RUN_DATA  data files per program: "prog:path,path prog2:path" (paths relative to the
#                 working folder; a folder is copied with all its files)
#   SCP_RUN_CORE  guest folder in which dumper writes core files (default /var/dumper)
#   SCP_RUN_LOG   file that gets one line per copied file and per translated path (default /dev/null)
#   READELF       readelf command for the NEEDED entries (default ntox86_64-readelf)
# Exit status: the program's exit status; 255 if a copy or ssh fails.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cov=0 envs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --coverage) cov=1; shift ;;
        -e) envs+=("$2"); shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
prog=$1; shift
read -r -a SSH <<< "${SCP_RUN_SSH:?}"
read -r -a SCP <<< "${SCP_RUN_SCP:?}"
DEST=${SCP_RUN_DEST:-:} LOG=${SCP_RUN_LOG:-/dev/null} READELF=${READELF:-ntox86_64-readelf}
GD=/tmp/scp-run/run.$$ GC=/tmp/scp-run/gcov
cnt() { echo "$*" >> "$LOG"; }
g() { "${SSH[@]}" "$1" </dev/null; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
put() { "${SCP[@]}" "$@" >/dev/null 2>&1 || { echo "scp-run: copy of $1 into the guest failed" >&2; exit 255; }; }

g "rm -rf $GD; mkdir -p $GD/lib $GC" || exit 255
put "$prog" "$DEST$GD/"
cnt "in program $prog"
cnt "map program $prog -> $GD/$(basename "$prog")"
cnt "map cwd $PWD -> $GD"

genv=() libdirs=
for e in ${envs[@]+"${envs[@]}"}; do
    case "${e%%=*}" in LD_LIBRARY_PATH) libdirs=${e#*=} ;; *) genv+=("${e%%=*}=$(q "${e#*=}")") ;; esac
done
if [ -n "$libdirs" ]; then
    # shared libraries: the NEEDED entries that exist in a folder of LD_LIBRARY_PATH, recursively
    todo=("$prog") seen=" " nlib=0
    while [ ${#todo[@]} -gt 0 ]; do
        f=${todo[0]}; todo=("${todo[@]:1}")
        for n in $($READELF -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
            IFS=: read -r -a dirs <<< "$libdirs"
            for d in "${dirs[@]}"; do
                [ -e "$d/$n" ] || continue
                case "$seen" in *" $n "*) break ;; esac
                seen+="$n "; put "$d/$n" "$DEST$GD/lib/"; cnt "in library $d/$n"; nlib=$((nlib + 1)); todo+=("$d/$n"); break
            done
        done
    done
    cnt "map LD_LIBRARY_PATH $libdirs -> $GD/lib"
    genv+=("LD_LIBRARY_PATH=$GD/lib")
fi
for spec in ${SCP_RUN_DATA:-}; do
    [ "${spec%%:*}" = "$(basename "$prog")" ] || continue
    IFS=, read -r -a paths <<< "${spec#*:}"
    for p in "${paths[@]}"; do
        [ -e "$p" ] || continue
        put -r "$p" "$DEST$GD/"
        find "$p" -type f | while read -r f; do cnt "in data $PWD/$f"; done
        cnt "map data $PWD/$p -> $GD/$p"
    done
done
[ "$cov" = 1 ] && genv+=("GCOV_PREFIX=$GC" "GCOV_PREFIX_STRIP=0")

# coverage: checksums of the .gcda files before the run, to find the files that the run wrote
# (the guest's file times have whole seconds, too coarse for find -newer)
sums() { g "find $GC -name '*.gcda' -exec cksum {} + 2>/dev/null" | sort; }
[ "$cov" = 1 ] && before=$(sums)
args=
for a in "$@"; do args+=" $(q "$a")"; done
"${SSH[@]}" "cd $GD && ${genv[*]} ./$(q "$(basename "$prog")")$args; exit \$?" </dev/null
rc=$?

if [ "$cov" = 1 ]; then
    # the gcov runtime wrote GC/<host path of the object folder>/NAME.gcda: copy back what changed
    for gf in $(comm -13 <(printf '%s\n' "$before") <(sums) | awk '{ print $3 }'); do
        hf=${gf#"$GC"}
        mkdir -p "$(dirname "$hf")" && g "cat $(q "$gf")" > "$hf" || { echo "scp-run: copy of $gf back failed" >&2; exit 255; }
        cnt "back gcda $hf"
        cnt "map gcda $gf -> $hf"
    done
fi
if [ "$rc" -gt 128 ]; then
    cf=${SCP_RUN_CORE:-/var/dumper}/$(basename "$prog").core
    if g "test -f $(q "$cf")"; then
        g "cat $(q "$cf")" > "$(basename "$prog").core" && cnt "back core $PWD/$(basename "$prog").core" && cnt "map core $cf -> $PWD/$(basename "$prog").core"
    fi
fi
g "rm -rf $GD"
exit "$rc"
