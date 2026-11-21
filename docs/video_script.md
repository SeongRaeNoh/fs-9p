# Video script: fs-9p (2:37)

This file describes the demo video as it was made. Length 2:37 (limit: under 3:00). Version shown:
fs-9p 0.10.0 (sources sha256 `ac061f948768`, `tests/srchash.sh`).

## How the footage was made

- All terminal footage is real. A terminal recorder typed each command into a real shell and saved
  every byte of output with its time; the video draws that recording. No output was typed by hand
  or edited. Each shot shows one cut of a recording (a start and an end time), except shot 11, which
  shows three cuts of one replay; nothing is blurred.
  Shots 5, 7 and 12 draw long waits (image build, boot, test runs, the priority runs) shorter than
  they were; a label on each of these shots says so. Shot 1 plays its recording 1.6 times as fast,
  with pauses over 0.4 s shortened; shot 3 plays 1.5 times, shot 5 1.15 times and shot 12 1.4 times
  as fast. The text on screen is the same.
- Shot 5 (quick start) was recorded in a fresh `git clone` of a git repository that holds this
  repository's files at sources `ac061f948768` (the clone has no `build/` folder). It shows the
  README's quick start: the three variables, `make`, `tools/make-image.sh "$IMAGE"` and
  `tools/qnx-vm start "$IMAGE" "$SHARE" "$SSH_PORT"`. Differences from the README, all on purpose:
  the ssh port is 22360 instead of 2222; `make-image.sh`'s output goes through a visible
  `grep '^make-image'`, because the image tool's own output names the folder of the SDP
  installation; the SDP environment (`qnxsdp-env.sh`) and QEMU's path were set before the recording,
  because their output also names install folders. The recording ran in a private mount namespace
  in which the work folder is `/home/dev` (the `~` of the README), so the printed paths read
  `/home/dev/...`; in that namespace ssh does not look in `/home/dev/.ssh` by itself, so
  `QNX_SSH_KEY` (see `tools/qnx-vm`) was set to `/home/dev/.ssh/id_ed25519`. `make-image.sh` put
  the matching public key `/home/dev/.ssh/id_ed25519.pub` into the image, as the README says.
- For shots 1, 2, 3, 6 and 10 the repository folder of the recordings held the image folder
  `fs9p-image/` (made by `tools/make-image.sh` with `SSH_IDENT`) and the shared folder `qnx-share/`
  (README quick start: `IMAGE` and `SHARE`); the image was started with
  `tools/qnx-vm start fs9p-image qnx-share 22360` (the start is not in these shots). In shot 7,
  `tools/qnx-ci.sh` starts and stops this image itself. fs-9p starts at boot from
  `image/post_start.fs-9p` through `image/fs-9p-supervise`.
- Shot 1 runs libxml2's own `testapi` program twice in `qnx-share`: the Linux reference build
  (`qnx-share/oss-linux/libxml2-2.15`), then the qcc build (`qnx-share/ci/libxml2-2.15`) in the
  guest through `tools/qnx-run`, with the build folder as `LD_LIBRARY_PATH`, as `tools/qnx-ci.sh`
  runs it under ctest. Both build folders were made before the recording by
  `demo/oss-suite.sh fs9p-image qnx-share libxml2-2.15` (libxml2 v2.15.4, commit 9649899, cloned
  from gitlab.gnome.org; not shown). `testapi` of v2.15.4 prints nothing when it passes, so both
  runs end with `echo "exit status $?"`. The Linux host is Ubuntu 22.04, so the reference build uses
  glibc. The repository's `tools/` is on `PATH`. Before the recording, the dump folder of the
  guest's `dumper` (`-d /data/var/dumper`) was replaced by a symbolic link to `/mnt/host/cores`, as
  the core-dump step of `tests/host_side.sh` does ("Core files through the share" in
  `docs/usage.md`); it was put back after the recordings.
