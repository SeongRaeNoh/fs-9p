# Evidence: the logs behind the README

Back to the [README](../README.md). This page names the log of each number in the README and holds
the longer results that the README links to: the QNX technologies and their tests, the priority
results, the many-writers test, the planted demonstrations and the comparison with other ways to
share files.

## Logs

The logs come from sources sha256 `ac061f948768` (first lines) and hold counts, no measured times.

| File | What it shows (lines) |
|---|---|
| [`tests/logs/oss_20261113_031340.log`](../tests/logs/oss_20261113_031340.log) | `demo/oss-suite.sh`: the table of the eight suite rows and the totals (219-233), check's 1,808 checks (232), the 2 tests that failed in the guest (235-237), the backtraces of `testapi` in libxml2 v2.13.5 (130-152) and v2.15.4 (176-191), check's build options (96) and its shell-script tests left out (100), the `dlopen()` check of v2.15.4 (240-241), libuv built and not run (193-197); without the QNX-only build options, check and libxml2 v2.13.5 do not build ([`tests/logs/oss_20261113_031620.log`](../tests/logs/oss_20261113_031620.log), 90, 107-108) |
| [`tests/logs/trace_libxml2_20261113_031313.log`](../tests/logs/trace_libxml2_20261113_031313.log) | `demo/trace-libxml2.sh`: libxml2 v2.13.5 built with qcc, `testapi` in the guest, its core file through the share, the gdb backtrace in the JUnit entry (frame 11: `SAX2.c:432`, `systemId=0x0`; 75), the libxml2 line of each frame (87-100), 4 of 4 checks (107); cleaned copy: [`evidence/oss_libxml2_testapi.txt`](../evidence/oss_libxml2_testapi.txt) |
| [`tests/logs/ci_crash_20261113_031252.log`](../tests/logs/ci_crash_20261113_031252.log) | `demo/ci-crash.sh`: of 4 tests, the one that crashed got the backtrace in its JUnit entry (`read_value (eq=0x0)`, 56), the one that failed without a crash and the one whose child crashed on purpose did not; 6 of 6 checks (88) |
| [`tests/logs/host_check_20261113_024556.log`](../tests/logs/host_check_20261113_024556.log) | `make host-check`, host gcc, no SDP: 84 table checks of the 9P codec (97), 200000 fuzz inputs (100, 117), the errno table (158) |
| [`tests/logs/ci_20261113_031200.log`](../tests/logs/ci_20261113_031200.log) | `demo/ci.sh`: one test at a time with coverage on (9), qnx-unit 5 of 5 (26), JUnit file (29), cJSON 22 of 22 (68), line and branch counts (31-32, 73-77), 2 projects and 27 tests with 0 failed (80), guest stopped (86) |
| [`tests/logs/cjson_20261113_030926.log`](../tests/logs/cjson_20261113_030926.log) | `demo/cjson.sh` (serial ctest): 3 changed lines of cJSON's CMake files (14), 22 of 22 (46), 158 Unity test cases (48), `cJSON.c` 1223 of 1384 lines (82) and 703 of 922 branches (86) |
| [`tests/logs/scp_baseline_20261113_030937.log`](../tests/logs/scp_baseline_20261113_030937.log) | `demo/scp-baseline.sh`: 25 `.gcda` files (19), 76 copies of 53 distinct files in and 68 back (25-26), fs-9p 0 and 0 (30), 22 of 22 in both runs (32) |
| [`tests/logs/guest_tests_20261113_025442.log`](../tests/logs/guest_tests_20261113_025442.log) | the full guest test: 154 passed, 0 failed (793; each of the 3 runs on these sources passed all checks, [testing](testing.md#logs)); steps on forked writers killed with SIGKILL (241-281), core files (163), stopping hung tests (451), `--json` (490), `AGENTS.md` (506), non-root mode (569) |
| [`tests/logs/priority_20261113_024628.log`](../tests/logs/priority_20261113_024628.log) | `demo/priority.sh`, 5 runs per mode: interrupt thread at 21 or 40 (486), fallback waits 24 of 27 and 0 of 27 (488), loops ended 8, 8 and 0 of 8 (490) |
| [`tests/logs/bisect_20261113_025421.log`](../tests/logs/bisect_20261113_025421.log) | `demo/bisect.sh`: first bad commit after 3 of 8 commits (95-96) |
| [`tests/logs/readme_run_20261113_031028.log`](../tests/logs/readme_run_20261113_031028.log) | the README quick start run as written, then `tools/qnx-run`, `pidin`, kill and automatic restart: 17 of 17 (157); the loop of the README picture as a script: [`workflow_20261113_025417.log`](../tests/logs/workflow_20261113_025417.log) |
| [`tests/logs/quickstart_20261113_031046.log`](../tests/logs/quickstart_20261113_031046.log) | `tools/add-to-quickstart.sh` on a private copy of the Quick Start Target Image: 16 of 16 (72) |
| [`evidence/`](../evidence/README.md) | cleaned copies: `qcc` build, guest `uname -a`, `pidin` of the non-root driver, the fallback counts of every run, the supervisor test, `tools/qnx-run` with ctest, `-t` and `--json`, the core file in gdb |
| [`examples/ai-agent-session-libxml2/logs/`](../examples/ai-agent-session-libxml2/logs/) | the recorded AI-agent session on libxml2 v2.15.4 (fs-9p 0.10.0, `001-ci.txt` 7; its tools have the same sha256 as at `ac061f948768`): `testapi` crashed and 7 of 8 passed, with gdb's backtrace (`001-ci.txt`, 26, 34-47); after the agent's fix 8 of 8 passed (`002-ci.txt`, 26, 38); tests unchanged ([`HASHES.md`](../examples/ai-agent-session-libxml2/HASHES.md)) |
| [`examples/ai-agent-session/logs/`](../examples/ai-agent-session/logs/) | the earlier AI-agent session, on a planted bug: 1 of 3 tests failed (`run1.txt`), then 3 of 3 passed with the tests unchanged (`run2.txt`); fs-9p 0.6.0 ([`SESSION_LOG.md`](../examples/ai-agent-session/SESSION_LOG.md), 16) |

No log above was edited after its run, except for two kinds of lines. Two compiler lines quoting an SDP header were replaced by a marker in `oss_20261113_031620.log` (the licence does not allow SDP text in this repository); the scripts print the SDP's install path as `<QNX>`. In `oss_20261113_031340.log`, `trace_libxml2_20261113_031313.log` and the three `trace_libxml2_` logs in `tests/logs/history/`, the backtrace lines that named a function of the QNX C library (frames #0 and #3 of `testapi`) were replaced by "[frame in the QNX C library removed]", because this repository publishes no result of a functional evaluation of a QNX component. `tests/logs/` holds only logs of these sources; the 106 logs of earlier sources are in [`tests/logs/history/`](../tests/logs/history/) ([testing](testing.md#logs)).

With coverage on, `tools/qnx-ci.sh` runs one test at a time; in 4 of 4 logged runs of `demo/ci.sh`
it reported the same line and branch counts ([testing](testing.md#logs)).

## QNX technologies and the tests that check them

| QNX technology | Where | Checked by |
|---|---|---|
| Resource manager: the file system is an ordinary process (`resmgr_attach()`, iofunc handlers, a thread pool) | `src/fs9p.c` | guest test: file operations compared with the host folder |
| Message-passing priority inheritance carried through the driver: each request slot is a priority-inheritance mutex, so a client that waits for a slot raises the slot's owner | `src/virtq.c` (`vq_get()`, `vq_put()`) | `demo/priority.sh` part 3b; guest test step "a reader at priority 40 waits for the request slot ..." |
| Priority following: the interrupt thread, which receives no message, runs at the highest waiting client's priority | `src/virtq.c` (`want_prio_locked()`) | `demo/priority.sh` parts 1 and 2; guest test step "interrupt-thread priority under CPU load" |
| Boot customisation and restart without a reboot: fs-9p enters a `mkqnximage` image through snippet files and mounts at boot; a supervisor starts a new fs-9p after `slay -9` | `tools/make-image.sh`, `image/post_start.fs-9p`, `image/fs-9p-supervise` | README run; guest test step "automatic restart" |
| Non-root after setup: `procmgr_ability()` locks the abilities `io` and `priority`, then `setuid()` | `src/fs9p.c` (`drop_privileges()`) | guest test step "option -U"; README run (`pidin`: user ID 1000) |

## Priority through the driver

For a test tool the priority part matters: in the tested cases, a client in the guest was not
delayed by lower-priority work (limits: see [usage](usage.md#limitations-of-0100)). fs-9p sets its
interrupt thread, which receives no message, to the highest waiting client's priority, and a client
that finds every request slot taken blocks on the slot's priority-inheritance mutex, so the kernel
raises the slot's owner. With the only slot held by a reader at priority 10 and 8 CPU-bound loops
at 30, a read at 40 finished when 0 of the 8 loops had ended, in each of 5 runs. With `-w` (no
priority inheritance through the request slots) or `-f` (both parts off: the interrupt thread stays
at its base priority 21, and no priority inheritance through the slots), the read finished only after 8
of 8 had ended ([`demo/priority.sh` log](../tests/logs/priority_20261113_024628.log)). When the interrupt
thread does not run, a waiting server thread checks the ring itself every 200 ms (a constant), the
*fallback wait*. Its counts, the QNX interfaces used and the problems the tests found:
[internals](internals.md).

![The priority chain from the log of demo/priority.sh: pidin shows the reader dd at priority 40 REPLY-blocked on fs-9p, the fs-9p server thread at 40, and the interrupt thread at 21 with -f and at 40 by default. In each of 5 runs under 8 loops at priority 30: 24 of 27 requests needed the fallback wait with -f, 0 of 27 by default; with one request slot held by a reader at 10, 8 of 8 loops had ended when the read at 40 finished with -f and with -w, 0 of 8 by default.](priority_chain.png)

## Many writers, some killed

A step of the guest test forks 100 or 200 processes that write
64-byte records into one file of the share, through one shared descriptor or with `O_APPEND`, and
sends SIGKILL to some of them while they write. In each of the 3 logged runs, all 4 rounds passed:
no write failed, every record in the file was whole and appeared once, a writer that exited
normally had all its records, and all 16 request slots were free at unmount (136, 136 and 141
writers killed while writing; [testing](testing.md#the-guest-test)).

## Planted demonstrations

These three bugs were put in on purpose, to show kinds of bugs that only a run on QNX shows. They
are not findings.

- **`info->msglen` used where `info->srcmsglen` was meant.** The bug was put into a small QNX
  project on purpose; an earlier recorded agent session, with fs-9p 0.6.0, fixed it
  ([examples/ai-agent-session/](../examples/ai-agent-session/)).
- **A server thread that does not take its client's priority.**
  `examples/qnx-unit/tests/test_msg.c` creates a channel with `_NTO_CHF_FIXED_PRIORITY` on purpose,
  so its server thread stays at priority 10 while it serves a client at 30; on a default channel
  the thread runs at 30, the priority inheritance that the QNX documentation describes.
- **A commit that breaks a test only on QNX.** `demo/bisect.sh` makes a history of 8 commits in
  which commit 5 drops a test for `ENOTSUP`, because `ENOTSUP` and `EOPNOTSUPP` have the same value
  with glibc; `git bisect run` with `tools/qnx-run` named that commit after 3 of the 8 commits were
  built and run in the guest.

## Compared with scp, fs-nfs3 and the QNX Toolkit

More ways, with sources: [usage](usage.md#other-ways-to-share-files-with-a-qnx-guest).

- **scp.** The [mkqnximage page](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/m/mkqnximage.html)
  names scp and sftp for moving files to and from the VM. For cJSON's 22 tests, our scp runner
  (`demo/scp-run.sh`: 108 lines, 77 of them code) copied 76 files into the guest per run (53
  distinct host files). With coverage on, it also copied 68 `.gcda` files back: after each test
  program, every one of the build's 25 `.gcda` files that the program had changed. With fs-9p, 0
  and 0. Both routes passed 22 of 22 and gave the same line coverage
  ([scp log](../tests/logs/scp_baseline_20261113_030937.log), [fs-9p log](../tests/logs/cjson_20261113_030926.log),
  [comparison table](real-project.md#compared-with-an-scp-runner)).
- **fs-nfs3.** The [fs-nfs3 page](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/f/fs-nfs3.html)
  says that this client needs an NFS server and a TCP/IP stack, and that it buffers writes by
  default. fs-9p needs neither for its files and answers `write()` after QEMU's reply
  (`tools/qnx-run` itself logs in over ssh through QEMU's user-mode network).
- **QNX Toolkit for VS Code.** Its [launch configuration](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.qnxtoolkit.user_guide/topic/customizing_launch_configurations.html)
  copies the program to the target (to `/tmp` by default) and runs it there. fs-9p needs no upload;
  the Toolkit stays the choice for its debugger and profiler and for boards.
