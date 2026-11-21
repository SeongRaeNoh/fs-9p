# Tests and logs of fs-9p

Back to the [README](../README.md).

## The guest test

`tests/run_guest_tests.sh` runs from a developer machine. It copies the sources to the machine that
runs QEMU (settings in `tests/env.local`; see `tests/env.example`), runs `tests/host_side.sh` there
and saves the output in `tests/logs/`. The file checks compare what the guest did with what the
host sees; the other checks read `pidin` output, fs-9p's start-up and statistics lines, and exit
statuses. Each of the 3 runs of 0.10.0 on the final sources passed 154 of 154 checks (cited run:
`tests/logs/guest_tests_20261113_025442.log`, line 793). The test:

1. builds the six programs with `qcc` (fs-9p, the probe, and the guest programs `errno_test`, `attr_test`, `link_test`, `writers_test`);
2. creates a test tree in the shared folder: 191 files in 32 folders (nested 4 levels, names with
   spaces, one folder with 150 entries, a 12 MiB file, empty and 1-byte files, files of exactly one
   and one-plus-one read request);
3. runs the errno table test and the probe in the guest;
4. mounts the share with `fs-9p -d` and compares host and guest: file and folder lists, `cksum` of
   every file, `md5sum` of the 12 MiB file read whole, with `dd bs=7777` and with `tail -c`, a file
   size, "No such file or directory" for a missing file and folder, two readers and one `find` at
   the same time;
5. write operations: create, write and append, `O_TRUNC`, `cp` of the 12 MiB file into the share,
   nested `mkdir`, `mv` within and across folders, `rm`, `rmdir`, the errors "File exists", "Not a
   directory" and "No such file or directory", a host-made file seen in the guest;
6. builds a program with `qcc` into the share and starts it in the guest from `/mnt/host`;
7. symbolic links and `statvfs` with `tests/link_test.c`: links made on the host are seen by
   `lstat`, followed by `stat` and `open`, and read by `readlink`; a chain of two links, a folder
   link inside a path, a target with `..`, a dangling link (`ENOENT`), a loop (`ELOOP`, no hang), an
   absolute target (`/dev/null`); `symlink()` in the guest makes links on the host (`EEXIST` for an
   existing name); files and folders created through a folder link; `unlink` removes the link, not
   its target; `statvfs()` and `fstatvfs()` compared with the host's `statfs`;
8. a versioned shared library: `libx.so.1.0` (soname `libx.so.1`) with the links `libx.so.1` and
   `libx.so`, built with `qcc` into the share; a program linked with `-lx` starts from the share
   through `tools/qnx-run -e LD_LIBRARY_PATH=...` and also opens `libx.so` with `dlopen()`;
