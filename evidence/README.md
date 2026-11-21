# Evidence: fs-9p builds and runs on QNX 8.0

These files are cleaned copies of output from QNX SDP 8.0 and a QNX 8.0 guest on QEMU (x86_64,
QEMU 6.2.0, KVM). They show that the project genuinely builds with `qcc` and runs on QNX 8.0. All
come from the full guest test of version 0.10.0, `tests/logs/guest_tests_20261113_025442.log`
(sources sha256 `ac061f948768`, computed by `tests/srchash.sh`).

| File | What it shows | Section of the test log |
|---|---|---|
| `build_qcc.txt` | the `qcc -Vgcc_ntox86_64` toolchain line (GCC 12.2.0), the QEMU version, and the six `qcc` commands of `make` without warnings | "build" |
| `guest_uname.txt` | `uname -a` of the guest: `QNX qnxqemu 8.0.0 ... x86pc x86_64`, and `id` (root) | "guest" |
| `driver_start_pidin.txt` | `fs-9p -d -v -U qnxuser`: the lines "running as uid 1000" and "mounted at /mnt/host" (interrupt thread base priority 21), `pidin` with user ID and effective user ID 1000, the driver's threads with their priorities and states, the two abilities of the non-root set (`io`, `priority`, locked), and the statistics lines at unmount | "option -U" |
| `priority_following.txt` | a reader at priority 40 next to CPU load at 30: with `-f` (fixed interrupt-thread priority 21) 24 completions came through the fallback wait in this run, by default the interrupt thread was set to 40 and 0 did; a reader at priority 8: by default the interrupt thread went down to 8, with `-f` it stayed at 21; a reader at 70 with `fs-9p -U qnxuser`: interrupt thread at 70, 0 failed priority changes; the same with `-U -P` (no priority ability): the pool thread ran at 63; a reader at 40 that waits for the one request slot (`-n 1`) held by a reader at 10: by default `pidin` shows the waiting server thread and the slot's owner at 40 (3 of 3 reads), and with 8 loops at 30 the read at 40 ended while all 8 loops still ran (0 of 8 ended); with `-w` (no priority inheritance through the slots, as in 0.9.0) and with `-f` it ended only after 8 of 8 loops had ended | "interrupt-thread priority under CPU load", "a client below the base priority", "a client above the maximum priority", "a reader at priority 40 waits for the request slot" |
| `supervisor_restart.txt` | `image/fs-9p-supervise`: after each of two `slay -9` a new fs-9p mounted the share without a typed command; with a limit of 2 restarts in 10 s the third kill was not followed by a restart and the reason was printed; a restart older than the window no longer counts | "image/fs-9p-supervise" |
| `qnx_run_ctest.txt` | `tools/qnx-run` on the host: `make qnx-test`, `make coverage` and `ctest` (CMake 3.31.6, `CMAKE_CROSSCOMPILING_EMULATOR`) run the unit tests of `examples/qnx-unit` (message passing, pulses, a ring buffer) inside the guest from the share; exit status 3 and stderr reach the host; JUnit files; the gcov runtime in the guest writes 3 `.gcda` files through the share, and gcovr on the host reports 83 of 83 lines of the three test files | "tools/qnx-run" |
| `symlinks_statvfs.txt` | symbolic links made on the host and in the guest: `lstat`, `stat`, `readlink`, `symlink`, `unlink`, a folder link inside a path, a target with `..`, a dangling link (ENOENT), a loop (ELOOP), an absolute target (`/dev/null`); `statvfs` against the host's `statfs`; a versioned shared library (`libx.so -> libx.so.1 -> libx.so.1.0`) loaded by the guest from the share | "symbolic links", "a versioned shared library" |
| `qnx_run_stop_json.txt` | `tools/qnx-run` stops a program that waits in `MsgReceive()` (and its child process) inside the guest: after the `-t 3` time limit (exit status 124, also when the program ignores SIGTERM, and when `-u qnxuser` runs it as uid 1000), after SIGINT (130) and SIGTERM (143) to `qnx-run`, and after ctest's `TIMEOUT` ended `qnx-run`; `pidin` then shows no such process; `--json` result lines, among them a program that exits with 124 by itself (`"timed_out":false`); the command block of `AGENTS.md` run as written (three JSON lines, ctest 5 of 5) | "tools/qnx-run stops the guest program", "tools/qnx-run --json", "AGENTS.md" |
| `core_dump.txt` | a program from the share crashes (exit status 139); the image's `dumper` writes `crash.core` through the share; `tools/qnx-run --json` names signal 11 (SIGSEGV) and the core file; `ntox86_64-gdb` on the host prints the backtrace | "core dumps through the share" |
| `oss_libxml2_testapi.txt` | not from the guest test: the cleaned output of `demo/trace-libxml2.sh` (`tests/logs/trace_libxml2_20261113_031313.log`): libxml2 v2.13.5 built with qcc, its `testapi` ended with SIGSEGV in the guest, the core file came through the share, and `tools/qnx-ci.sh` wrote the backtrace of `ntox86_64-gdb` into the JUnit entry: `xmlParseDTD("foo", NULL)` reaches `xmlSAX2ResolveEntity()` with `systemId=0x0`, which passes it to a `%s` format (`SAX2.c` line 432); pointer values replaced by ADDR; frames #0 and #3, which named a function of the QNX C library, replaced by "[frame in the QNX C library removed]", as in the trace log | trace log |
| `full_test_run.log` | the full test of version 0.10.0: 154 checks passed, 0 failed (each of the 3 runs on these sources passed all 154) | copy of the whole log |