- Shots 2 and 10 are two cuts of one recording: they read the core file of shot 1 with the SDP's
  `ntox86_64-gdb` on the host. `qnx-share/bt.gdb` holds two settings that gdb reads before it
  loads the core (`-ix`): `set solib-search-path ci/libxml2-2.15` (libxml2's shared library is in
  the build folder) and `set filename-display basename`. A visible `grep` keeps the signal line
  and frames 8 to 10 of the backtrace, and a visible `sed` removes addresses of 5 or more hex
  digits; the null pointer `0x0` stays. Frames 0 to 7 (libxml2's error functions and frames
  outside libxml2) are not shown; a label in shot 10 says so. The backtrace of the logged run is in
  `tests/logs/oss_20261113_031340.log` lines 176-191. Shot 10 then prints line 830 of libxml2's
  `testapi.c` (`xmlNewTextReaderFilename(NULL);`) and line 2104 of its `xmlreader.c`
  (`xmlTextReaderErr(code, "failed to open %s", URI);`). Its three labels appear one after the
  other. The same line 2104 is in libxml2's master branch, and no public report of it was found
  on 2026-11-13 (`docs/upstream-search.md`).
- Shot 3 is one terminal with two tmux panes: left a host shell in `qnx-share/demo` (a two-line
  `Makefile` whose rule runs `qcc -Vgcc_ntox86_64 -o hello hello.c`), right a root shell in the
  guest over ssh in `/mnt/host/demo`.