9. core files: the image's `dumper` folder is replaced by a link to `/mnt/host/cores`, a program
   built with `qcc -g` crashes in the guest (exit status 139 on the host through `tools/qnx-run`),
   `crash.core` appears in the host folder, `tools/qnx-run --json` with `QNX_CORE_DIR` names
   signal 11 (`SIGSEGV`) and the core file, `ntox86_64-gdb -batch -ex bt` on the host shows the
   frames with source lines, and the folder is put back (see
   [usage](usage.md#core-files-through-the-share));
10. attribute operations with `tests/attr_test.c`: `fsync`, `ftruncate`, `truncate`, `fchmod`,
   `chmod`, `utime`, `utimes`, `utime(NULL)`, `chown` and `chgrp` to the host user's own ids, and
   `chown` to root (refused by the host: "Operation not permitted");
11. robustness: two `cp` of 24 MiB files at the same time, one `write()` of 100 MiB, 2,000 files
   created, listed, read and removed, a path of depth 20, forked writers killed while they write
   (below), three cycles of mount and unmount, and a driver restart while a client holds a file open;
12. `image/fs-9p-supervise`: after each of two `slay -9` a new fs-9p mounts the share without a typed
   command; with the limit set to 2 restarts in 10 s, the third kill is not followed by a restart and
   the supervisor prints why; with 1 restart in 10 s, a restart older than 10 s no longer counts;
13. `tools/qnx-run` (step before the unmount): a guest command with its output and exit status;
    `make qnx-test` and `ctest` on the host run the 5 unit tests of `examples/qnx-unit` in the guest
    from the share; exit status 3 and stderr of a guest program reach the host; JUnit files (ctest
    needs `CMAKE_ENV` with CMake 3.21 or newer, see `tests/env.example`); `make coverage`: the tests
    built with gcov counters run in the guest, the 3 `.gcda` files appear in the host build folder
    through the share, and gcovr (setting `GCOVR`) or the SDP's gcov reports on the host;
14. `tools/qnx-run` stops the guest program (6 checks): `stuck_receive fork` (two processes that
    wait in `MsgReceive()`) under `-t 3` returns 124 and leaves 0 processes, also when the program
    ignores SIGTERM and when `-u qnxuser` runs both processes as uid 1000; SIGINT and SIGTERM to `qnx-run` return 130 and 143 with 0 left; ctest
    `TIMEOUT 5` ends `qnx-run`, and the guest then stops both processes (0 left); details in
    [usage](usage.md#toolsqnx-run);
15. `tools/qnx-run --json` (3 checks): the JSON line of a program that exits with 3, and of
    `stuck_receive` under `-t 2` (`timed_out` true, status 124), parsed with Python's `json`; a
    program that exits with 124 by itself gives `timed_out` false without `-t` and with `-t 60`,
    and its JUnit file (`-j`) names an exit-status failure, not a timeout;
16. `AGENTS.md`: the marked command block of `AGENTS.md` runs as written from the repository root
    (3 checks: three JSON lines with the expected fields, `ctest` with `tools/qnx-run;-t;60` as
    emulator 5 of 5, no `stuck_receive` left);
17. option `-p` (polling): `cksum` of all files, a 12 MiB copy, 0 interrupts in the statistics;
18. option `-n 64`: 64 `md5sum` processes read the 12 MiB file at the same time, and more than 16
    requests were in flight at once;
19. option `-U qnxuser`: `pidin` shows the user ID and the two locked abilities of the non-root
    set; `cksum` of all files, a write, `mkdir` and `mv` work; 0 fallback-wait completions;
20. interrupt-thread priority: eight CPU-bound loops at priority 30 and a reader at priority 40,
    once with `-f` and once by default (more than 0 fallback-wait completions with `-f`, 0 by
    default, interrupt thread at 40; counts of every run under "Fallback counts by run" below); a
    reader at priority 8 (by default the interrupt thread goes
    down to 8, with `-f` it stays at 21); then fs-9p as `qnxuser` with a reader at priority 70 and
    loops at 65, once with the `priority` ability (pool and interrupt thread at 70, the read
    finishes while all loops run) and once with `-P` (pool thread at 63, the read finishes only
    after loops have ended);
21. request slots (runs only when `SLOW_SHARE` is set; needs a VM with a third virtio-9p device
    whose reads QEMU throttles, settings `SLOW_SHARE` and `SLOW_TAG` in `tests/env.example`):
    `fs-9p -n 1` on that device, a reader at priority 10 holds the one request slot, and a reader
    at priority 40 waits for it; by default, with `-w` and with `-f`. Part A (no load): by default
    a thread of fs-9p waited on the slot's mutex during 3 of 3 reads at 40 and `pidin` showed the
    waiting thread and the slot's owner at 40 (`40r`/`40r`); with `-w` no thread waited on a slot
    mutex (0 of 3). Part B (8 loops at priority 30): by default the interrupt thread was raised to 40 and the read
    at 40 ended while all 8 loops ran (0 of 8 ended); with `-w` and with `-f` it ended only after
    8 of 8 had ended; 1 slot handed over by default, 0 with `-w` and `-f` (4 checks, `tests/logs/guest_tests_20261113_025442.log` lines 647-717);
22. two devices (needs `SHARE2`, see `tests/env.example`): a second folder as a modern-only device
    with mount tag `share2`; one fs-9p instance per device (`-a`); the write and attribute tests
    over the virtio 1.x interface; 0 fallback-wait completions;
23. `-a` with a mount tag that no device has: error message, exit status 1;
24. a read-only mount with the virtio 1.x interface (`-r -t modern`): checksums, concurrent
    readers, "Read-only file system" for write, mkdir, rm, mv, chmod, chown and touch, host tree
    unchanged.

**Forked writers, some killed** (step 11; `tests/writers_test.c`; 7 checks, `tests/logs/guest_tests_20261113_025442.log`
lines 241-281). The parent process creates one file in the share and forks the writers. Each writer
writes 64-byte records, one `write()` per record, either through the descriptor it inherited (one
open file and one file offset for all writers) or through its own `O_APPEND` descriptor. The
writers start together, and the parent sends SIGKILL to some of them while they write. The parent
then reads the file back through the share and checks: every record whole and correct, none twice,
each writer's records in order and without a gap, all records of every writer that exited
normally, no failed `write()`, and the host's md5 of the file equal to the guest's. Four rounds,
each one check: 100 writers with 50 records each and 40 kills, and 200 writers with 20 records each
and 100 kills, each in both modes. Three more checks: writers were killed while writing (136 in the
4 rounds of the cited run, 136 and 141 in the other two runs; line 278 of each log), fs-9p then
creates, writes and reads a new file, and at the unmount fs-9p's line "request slots at unmount"
reports 16 of 16 slots free, 0 lost and 0 requests in flight (line 280).

A **fallback wait** is fs-9p's guard against a lost or late interrupt: a server thread that waits
for the device looks at the used ring itself every 200 ms. The 200 ms is a constant in
`src/virtq.c`, not a measurement. A "fallback-wait completion" is a request that this check, not
the interrupt thread, completed (counter "reaped by waiters" in fs-9p's statistics line).

The test logs in to the guest as root over ssh (`GUEST_SSH` in `tests/env.example`). An image that
`tools/make-image.sh` builds puts the user's public key into the image for that login; a Quick
Start Target Image needs the one-time key setup of [usage](usage.md#qnx-80-quick-start-target-image).

## Other test scripts

- `make host-check` builds and runs, with the host's C compiler and without the QNX SDP, three
  programs with AddressSanitizer and UndefinedBehaviorSanitizer: `tests/host/p9_test.c` (84 table
  checks of the 9P2000.L codec in `src/p9.c`: the bytes of all 18 request types, the decoded fields
  of the replies, malformed replies, every proper prefix of every valid reply body, walks of more
  than 16 names, msize, the fid pool), `tests/host/p9_fuzz.c` (200000 replies from a seeded
  generator, mutated valid replies and random bytes, against invariants on return values and
  directory entries) and `tests/errno_test.c`. `tests/host/fake_virtq.h` stands in for the
  virtqueue, so `src/p9.c` builds unchanged on Linux; each reply buffer has exactly the length of
  the reply, so a read past it stops the run. `.github/workflows/host-tests.yml` runs the same
  target on GitHub Actions with no SDP (the SDP licence rules out hosted CI); it has not run on
  GitHub yet, because the repository is not public yet. The table test and the
  fuzz run found two input checks missing in `src/p9.c`, both fixed: an `Rlerror` reply shorter than
  its 4-byte code was read as an error number, and after an `Rwalk` with more qids than names
  `p9_walk_ex()` reported that count as the number of names walked (its caller in `src/fs9p.c` uses
  the number only when it is smaller than the number of names). Log: `tests/logs/host_check_20261113_024556.log`.
- `tests/readme_run.sh` runs the two marked blocks of the README quick start unchanged with `bash`,
  then checks, through `tools/qnx-run`: the image and `build/fs-9p` exist; `tools/qnx-vm start`
  returned ready; the boot line of fs-9p 0.10.0; `tools/qnx-run` of a program built on the host;
  `make qnx-test`; guest read and host read of each other's files; `pidin` user 1000 and the two
  locked abilities; after `slay -9 fs-9p` a new fs-9p (also uid 1000) mounts `/mnt/host` again, a
  descriptor opened before the kill fails, a new open reads the file, the console shows the
  supervisor's "restart 1" line; `tools/qnx-vm status` and `stop` (17 checks,
  `tests/logs/readme_run_20261113_031028.log`, line 157). The console is printed through a whitelist, so no
  boot messages of the image reach the log.
- `tests/quickstart_test.sh` checks `tools/add-to-quickstart.sh` on a private copy of a QNX 8.0
  Quick Start Target Image (a qcow2 overlay; the image is only read): key setup on the serial
  console, two runs of the script (one block only), a second boot with `/mnt/host` mounted and
  fs-9p as uid 1000 without a typed command, an automatic restart after `slay -9`, and `--remove`
  (the boot script has its old checksum) (16 checks, `tests/logs/quickstart_20261113_031046.log`, line 72).

## Logs

| Log | What it shows |
|---|---|
| `tests/logs/guest_tests_20261113_025442.log` | the full test above: 154 checks passed, 0 failed (line 793). All 3 runs of the guest test on sources `ac061f948768`, each on a newly booted guest, passed 154 of 154 (this one, `guest_tests_20261113_025938.log`, `guest_tests_20261113_030430.log`; last line of each). The 7 checks of the forked-writers step are new since the sources `352c129bfa44` and `08d95d90fd5c`, whose 3 runs each passed 147 of 147. Of the 4 runs on the sources `1180d3fa0c6d`, 2 had failed one check each ("part B by default", "SIGTERM unmount with an open fd"); both checks were changed in the test, not in the driver: part B by default now requires the interrupt thread at 40 (the count of fallback completions is printed, not required), and the open-fd scenarios keep the descriptor in a holder process that does not fork. |
| `tests/logs/readme_run_20261113_031028.log` | `tests/readme_run.sh`: 17 checks passed, 0 failed (line 157) |
| `tests/logs/quickstart_20261113_031046.log` | `tests/quickstart_test.sh`: 16 checks passed, 0 failed (line 72) |
| `tests/logs/workflow_20261113_025417.log` | `demo/workflow.sh`: edit, build and run without copying the program, then the same run with `tools/qnx-run` |
| `tests/logs/priority_20261113_024628.log` | `demo/priority.sh` with `RUNS=5`: `pidin` while a reader at priority 40 waits (interrupt thread at 21 with `-f`, at 40 by default; lines 22, 47); the fallback-wait counts under CPU load in 5 runs (24 of 27 requests with `-f` in each run, 0 of 27 by default in each run; line 488); part 3, the request slot of `fs-9p -n 1` (3a: 3 of 3 reads at 40 waited on the slot's mutex, waiting thread and slot's owner at `40r`/`40r`, line 489; 3b: loops that had ended when the read at 40 finished, 8 of 8 with `-f` and with `-w` and 0 of 8 by default in each of 5 runs, line 490; 1 slot handed over by default in each run, md5 equal in all 15 runs, line 491) |
| `tests/logs/bisect_20261113_025421.log` | `demo/bisect.sh`: `git bisect run` with `tools/qnx-run` finds the planted commit (8 commits, 3 built and run in the guest; line 95) |
| `tests/logs/cjson_20261113_030926.log` | `demo/cjson.sh` with `COVERAGE=1`: cJSON v1.7.18's own tests in the guest, 22 of 22 test programs passed (158 Unity test cases, 0 failures, 1 ignored; lines 46, 48); coverage of `cJSON.c` 1223 of 1384 lines (88 %) and 703 of 922 branches (76 %) (lines 82, 86) ([real-project.md](real-project.md)) |
| `tests/logs/scp_baseline_20261113_030937.log` | `demo/scp-baseline.sh`: the same 22 tests through an `scp` runner, 22 of 22 in a plain run and in a coverage run (lines 12, 17); per run 76 files copied into the guest, 68 `.gcda` files copied back in the coverage run (lines 25, 26); fs-9p 0 and 0 (line 30; "Demos" below) |
| `tests/logs/ci_20261113_031200.log` | `demo/ci.sh`: `tools/qnx-ci.sh` boots the guest, runs `ctest -j 1 --output-junit` (coverage on: one test at a time, line 9) on `examples/qnx-unit` and cJSON v1.7.18 in the guest (5 of 5 and 22 of 22 passed, lines 26, 68; 1 test started before the first one ended, lines 28, 70), counts the JUnit files (5 and 22 test cases, 0 failures, lines 29, 71), runs gcovr (qnx-unit 92 of 92 lines and 58 of 98 branches, lines 31-32; cJSON 1784 of 2009 lines and 1079 of 1372 branches, lines 73-74; `cJSON.c` 1223 of 1384 lines, line 76, as in the serial cJSON run) and stops the guest (line 86). The 3 CI logs of the sources `352c129bfa44` (`tests/logs/history/ci_20261113_011643.log`, `ci_20261113_011733.log`, `ci_20261113_014647.log`) have the same counts in lines 31-32 and 73-77: 4 of 4 runs with one test at a time gave the same line and branch counts. Earlier runs with `ctest -j 4` and coverage had given different line counts of `cJSON_Utils.c` between runs (cause not checked). |
| `tests/logs/oss_20261113_031340.log` | `demo/oss-suite.sh`: eight open-source C projects at fixed tags (seven libraries; libxml2 in two versions; libuv only built), built with qcc, their own ctest suites in the guest through `tools/qnx-ci.sh` and on Linux as a check of each suite; counts per project in the table of section 5 (lines 219-233): 37 of 39 ctest tests passed in the guest; [oss-suite.md](oss-suite.md) |
| `tests/logs/oss_20261113_031620.log` | `demo/oss-suite.sh` with `OSS_QNX_OPTS=0` on check and libxml2: the QNX builds without the QNX-only CMake options fail (lines 90, 107-108; [oss-suite.md](oss-suite.md#build-changes-and-upstream-status)) |
| `tests/logs/trace_libxml2_20261113_031313.log` | `demo/trace-libxml2.sh`: libxml2 v2.13.5 built with qcc, `testapi` in the guest through `tools/qnx-ci.sh`, its core file through the share, gdb's backtrace in the JUnit entry (frame 11: `xmlSAX2ResolveEntity (... systemId=0x0) at .../SAX2.c:432`, line 75), the libxml2 source line of each frame (lines 87-100), 4 of 4 checks (line 107) |
| `tests/logs/ci_crash_20261113_031252.log` | `demo/ci-crash.sh`: `tools/qnx-ci.sh` on `examples/ci-crash`; the crashed test's JUnit entry holds the backtrace `read_value (eq=0x0)`, `parse_record`, `main` with file and line (lines 54-58); the test that failed without a crash and the passing test whose child crashed on purpose get none; 6 of 6 checks (line 88) |
| `tests/logs/host_check_20261113_024556.log` | `make host-check` with host gcc, no SDP: 84 table checks of the 9P codec (line 97), 200000 fuzz inputs with no sanitizer report (lines 100, 117), the errno table on Linux (line 158) |
| `examples/ai-agent-session/logs/reader_scripts_20261112_062802.txt` | the example's published `run_tests.sh` and `qrun.sh` run on QNX: 2 of 3 tests passed, then 3 of 3 after `patch -p1 < fix.diff` (run with the `tools/qnx-run` of 0.8.0; not run again since then) |

The sixteen logs in `tests/logs/` (the fourteen above and the two other guest-test runs named in the
first row) were made from the same sources of version 0.10.0 (sha256 `ac061f948768` in their first
lines; `tests/srchash.sh` computes it). The 106 logs of earlier sources are kept as history in
`tests/logs/history/`; their first lines name their sources. Sixteen are from
sources `352c129bfa44`: the same steps with three guest-test runs and three CI runs (described
above), before the forked-writers step of the guest test, fs-9p's "request slots at unmount" line
and the current project rows of `demo/oss-suite.sh` (with check's option
`-DCHECK_ENABLE_TIMEOUT_TESTS=OFF`) were added. Fourteen are the same steps from sources
`08d95d90fd5c` with three guest-test runs, before `tools/qnx-ci.sh` ran one test at a time with
coverage on. Fifteen are the same steps from sources `1180d3fa0c6d` with four guest-test runs
(described above), before the changed guest checks, the `-u` options of `tools/qnx-run` and
`tools/qnx-ci.sh`, the `--timeout` and `--build-only` options and the libxml2 v2.15.4 and libuv
v1.53.0 rows were added. Nine are the same runs from sources `dc2e6c148de2`, before the host-only
tests, the backtraces of `tools/qnx-ci.sh`, `demo/ci-crash.sh` and `demo/trace-libxml2.sh` were
added. The `oss_` logs of the open-source suites on sources before `ac061f948768` are no longer in
this repository. Nine of them are the same
runs from sources `e646d1b3c902`, before `demo/oss-suite.sh`, the test routing of `tools/qnx-ci.sh` and
the find root path of `examples/qnx-unit/qnx-x86_64.cmake` were added. Eight of them are the same
runs of 0.10.0 from sources `ec45bd0e841f`: the sources without `tools/qnx-ci.sh` and `demo/ci.sh`
(the file list of `tests/srchash.sh` without these two files gives `ec45bd0e841f`). The other 35
are from versions 0.1.0 to 0.9.0. `demo/cjson.sh` prints the hash in line 1 since 0.9.0; in the 0.8.0 cJSON log
(`cjson_20261112_062615.log`) line 2 was added after the run and says so. Five older logs carry a
marker where lines were removed after the run: image boot or login messages
(`readme_run_20261111_192556.log`, `readme_run_20261111_205414.log`,
`readme_run_20261111_221010.log`), a login message of the build machine
(`workflow_20261111_192348.log`) and a timing line (`guest_tests_20261111_192257.log`). In the
0.7.0 workflow log, four copies of the build machine's ssh login banner, which ssh printed between
output lines, were removed; since 0.8.0 the scripts keep that banner out of the logs (`ssh -q`, and
stderr joined in the guest). In the README-run logs from `readme_run_20261111_221010.log` on, the
wrapper that ran the script printed one path of the SDP installation as `<QNX>/...`.
`demo/oss-suite.sh` and `tools/qnx-ci.sh` print that path as `<QNX>` and delete old JUnit files
before a run. The current `oss_` and `trace_libxml2_` logs were not edited after their run, except
for two kinds of lines. Two lines of `oss_20261113_031620.log` (40 and 46) were edited: the
compiler quoted one line of an SDP header in each, and both were replaced by a marker because the
licence does not allow SDP text in this repository.
Lines 135, 137, 181 and 183 of `oss_20261113_031340.log`, lines 33, 35, 65 and 67 of
`trace_libxml2_20261113_031313.log` and the same four lines of the three `trace_libxml2_` logs in
`tests/logs/history/` named a function of the QNX C library as frame #0 or #3 of a `testapi`
backtrace and were replaced by "[frame in the QNX C library removed]", because this repository
publishes no result of a functional evaluation of a QNX component.

`evidence/` holds cleaned copies of parts of the 0.10.0 guest test
(`tests/logs/guest_tests_20261113_025442.log`): the build output, the guest's `uname -a`, the
driver's start-up output with `pidin`, the priority tests with the request-slot step
(`priority_following.txt`), the supervisor test, the
`tools/qnx-run` step with coverage, the stop, `--json` and `AGENTS.md` steps
(`qnx_run_stop_json.txt`), symbolic links and `statvfs`, the core file in gdb, and the whole log
(`evidence/README.md`). The logs contain no measured times; configured constants appear, such as
the 200 ms of the fallback wait, the restart window of the supervisor test and the 2 s between
SIGTERM and SIGKILL of `tools/qnx-run`.

### Fallback counts by run

The count of fallback-wait completions with `-f` depends on how the scheduler places the loops and
the reader, so it differs between runs; with following (default) it was 0 in every run.

| Run | With `-f` | Default |
|---|---|---|
| `tests/logs/priority_20261113_024628.log` (`demo/priority.sh`, 0.10.0, sources `ac061f948768`, `RUNS=5`, 27 requests per run; line 488) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/guest_tests_20261113_025442.log` (guest test, 0.10.0, sources `ac061f948768`; line 610) | 24 | 0 |
| `tests/logs/guest_tests_20261113_025938.log`, `guest_tests_20261113_030430.log` (guest test, other runs on sources `ac061f948768`; line 610) | 8, 8 | 0, 0 |
| `tests/logs/history/priority_20261113_012114.log` (`demo/priority.sh`, 0.10.0, sources `352c129bfa44`, `RUNS=5`, 27 requests per run; line 489) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261113_012937.log`, `guest_tests_20261113_013429.log`, `guest_tests_20261113_013921.log` (guest test, 0.10.0, sources `352c129bfa44`; line 567) | 24, 8, 24 | 0, 0, 0 |
| `tests/logs/history/priority_20261112_213520.log` (`demo/priority.sh`, 0.10.0, sources `08d95d90fd5c`, `RUNS=5`, 27 requests per run; line 489) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_214337.log` (guest test, 0.10.0, sources `08d95d90fd5c`; line 567) | 8 | 0 |
| `tests/logs/history/guest_tests_20261112_214825.log`, `guest_tests_20261112_215318.log` (guest test, other runs on sources `08d95d90fd5c`; line 567) | 8, 8 | 0, 0 |
| `tests/logs/history/priority_20261112_142402.log` (`demo/priority.sh`, 0.10.0, sources `1180d3fa0c6d`, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_150230.log` (guest test, 0.10.0, sources `1180d3fa0c6d`) | 24 | 0 |
| `tests/logs/history/guest_tests_20261112_145745.log`, `guest_tests_20261112_145202.log`, `guest_tests_20261112_143157.log` (guest test, other runs on sources `1180d3fa0c6d`) | 8, 8, 24 | 0, 0, 0 |
| `tests/logs/history/priority_20261112_115215.log` (`demo/priority.sh`, 0.10.0, sources `dc2e6c148de2`, `RUNS=5`, 27 requests per run; line 488) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_120009.log` (guest test, 0.10.0, sources `dc2e6c148de2`; line 556) | 24 | 0 |
| `tests/logs/history/priority_20261112_103702.log` (`demo/priority.sh`, 0.10.0, sources `e646d1b3c902`, `RUNS=5`, 27 requests per run; line 489) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_104457.log` (guest test, 0.10.0, sources `e646d1b3c902`; line 556) | 8 | 0 |
| `tests/logs/history/priority_20261112_075043.log` (`demo/priority.sh`, 0.9.0, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_075316.log` (guest test, 0.9.0) | 24 | 0 |
| `tests/logs/history/priority_20261112_062015.log` (`demo/priority.sh`, 0.8.0, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_062323.log` (guest test, 0.8.0) | 24 | 0 |
| `tests/logs/history/guest_tests_20261112_044842.log` (guest test, 0.7.0) | 8 | 0 |
| `tests/logs/history/priority_20261112_045153.log` (`demo/priority.sh`, 0.7.0, one run) | 24 of 27 | 0 of 27 |

## Demos

`demo/workflow.sh` runs from the developer machine with the settings of `tests/env.local`. It
writes `hello.c` into the shared folder, builds it on the host with `qcc`, runs `./hello` in the
guest from `/mnt/host/demo`, edits the source, builds and runs again, lets the guest write a result
file that the host reads, and runs the program once more with `tools/qnx-run` on the host.
`demo/record_loop.sh` records the same loop in two real terminals for the picture at the top of the
README; `demo/render_frames.py` draws the saved terminal text unchanged.

`demo/ci.sh` is the team example of the README: it clones cJSON into the share and runs
`tools/qnx-ci.sh` on `examples/qnx-unit` and cJSON, which boots the guest, runs both test suites
with `ctest -j 1 --output-junit` (one test at a time while coverage is on), writes gcovr reports and
stops the guest
([usage](usage.md#a-teams-test-machine-toolsqnx-cish)).

`demo/priority.sh` shows with `pidin` how fs-9p passes a client's priority on to its interrupt
thread. Part 1 starts a reader at priority 40 and runs `pidin` while the reader waits: the reader
is REPLY-blocked on fs-9p, the fs-9p server thread runs at 40 (QNX message passing), and the
interrupt thread (state `INTR`) is at its base priority 21 with `-f` and at 40 by default. A read
request must stay in flight long enough for `pidin`, so part 1 uses a third virtio-9p device whose
reads QEMU throttles (`-fsdev local,id=fs2,path=SLOW_SHARE,security_model=none,throttling.bps-read=262144`
and `-device virtio-9p-pci,fsdev=fs2,mount_tag=slow`; settings `SLOW_SHARE` and `SLOW_TAG` in
`tests/env.local`). Part 2 repeats the CPU-load step of the guest test (8 loops at priority 30) and
prints fs-9p's statistics lines: counts and priorities, no measured times. `RUNS=N` repeats part 2
N times; the summary then lists the count of every run and the range. Part 3 starts
`fs-9p -n 1` (one request slot) on the throttled device, and a reader at priority 10 holds the
slot: part 3a runs `pidin` while a reader at priority 40 waits for the slot (by default the waiting
server thread is blocked on the slot's mutex, and the slot's owner runs at 40); part 3b starts 8
loops at priority 30 and then a read at 40, with `-f`, `-w` and by default, and counts the loops
that had ended when the read finished, the slots handed over and the fallback-wait completions
(`RUNS=N` repeats part 3b N times per mode).

`demo/bisect.sh` runs on the machine with the SDP and the running guest. It makes a git history of
8 commits of a portable C file; commit 5 drops a test for `ENOTSUP` because `ENOTSUP` and
`EOPNOTSUPP` are the same value on Linux with glibc. A small program in the demo prints that they
are two different values in the QNX guest, so the unit test fails on QNX from commit 5 on, while
the Linux build of the same test passes. `git bisect run` builds each step with `qcc` and runs the test in the guest
with `tools/qnx-run`, and names commit 5 as the first bad commit.

`demo/cjson.sh FOLDER` runs on the machine with the SDP and the running guest; `FOLDER` must be
inside the shared folder. It clones cJSON (tag `v1.7.18` by default), changes the three `add_test`
lines of the clone so that `ctest` uses the emulator, builds with `qcc` through CMake, and runs
`ctest` with `tools/qnx-run` as `CMAKE_CROSSCOMPILING_EMULATOR`. With `COVERAGE=1` it builds again
with gcov counters, runs the tests again in the guest and reports the coverage of `cJSON.c` and
`cJSON_Utils.c` with gcovr over the `.gcda` files of all test programs. It prints counts only, no
times and no output of failing tests ([real-project.md](real-project.md)).

`demo/scp-baseline.sh WORK_DIR` counts what a test runner without the shared folder must copy,
on the same cJSON tests; `WORK_DIR` must be outside the shared folder. The script clones and builds
cJSON as `demo/cjson.sh` does (same tag, same three changed lines) and runs `ctest` twice, plain and
with gcov counters, with `demo/scp-run.sh` as `CMAKE_CROSSCOMPILING_EMULATOR`. For every test run,
`demo/scp-run.sh` copies with `scp` the program, the shared libraries that it needs from the
folders of `LD_LIBRARY_PATH` (`NEEDED` entries read with `ntox86_64-readelf`), and the data folders
written by hand for 2 of the 22 programs into a new guest folder, and runs the program there over
ssh; in the coverage run it copies back every `.gcda` file whose checksum the run changed. Each
copy and each translated path is one line in the runner's own log, and the script counts these
lines. Settings: `SCP_RUN_SSH` and `SCP_RUN_SCP` (the commands for the guest login and the copy).
Counts and results: [real-project.md](real-project.md#compared-with-an-scp-runner) and
`tests/logs/scp_baseline_20261113_030937.log`.