"Fallback wait": a server thread that waits for the device looks at the used ring itself every
200 ms, in case the interrupt thread did not run. The 200 ms is a constant in `src/virtq.c`, not a
measurement; the logs count how many requests were completed that way. The count with `-f` differs
between runs, because it depends on how the scheduler places the loops and the reader. Counts with
`-f` and with following (default), by run:

| Run | With `-f` | Default |
|---|---|---|
| `tests/logs/priority_20261113_024628.log` (`demo/priority.sh`, 0.10.0, sources `ac061f948768`, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/guest_tests_20261113_025442.log` (guest test, 0.10.0, sources `ac061f948768`; this folder) | 24 | 0 |
| `tests/logs/guest_tests_20261113_025938.log`, `guest_tests_20261113_030430.log` (guest test, other runs on sources `ac061f948768`) | 8, 8 | 0, 0 |
| `tests/logs/history/priority_20261112_213520.log` (`demo/priority.sh`, 0.10.0, sources `08d95d90fd5c`, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_214337.log` (guest test, 0.10.0, sources `08d95d90fd5c`) | 8 | 0 |
| `tests/logs/history/guest_tests_20261112_214825.log`, `guest_tests_20261112_215318.log` (guest test, other runs on sources `08d95d90fd5c`) | 8, 8 | 0, 0 |
| `tests/logs/history/priority_20261112_142402.log` (`demo/priority.sh`, 0.10.0, sources `1180d3fa0c6d`, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_150230.log` (guest test, 0.10.0, sources `1180d3fa0c6d`) | 24 | 0 |
| `tests/logs/history/guest_tests_20261112_145745.log`, `guest_tests_20261112_145202.log`, `guest_tests_20261112_143157.log` (guest test, other runs on sources `1180d3fa0c6d`) | 8, 8, 24 | 0, 0, 0 |
| `tests/logs/history/priority_20261112_115215.log` (`demo/priority.sh`, 0.10.0, sources `dc2e6c148de2`, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_120009.log` (guest test, 0.10.0, sources `dc2e6c148de2`) | 24 | 0 |
| `tests/logs/history/priority_20261112_103702.log` (`demo/priority.sh`, 0.10.0, sources `e646d1b3c902`, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_104457.log` (guest test, 0.10.0, sources `e646d1b3c902`) | 8 | 0 |
| `tests/logs/history/priority_20261112_091154.log` (`demo/priority.sh`, 0.10.0 before `tools/qnx-ci.sh`, sources `ec45bd0e841f`, `RUNS=5`) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_091947.log` (guest test, 0.10.0, sources `ec45bd0e841f`) | 8 | 0 |
| `tests/logs/history/priority_20261112_075043.log` (`demo/priority.sh`, 0.9.0, `RUNS=5`, 27 requests per run) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_075316.log` (guest test, 0.9.0) | 24 | 0 |
| `tests/logs/history/priority_20261112_062015.log` (`demo/priority.sh`, 0.8.0, `RUNS=5`) | 24 in each of the 5 runs | 0 in each run |
| `tests/logs/history/guest_tests_20261112_062323.log` (guest test, 0.8.0) | 24 | 0 |
| `tests/logs/history/guest_tests_20261112_044842.log` (guest test, 0.7.0) | 8 | 0 |
| `tests/logs/history/priority_20261112_045153.log` (`demo/priority.sh`, 0.7.0, one run) | 24 of 27 | 0 of 27 |

Waiting for a request slot (0.10.0; fs-9p `-n 1` on a device whose reads QEMU throttles; a reader at 10
holds the only slot, 8 CPU-bound loops at 30 run, a reader at 40 reads 256 KiB): loops that had
ended when the read at 40 finished, of 8.

| Run | Default | `-w` (as in 0.9.0) | `-f` |
|---|---|---|---|
| `tests/logs/priority_20261113_024628.log` (`demo/priority.sh`, part 3b, 5 runs per mode, sources `ac061f948768`) | 0 in each run | 8 in each run | 8 in each run |
| `tests/logs/guest_tests_20261113_025442.log` (guest test, part B, sources `ac061f948768`; this folder; the 2 other guest runs on these sources gave the same counts) | 0 | 8 | 8 |
| `tests/logs/history/priority_20261112_213520.log` (`demo/priority.sh`, part 3b, 5 runs per mode, sources `08d95d90fd5c`) | 0 in each run | 8 in each run | 8 in each run |
| `tests/logs/history/guest_tests_20261112_214337.log` (guest test, part B, sources `08d95d90fd5c`; the 2 other guest runs on these sources gave the same counts) | 0 | 8 | 8 |
| `tests/logs/history/priority_20261112_142402.log` (`demo/priority.sh`, part 3b, 5 runs per mode, sources `1180d3fa0c6d`) | 0 in each run | 8 in each run | 8 in each run |
| `tests/logs/history/guest_tests_20261112_150230.log` (guest test, part B, sources `1180d3fa0c6d`; the 3 other guest runs on these sources gave the same counts) | 0 | 8 | 8 |
| `tests/logs/history/priority_20261112_115215.log` (`demo/priority.sh`, part 3b, 5 runs per mode, sources `dc2e6c148de2`) | 0 in each run | 8 in each run | 8 in each run |
| `tests/logs/history/guest_tests_20261112_120009.log` (guest test, part B, sources `dc2e6c148de2`) | 0 | 8 | 8 |
| `tests/logs/history/priority_20261112_103702.log` and `guest_tests_20261112_104457.log` (sources `e646d1b3c902`) | 0 in each run | 8 in each run | 8 in each run |
| `tests/logs/history/priority_20261112_091154.log` and `guest_tests_20261112_091947.log` (sources `ec45bd0e841f`) | 0 in each run | 8 in each run | 8 in each run |

Cleaning: the date and time with time zone in the first line of the test log were shortened to the
date. The files contain no measured times or throughput figures (configured constants such as the
200 ms above and the 10 s window of the restart test and the 2 s between SIGTERM and SIGKILL of `tools/qnx-run` do appear), no paths of the test machine, and
no host or account names of the test machine (checked with `grep`); paths of the shared folder and
the repository are printed as `SHARE` and `REPO`. `qnxqemu` is the default host name of the QNX
Quick Start image; `qnxuser` is its default user.