- Shot 4 is a picture drawn for this video: `docs/architecture.png` (title and footer line cut
  off) and, beside it, a panel on the request slots. The panel's sentences restate
  `docs/internals.md` (table row "Virtqueue"; item 3, "The interrupt thread and the request slots
  follow the priority of the waiting client") and `docs/usage.md` (options `-n` and `-w`). Three
  frames mark the boxes that the narration names: the resource manager, the QNX programs with
  their messages, and the virtqueue.
- Shot 6 is a root shell in the guest over ssh. `pidin -p fs-9p` lists the threads of the running
  fs-9p process (one in `SIGWAITINFO`, the interrupt thread in `INTR`, the others in `RECEIVE`);
  `pidin -p fs-9p -F '%a %n %U %W'` shows its user ID and effective user ID, 1000 (the image starts
  fs-9p as root, and fs-9p drops to `qnxuser` after setup); `mount` lists `/mnt/host` with type `9p`.
- Shot 7 is one run of the plain command `demo/ci.sh fs9p-image qnx-share`, without a filter. The
  shell had line-buffered output set beforehand (the `stdbuf -oL` setting, through `LD_PRELOAD` and
  `_STDBUF_O`), so that the `sed` inside the script prints each line at once instead of in 4 KB
  blocks; the text of the output is the same. The script cloned cJSON v1.7.18 (nothing of cJSON is
  in this repository) and made one `tools/qnx-ci.sh` call on `examples/qnx-unit` and cJSON: boot
  the guest, build each project with qcc into the share, run its ctest suite in the guest with
  `tools/qnx-run` as the test emulator (one test at a time, because coverage is on), write JUnit
  files and gcovr reports from the `.gcda` files that the guest wrote into the share, stop the
  guest. The boot, the first test run and the cJSON test run are drawn as 2 s waits. The shot ends
  before the last three output lines ("qnx-vm: stopped", the exit status, and the line that names
  the run's own log file, which is not in this repository). The output equals
  `tests/logs/ci_20261113_031200.log` line for line except the date line, the ssh port and the log
  name; the counts are on its lines 26 (5 of 5), 29, 31 (92 of 92 lines), 68 (22 of 22), 71, 73
  (1784 of 2009 lines) and 80 (27 tests, 0 failed). The line "time limit 300 s per test" is a
  setting of `tools/qnx-ci.sh`, not a measurement. The narration of this shot says that hosted CI
  may not run the QNX SDP; this is the reason the tests run on the team's own machine.
- Shot 8 is a card. Its counts: `demo/scp-run.sh` (the scp runner) has 108 lines, 77 of them code
  (neither blank nor comment); `demo/scp-baseline.sh` line 35 is the hand-written list of cJSON's
  data folders (2 folders; 29 data files per run, `tests/logs/scp_baseline_20261113_030937.log`
  line 25); the coverage run copied 76 files into the guest and 68 `.gcda` files back (line 26);
  with fs-9p, 0 and 0 (line 30); cJSON's 22 tests passed in both scp runs (line 32). With fs-9p,
  ctest needs one CMake variable, `CMAKE_CROSSCOMPILING_EMULATOR`, set to `tools/qnx-run`.
- Shot 9 is a card, not a recording, with the results in the QNX guest only. Its counts come from
  `tests/logs/oss_20261113_031340.log` (`demo/oss-suite.sh` on all eight rows): table lines 222-229
  (QNX columns), check's checks line 232, total line 233 (guest: 39 ctest tests run, 37 passed),
  failed tests lines 235-237 (`testapi` of both libxml2 versions; for v2.15.4 the card calls it the
  latent bug shown before), check's build options line 96 (its timing-dependent
  self-tests are disabled in this suite), tests left out lines 100 (check) and 159 (libxml2
  v2.15.4). The four libraries of the first row are zlib v1.3.1 (2 of 2), libyaml 0.2.5 (2 of 2),
  libdeflate v1.24 (8 of 8) and utf8proc v2.10.0 (9 of 9). libuv v1.53.0 is built (with `-lm` added
  for its test programs) and its test suite was not run. A ctest test is one run of a test program;
  one program can hold many test cases.
- Shot 11 is a replay of the recorded session in `examples/ai-agent-session-libxml2/` (2026-11-13,
  fs-9p 0.10.0): a fresh AI coding agent got `TASK.md`, an unchanged libxml2 v2.15.4 clone and this
  repository's tools, and fixed the crash of shots 1, 2 and 10. No AI model and no QNX program runs
  in this shot. A small script prints the call lines of `TOOL_CALLS.md` rows 1, 7, 8, 24 and 27
  (call number, tool, input as published) and published files: `logs/001-ci.txt` whole after call 8
  (the call printed that file; 59 lines), `fix.diff` whole after call 24 (the Edit), and after call 27
  the call's own `grep` of the second run's output, run again on the published `logs/002-ci.txt`
  (18 lines; with "exit 0", the 19 lines that row 27 names). Lines in square brackets name the calls
  that are not printed (from the step table in the example's README). Lines longer than the
  120-column window are cut and end in "…". The script's pauses are set for the video, not taken
  from the session. The shot shows three cuts of this 24-second recording (the window title says
  "replay in 3 cuts"): (a) from the start to line 34 of `logs/001-ci.txt` (the failing guest run:
  "2/8 Test #3: testapi ...***Failed", "88% tests passed, 1 tests failed out of 8" on line 26, and
  "-- testapi: crashed with SIGSEGV; core file testapi.core; ..." on line 34); (b) call 24 and
  `fix.diff`; (c) call 27 and its grep lines. Lines 35-59 of `logs/001-ci.txt` (gdb's backtrace and
  the end of the run) are not on screen. The backtrace from the same core file is the one of shots 2
  and 10. The session's Linux reference run (call 28) is not shown.
- Shot 12 is one run of `demo/priority.sh` (one run per mode) with a visible filter:
  `stdbuf -oL demo/priority.sh | sed -un '/^### 3b/,$p' | grep -E '^### 3b|STATE|fs9p/fs-9p|^loops'`.
  The `sed` keeps the output from the first part-3b heading on; the `grep` keeps the three part-3b
  headings, pidin's header and fs-9p rows, and the count line of each mode. The script's other
  parts ran but are not shown, and the grep drops the line that says when pidin ran (1 s after the
  reader at 40 started; a `sleep 1` of the script, not a measurement). Part 3b runs `fs-9p -n 1`
  (one request slot) on a third virtio-9p device whose reads QEMU throttles (the QEMU options in
  the comment of `demo/priority.sh` lines 27-31): a reader at priority 10 holds the slot, 8 loops
  at priority 30 start, then a reader at priority 40 reads 256 KiB. With `-f` and `-w` (the slot
  part of the priority handling off), pidin shows the reader-at-40's server thread at
  `40r CONDVAR` and the slot's owner at `10r READY`, and 8 of 8 loops had ended when the read at
  40 finished. By default, 0 of 8 had ended, and pidin shows no fs-9p thread at 40: fs-9p had
  handed the slot to the read at 40 (the run's fs-9p statistics count 1 slot handed over), so no
  thread waited for a slot when pidin ran; a label says so. The guest of this recording had 2
  processors. The same counts (8, 8 and 0 of 8) are in each of 5 runs per mode in
  `tests/logs/priority_20261113_024628.log` line 490 (a guest with 4 processors); the log of the
  recorded run is not in the repository. The narration carries the claim as the tests support it:
  inside the guest, a client is not delayed by lower-priority work, also while it waits for a
  request slot (tested with one slot and one low-priority reader). A label adds that QEMU's 9P
  server on the Linux host does not follow QNX priorities (QEMU is a Linux process; this part is
  not tested).
- Prompts are set to `host$` and `qnx#`. Cards and pictures (shots 4, 8, 9 and 13) are plain text,
  boxes and the repository's own `docs/architecture.png`, drawn for this video. No logos, no login
  banner, no browser pages, no music. The narration is a synthetic English voice reading the text
  in the table below; the same text is burned in as subtitles.

## Commands, in recorded order

| Shot | Shell | Commands |
|---|---|---|
| 3 | host, `qnx-share/demo` | `make hello` |
| 3 | guest, `/mnt/host/demo` | `./hello` |
| 3 | host | `sed -i 's/version 1/version 2/' hello.c`; `make hello` |
| 3 | guest | `./hello \| tee result.txt` |
| 3 | host | `cat result.txt` |
| 1 | host, `qnx-share` | `(cd oss-linux/libxml2-2.15 && ./testapi); echo "exit status $?"`; `(cd ci/libxml2-2.15 && qnx-run -e LD_LIBRARY_PATH=$PWD ./testapi); echo "exit status $?"` |
| 2, 10 | host, `qnx-share` | `ls cores`; `ntox86_64-gdb -batch -ix bt.gdb -ex bt ci/libxml2-2.15/testapi cores/testapi.core 2>&1 \| grep -E '^Program\|^#(8\|9\|10) ' \| uniq \| sed -E 's/0x[0-9a-f]{5,} (in )?//g'`; `sed -n 830p oss-src/libxml2-2.15/testapi.c; sed -n 2104p oss-src/libxml2-2.15/xmlreader.c` |
| 7 | host, repository | `demo/ci.sh fs9p-image qnx-share` |
| 6 | guest, `/` | `pidin -p fs-9p`; `pidin -p fs-9p -F '%a %n %U %W'`; `mount` |
| 12 | host, repository | `stdbuf -oL demo/priority.sh \| sed -un '/^### 3b/,$p' \| grep -E '^### 3b\|STATE\|fs9p/fs-9p\|^loops'` |
| 5 | host, fresh clone | `IMAGE=~/fs9p-image SHARE=~/qnx-share SSH_PORT=22360`; `make`; `tools/make-image.sh "$IMAGE" 2>&1 \| grep '^make-image'`; `tools/qnx-vm start "$IMAGE" "$SHARE" "$SSH_PORT"` |
| 11 | none (replay) | no command is shown; the replay script prints the files named in "How the footage was made" |

All shots were recorded on 2026-11-13. `hello.c` (written into
`qnx-share/demo` before shot 3) prints `Hello from <sysname>, version 1`.

## Shots

| # | Time | Picture | Heading | Narration (also the subtitles) |
|---|---|---|---|---|
| 1 | 0:00-0:07 | host, `qnx-share`: libxml2 v2.15.4's `testapi` from the Linux reference build ("exit status 0"), then the qcc build in the guest through `qnx-run` ("Memory fault (core dumped)", "exit status 139") | libxml2 v2.15.4's API test: the QNX guest exposed a latent libxml2 bug glibc did not show | The QNX guest exposed a latent libxml2 bug that the glibc run did not show. |
| 2 | 0:07-0:11 | host, `qnx-share`: `testapi.core` in `cores`; gdb: "Program terminated with signal SIGSEGV", "#8 xmlTextReaderErr (code=XML_ERR_ARGUMENT, msg=\"failed to open %s\") at xmlreader.c:196", "#9 xmlNewTextReaderFilename (URI=0x0) at xmlreader.c:2104", "#10 main (...) at testapi.c:830" | The core file lands in the shared folder; gdb on the host reads the backtrace | gdb on the host reads the backtrace from the core file. |
| 3 | 0:11-0:21 | two panes (host left, guest right), commands of shot 3: "Hello from QNX, version 1", then "version 2" | fs-9p: a host folder in a QNX 8.0 guest. Build on the host, run in the guest, no copying | fs-9p mounts a Linux host folder in the QNX guest, over virtio-9p. Build on the host, run in the guest, no copying. |
| 4 | 0:21-0:36 | `docs/architecture.png` (Linux host: make, ctest, tools/qnx-run; shared folder; QEMU with the virtio-9p device; QNX 8.0 guest: fs-9p process with resource manager, 9P2000.L client, virtqueue, virtio PCI transport; QNX programs that send open, read, write and stat as QNX messages) and a panel "Request slots" (src/virtq.c): "One slot per 9P request in flight; 16 by default (-n).", "Each slot has a mutex with PTHREAD_PRIO_INHERIT.", "A client that finds every slot taken blocks on a slot's mutex: the kernel runs the owner at that client's priority.", "The freed slot goes to the highest-priority waiter.", "-w turns this part off (as in 0.9.0), for comparison." | How fs-9p works: a resource manager, QNX message passing, request slots | In the guest, fs-9p is a resource manager; programs reach it through QNX message passing. Requests share 16 request slots; a client that waits for one lends its priority to the slot's owner. |
| 5 | 0:36-0:45 | host, fresh clone (window title: "Linux host: a fresh git clone (no build folder); the SDP environment was sourced before"): the commands of shot 5; `mkdir -p build` and 6 qcc lines; "make-image: ssh key for root logins: /home/dev/.ssh/id_ed25519.pub", "make-image: image ready in /home/dev/fs9p-image/output; ..."; "qnx-vm: QEMU started (pid ...); share /home/dev/qnx-share; ssh port 22360", "qnx-vm: ready: the guest answers on ssh and /mnt/host is mounted", "fs-9p 0.10.0: mount tag \"hostshare\" mounted at /mnt/host (... 16 request slots)"; label "waits shortened in this video" | Quick start in a fresh clone of the repository: the README's three commands | Quick start from a fresh clone: make, build the image once, start the VM; fs-9p mounts the shared folder. |
| 6 | 0:45-0:51 | guest shell: `pidin -p fs-9p` (6 threads of `system/bin/fs-9p`: `SIGWAITINFO`, `INTR`, `RECEIVE`), `pidin -F` (uid 1000, euid 1000), `mount` ("none on /mnt/host type 9p") | In the QNX guest: the fs-9p process (user 1000) with its threads, and /mnt/host in mount | pidin shows its threads, as user 1000; mount lists /mnt/host. |
| 7 | 0:51-1:14 | the output of `demo/ci.sh fs9p-image qnx-share` up to "== stop the VM": clone of cJSON v1.7.18, boot, project 1 qnx-unit ("100% tests passed, 0 tests failed out of 5", JUnit 5 test cases, 4 `.gcda`, "lines: 100.0% (92 out of 92)"), project 2 cJSON (22 tests, "100% tests passed, 0 tests failed out of 22", JUnit, 25 `.gcda`, "lines: 88.8% (1784 out of 2009)"), "RESULT: 2 project(s), 27 tests in the QNX guest with ctest, 0 failed"; label "waits shortened in this video" | Test machine: demo/ci.sh runs tools/qnx-ci.sh: boot, ctest in guest, JUnit, coverage | Hosted CI may not run the QNX SDP. On your own machine, demo/ci.sh boots the guest, runs each ctest suite in it, and stops it. qnx-unit: 5 of 5; coverage counters land in the shared folder, for gcovr. cJSON: 22 of 22; 27 tests in all, 0 failed. |
| 8 | 1:14-1:25 | table card "What cJSON's 22 tests need in the guest": you maintain: with scp "a runner script (108 lines, 77 of them code) and a hand-written list of 2 data folders (29 files)", with fs-9p "one CMake variable: CMAKE_CROSSCOMPILING_EMULATOR = tools/qnx-run"; one coverage run copies: "76 files in, 68 coverage files back", "nothing"; source line `demo/scp-run.sh`, `demo/scp-baseline.sh`, `tests/logs/scp_baseline_20261113_030937.log` lines 25-32 | none (card) | Over scp, these tests needed a runner script of 108 lines, 77 of them code. With fs-9p: one CMake variable, nothing copied. |
| 9 | 1:25-1:41 | table card "Seven open-source C libraries: their own tests", columns library, passed in the QNX guest, notes: zlib, libyaml, libdeflate, utf8proc 21 of 21 (built and run as released); check 0.15.2 2 of 2 (1,808 checks inside; timing-dependent self-tests off; 7 shell-script tests left out); libxml2 v2.15.4 7 of 8 (testapi crashed: the latent bug shown before; 14 script and catalog tests left out); libxml2 v2.13.5 7 of 8 (testapi crashed: a known bug, fixed upstream in v2.13.6); libuv v1.53.0 built, tests not run (builds with -lm added for its test programs; its test suite was not run); 7 suite runs of 6 libraries 37 of 39 (a ctest test is one run of a test program); source line `demo/oss-suite.sh` through `tools/qnx-ci.sh`, log `tests/logs/oss_20261113_031340.log` lines 222-237 | none (card) | Seven open-source C libraries, with their own test suites: 37 of 39 ctest tests pass in the guest. Both failures are libxml2 testapi crashes; libuv is built only. |
| 10 | 1:41-1:54 | the recording of shot 2 from the backtrace on: frames 8-10 and the two source lines; labels, one after the other: "frames 0-7 are not shown (libxml2's error functions and frames outside libxml2)", "cause in libxml2: a null pointer passed to %s, undefined behaviour in C", "observed; no public report found on 2026-11-13 (the same line is in libxml2's master branch)" | The libxml2 v2.15.4 crash: frames 8-10 of the backtrace and the two source lines | At xmlreader.c line 2104, libxml2 passes a null pointer to %s: undefined behaviour in C. We found no public report of it on 2026-11-13. |
| 11 | 1:54-2:10 | replay in three cuts (window title: "replay in 3 cuts: calls of TOOL_CALLS.md and the published files; long lines cut at the edge (…); nothing runs"): (a) call 1 (Read of `TASK.md`: "# Task: libxml2's test programs must pass in the QNX 8.0 guest"), call 7 ("exit 1"), call 8 and `logs/001-ci.txt` lines 1-34 ("2/8 Test #3: testapi ...***Failed", "88% tests passed, 1 tests failed out of 8", "-- testapi: crashed with SIGSEGV; core file testapi.core; ..."); (b) call 24 and `fix.diff` (`if (URI == NULL) {` ... `return(NULL);`); (c) call 27 ("exit 0" and its grep of `logs/002-ci.txt`: "19:2/8 Test #3: testapi ... Passed", "26:100% tests passed, 0 tests failed out of 8", "38:run.sh: tools/qnx-ci.sh exit status 0") | Replay of the recorded AI-agent session in examples/ai-agent-session-libxml2 | A replay: a fresh AI agent with a task file and fs-9p's tools. First guest run: 1 of 8 fails. The agent added one null check. Second guest run: all 8 test programs pass. |
| 12 | 2:10-2:26 | host, repository: the filtered output of `demo/priority.sh` part 3b for `-f`, `-w` and the default: pidin rows of fs-9p (with `-f` and `-w`: `40r CONDVAR` and `10r READY`; by default: `21f INTR` and `10r READY`) and "loops that had ended when the read at 40 finished: 8 of 8", "8 of 8", "0 of 8"; labels, one after the other: "waits shortened in this video", "default: no fs-9p thread waits at 40 here; fs-9p had handed the slot to the read at 40 (1 hand-over)", "QEMU's 9P server on the Linux host does not follow QNX priorities" | Live in the guest: a reader at 10 holds the only request slot; 8 loops at 30; a read at 40 | With the slot hand-over off (-f, -w), 8 of 8 loops end before that read; by default, 0 of 8. Inside the guest, a client is not delayed by lower-priority work, also while it waits for a request slot (tested with one slot and one low-priority reader; the last clause is in the subtitles only). |
| 13 | 2:26-2:37 | title card: "fs-9p", "a host folder inside a QNX 8.0 guest", "build on the host · run in QNX · no copy step", "7 open-source C libraries: 37 of 39 ctest tests passed in the guest · two libxml2 crashes traced", "guest test: 154 of 154 checks in each of 3 runs · CI run: 27 tests, 0 failed · Quick Start installer: 16 of 16", "AGENTS.md and qnx-run --json for coding agents · Apache-2.0 · link in the description" | none (card) | For teams that test C code on QNX 8.0: build on the host, run the tests in the guest. fs-9p is open source; the link is in the description. |

The counts on card 13 come from `tests/logs/oss_20261113_031340.log` (line 233), the passed checks in
`tests/logs/guest_tests_20261113_025442.log`, `_025938.log` and `_030430.log` (154 passed, 0 failed,
line 793 of each), the RESULT line of `tests/logs/ci_20261113_031200.log` (2 projects, 27 tests in the
guest, 0 failed, line 80) and the passed checks in `tests/logs/quickstart_20261113_031046.log` (16
passed, 0 failed, line 72). `AGENTS.md` and `tools/qnx-run --json` are checked by the guest test
steps "AGENTS.md" and "tools/qnx-run --json" of the same guest test logs
(`guest_tests_20261113_025442.log` lines 490-506). The two libxml2 crashes were traced the same
way: the guest wrote the core file into the shared folder, and `tools/qnx-ci.sh` put gdb's backtrace
into the test's JUnit entry (`tests/logs/oss_20261113_031340.log` lines 176-191 for v2.15.4;
`tests/logs/trace_libxml2_20261113_031313.log` line 75 for v2.13.5). The counts of shot 11 are in
`examples/ai-agent-session-libxml2/logs/001-ci.txt` line 26 (1 of 8 failed) and `logs/002-ci.txt`
lines 26 and 38 (0 of 8 failed; exit status 0).

## README picture

`docs/loop.gif` (1280x292, 155 frames of 120 or 130 ms, 19.4 s per loop; the last 3 s repeat the
final frame) is made from an earlier recording of the same loop (fs-9p 0.8.0, the same commands
as shot 3): the rendered terminal clip from 0.6 s to 17.0 s, cropped to the top 420 of 760 pixel
rows, scaled to 1280 pixels wide, 64-colour palette (ffmpeg `palettegen` and `paletteuse`). Its
right pane is a root shell in the guest over ssh.
