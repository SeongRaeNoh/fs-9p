# Task: libxml2's test programs must pass in the QNX 8.0 guest

This folder: `[session folder]` (called "this
folder" below). Use absolute paths in every command.

## Goal

`libxml2/` is a clone of libxml2 at tag v2.15.4, unchanged at the start. `./run.sh ci` builds it
with qcc (QNX SDP 8.0) and runs libxml2's own ctest suite in a QNX 8.0 guest through fs-9p's
`tools/qnx-ci.sh`. One of libxml2's test programs crashes in the guest. Built for Linux with glibc,
the same program passes.

Find the cause in libxml2's code, make the smallest fix, and show both of these:

1. `./run.sh ci` with no options ends with every test program that `tools/qnx-ci.sh` runs in the
   guest passed (8 of 8), and the line `run.sh: tools/qnx-ci.sh exit status 0`. `tools/qnx-ci.sh`
   leaves out libxml2's script and catalog tests, because they would run on Linux; it names them in
   its output. That is expected and is not part of this task.
2. `./run.sh linux` with no options (the Linux reference build) still passes all its tests.

## What you have

| Path in this folder | Content |
|---|---|
| `libxml2/` | git clone of libxml2 at tag v2.15.4 (commit `9649899`, shallow). Your change goes here. |
| `run.sh` | your only way to the QNX guest and to the Linux reference build; usage in its header |
| `server/srv.sh` | the part of `run.sh` that runs on the lab server (read it if you want to know what `run.sh` does there) |
| `fs-9p/` | a read-only copy of fs-9p's `README.md` (passages about libxml2 removed), `AGENTS.md`, `docs/usage.md` and `tools/` (`qnx-ci.sh`, `qnx-run`, `qnx-vm`, `qnx-share.sh`). The lab server runs the same tool files. |
| `results/calls/` | made by `run.sh`: the complete output of each call (`NNN-SUBCOMMAND.txt`) and the JUnit file of each `ci` call |
| `scratch/` | make it if you need room for your own files (notes, a small test program) |
| `SESSION_LOG.md` | you write it (format below) |

## How the guest is reached

QNX SDP 8.0, QEMU and cmake are on a lab server. `run.sh` reaches it with ssh. The QNX 8.0 guest
runs in QEMU on that server (ssh port 22349). In the guest, the fs-9p driver mounts a server folder
at `/mnt/host`; `run.sh` prints that folder as `SHARE`. Programs that qcc builds into `SHARE` run in
the guest without copying, and the guest writes core files of crashed programs into `SHARE` too.

| Command (by absolute path) | What it does |
|---|---|
| `run.sh ci [--tests=REGEX] [--keep-vm]` | copies `libxml2/` to `SHARE/src/libxml2`, then `tools/qnx-ci.sh`: boots the guest, builds with qcc into `SHARE/ci/libxml2`, runs the tests in the guest, puts gdb's backtrace of each crashed test into the JUnit file, stops the guest (`--keep-vm`: leaves it running) |
| `run.sh linux [ctest args]` | copies `libxml2/` as `ci` does, builds it with the server's gcc and runs ctest on Linux |
| `run.sh vm start\|stop\|status` | starts, stops or reports this session's guest |
| `run.sh run [-t S] [-C DIR] [-e V=X]... PROGRAM [ARG...]` | `tools/qnx-run --json` in the running guest; core files go to `SHARE/cores` |
| `run.sh gdb PROGRAM CORE COMMAND...` | the SDP's gdb on the server, on a program and a core file in `SHARE` (accepted commands: see `run.sh`) |
| `run.sh files [PATH]` | lists a folder of `SHARE` |

A `ci` or `linux` call can take several minutes: give the Bash tool its largest time limit
(600000 ms) for them. Each `run.sh` call ends within that limit.

## Rules

1. Fix the cause in libxml2's library sources. Do not edit libxml2's test programs (`testapi.c`,
   `runtest.c`, `runsuite.c`, `runxmlconf.c`, `testcatalog.c`, `testchar.c`, `testdict.c`,
   `testparser.c`, `testrecurse.c`, `testlimits.c`, `testModule.c`, `testdso.c`), `CMakeLists.txt`,
   the folders `test/` and `result/`, `run.sh`, `server/` or `fs-9p/`. Do not change build options,
   and do not skip, disable or weaken a test. The sha256 of every file was recorded before the session.
2. Leave your change in the clone's working tree: no `git commit`, `stash`, `reset` or `checkout`.
3. Read only the files of this folder that the table above names, and your own files. Do not open
   `LAUNCH_PROMPT.md`, `PUBLISH.md`, `make_example.py` or `setup/` (they belong to the people who
   set up this session), and do not open files outside this folder.
4. Reach the guest and the lab server only through `run.sh`. Do not run ssh, scp or rsync yourself.
   Never start a coding agent on the lab server.
5. QNX licence: do not open, print or copy files of the QNX SDP (headers, libraries,
   documentation). Do not ask gdb for disassembly or memory dumps of QNX system libraries. For QNX
   API questions you may read the public QNX 8.0 documentation at
   https://www.qnx.com/developers/docs/8.0/ with WebFetch. Open no other web pages: no web search,
   and not libxml2's repository, issue tracker or mailing lists.
6. No timing figures: do not measure, print or write run times.
7. Do not ask anyone and do not contact anyone. Work until the goal is met or you cannot go on.
8. At the end, `run.sh vm status` must print `guest not running` (run `run.sh vm stop` if you
   started a guest with `vm start` or `ci --keep-vm`).

## Session log

Write `SESSION_LOG.md` in this folder as you go: start it before the first `run.sh` call and add to
it after each step, not only at the end. It may be published, so write plain English, factual,
with no timing figures. Format:

```text
# Session log: libxml2 tests in the QNX 8.0 guest

Task: TASK.md in this folder. Result: <one sentence>. No timing figures are recorded in this log.

## Preparation
- Read: <files, with line ranges if you read parts>

## Iteration N: <short title>
- Ran: `<command>` (exit status N; complete output in results/calls/NNN-....txt)
- Saw: <the relevant output lines, quoted in a code block>
- Concluded: <one fact per sentence; mark each as (checked: how) or (inferred: from what)>
- Changed: <file and a short diff, or "nothing">

## Result
- Cause: file, function, line, and what was wrong
- Fix: the complete diff (`git -C <clone> diff`)
- Why the program crashed only in the guest
- Calls: the number of run.sh calls of each subcommand (counts, no times)
- The last lines of the passing guest run and of the passing Linux run
```
