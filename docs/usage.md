# Using fs-9p

Reference for the quick start, `tools/qnx-run`, `tools/qnx-ci.sh`, other ways to share files, core
files, the driver options, other images, limitations and troubleshooting (version 0.10.0). Back to the [README](../README.md).

## What the three quick-start steps do

- `tools/make-image.sh` writes two `mkqnximage` snippet files into `IMAGE/local/snippets/`
  (`system_files.fs-9p` puts `build/fs-9p` into the image as `/system/bin/fs-9p`,
  `image/fs-9p-supervise` as `/system/bin/fs-9p-supervise`, and the SDP's OpenSSH helper
  `sshd-auth` as `/system/bin/sshd-auth` for the ssh login of `tools/qnx-run`; `post_start.fs-9p`,
  a copy of `image/post_start.fs-9p`, starts fs-9p at the end of system start-up) and runs
  `mkqnximage --type=qemu`. Snippet files are the customisation method of the public
  [mkqnximage reference](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/m/mkqnximage.html).
  The image gets the first of `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub`, `id_rsa.pub` for root logins
  over ssh (`SSH_IDENT=file` selects another public key, `SSH_IDENT=none` none).
- At boot, `fs-9p-supervise -U qnxuser` starts `fs-9p -U qnxuser`, which attaches the device, mounts
  `/mnt/host`, keeps only the two abilities it still needs and continues as `qnxuser`
  ([internals](internals.md#qnx-features-that-fs-9p-uses)); the supervisor returns when `/mnt/host`
  exists and starts fs-9p again when a signal ends it ("Automatic restart" below).
- `tools/qnx-vm start` runs `tools/qnx-share.sh` in the background. That script starts
  `qemu-system-x86_64` with the image and the two options that export a host folder
  (`-fsdev local,...` and `-device virtio-9p-pci,...,mount_tag=hostshare`). The disk is opened with
  `snapshot=on`, so the image stays as it was built; the shared folder is ordinary host storage and
  keeps every change. It uses KVM (`-enable-kvm`).

`tests/readme_run.sh` runs the two marked blocks of the README exactly as written, then checks the
share, `tools/qnx-run`, the user and abilities of fs-9p with `pidin`, an automatic restart after
`slay -9 fs-9p`, and `tools/qnx-vm status` and `stop`
(log `tests/logs/readme_run_20261113_031028.log`, 17 checks passed; list in [testing](testing.md#other-test-scripts)).

## `tools/qnx-vm` and `tools/qnx-share.sh`

| Command or setting | Meaning |
|---|---|
| `tools/qnx-vm start [IMAGE [SHARE [PORT]]]` | start QEMU in the background (`setsid`) and return when the guest answers on ssh and `/mnt/host` is mounted (at most `QNX_VM_WAIT` seconds, default 180); defaults `QNX_IMAGE`, `QNX_SHARE`, `QNX_SSH_PORT` (2222) |
| `tools/qnx-vm stop`, `status`, `console` | stop QEMU (SIGTERM, then SIGKILL after 10 s); say whether it runs and whether ssh and `/mnt/host` work; print the serial console output |
| `IMAGE/qnx-vm/` | state of `tools/qnx-vm`: `qemu.pid`, `share`, `port`, `console.log` |
| `QNX_SSH_KEY` | private key file for the ssh checks of `tools/qnx-vm` and for `tools/qnx-run` |
| `QNX_CONSOLE_LOG` | `tools/qnx-share.sh` writes the serial console to this file and to the unix socket `FILE.sock` instead of the terminal (`tools/qnx-vm` sets it) |
| `QEMU_EXTRA` | more QEMU options, split at spaces, for example a second `-fsdev`/`-device` pair |
| `QNX_DISK` | open this disk read-write instead of `output/disk-qemu.vmdk` with `snapshot=on`, so changes inside the guest stay (used for the Quick Start Target Image below) |

## Automatic restart (`image/fs-9p-supervise`)

`fs-9p-supervise [fs-9p options]` runs fs-9p in the foreground of a background shell loop. When a
signal ends fs-9p (exit status above 128, for example after `slay -9 fs-9p`), the loop prints
"fs-9p-supervise: fs-9p ended by signal N; starting it again (restart M)" on the console and starts
it again after 1 s. When fs-9p exits by itself (0 after SIGTERM, 1 when the setup fails), the loop
ends. `slay -9 fs-9p` kills only the driver: the supervisor is a shell process with another name.
Settings (environment of the supervisor):

| Setting | Default | Meaning |
|---|---|---|
| `FS9P_RESTART_MAX` | 5 | at most this many restarts within the window; at the limit the supervisor prints "not started again: K restarts in the last W s" and ends (0: never restart) |
| `FS9P_RESTART_WINDOW` | 60 | the window in seconds (the shell's `SECONDS` counter) |
| `FS9P` | `/system/bin/fs-9p` | the driver program |

Open files do not survive a restart: a descriptor opened before it fails with "Bad file
descriptor"; a new open works.

## `tools/qnx-run`

`tools/qnx-run` starts a program from the shared folder inside the guest over ssh and returns its
exit status, stdout and stderr on the host; nothing is copied into the guest. It logs in as root
with the key that `tools/make-image.sh` put into the image. `tools/qnx-run -h` prints its usage.

```sh
export QNX_IMAGE="$IMAGE"            # after tools/qnx-vm start: share and port come from IMAGE/qnx-vm/
# a VM started another way: export QNX_SHARE="$SHARE" QNX_SSH_PORT="$SSH_PORT" QNX_SSH_KEY=~/.ssh/id_ed25519
tools/qnx-run "$SHARE/hello"                                        # output and exit status on the host
tools/qnx-run -t 60 "$SHARE/hello"                                  # the same; stopped in the guest after 60 s
tools/qnx-run --json -t 60 "$SHARE/hello"                           # one JSON line instead of the output
make -C examples/qnx-unit B="$SHARE/qnx-unit-build" qnx-test        # unit tests in the guest; JUnit files
make -C examples/qnx-unit B="$SHARE/qnx-unit-build" coverage        # the same with gcov counters; gcovr report
```

| Option or setting | Meaning |
|---|---|
| `-t SECONDS` | time limit: after SECONDS the guest stops the program ("Stopping" below) and `qnx-run` returns 124 |
| `--json` | print one line with a JSON object when the program ends, and nothing else on stdout ("JSON result" below) |
| `-o DIR` | with `--json`: folder for `stdout.txt` and `stderr.txt` (default: a new folder in `$TMPDIR` or `/tmp`, kept after the run) |
| `-j FILE`, `-n NAME` | also write a JUnit XML file with one test case NAME (default: the program name) |
| `-C DIR` | working folder (default: the current host folder); inside the share it becomes the same folder in the guest, outside it the guest uses `QNX_MOUNT` |
| `-e NAME=VALUE` | set a variable for the guest program (repeatable) |
| `-i` | pass the host's stdin to the program (default: the program reads `/dev/null`) |
| `-u USER` | run the program as the guest user USER (the guest's `on -u`; the ssh login stays root), for test suites that refuse to run as root |
| `QNX_IMAGE`; `QNX_SHARE`, `QNX_SSH_PORT`, `QNX_SSH_KEY` | the image folder of a VM started with `tools/qnx-vm` (share and port are read from it); or the share, the ssh port (default 2222) and the private key |
| `QNX_MOUNT`, `QNX_SSH` | the guest mountpoint of the share (default `/mnt/host`); the command that runs a shell command in the guest (default: ssh as root to 127.0.0.1) |
| `QNX_CORE_DIR` | with `--json`: the host folder inside the share that the guest's `dumper` writes core files into; after a crash `qnx-run` names the new core file in `core_file` |

- A host path inside `QNX_SHARE` (the program or an argument) is mapped to its path under
  `/mnt/host`. A name without `/` is looked up in the guest's `PATH` (`tools/qnx-run uname -sr`).
- `-e`: absolute host paths inside `QNX_SHARE` in the value are mapped to guest paths, also in a
  colon-separated list, so `tools/qnx-run -e LD_LIBRARY_PATH="$SHARE/lib" "$SHARE/app"` lets the
  guest's loader find libraries in the share. Version links such as
  `libx.so -> libx.so.1 -> libx.so.1.0` work through fs-9p (guest test, step "a versioned shared
  library in the share").
- With CMake, `tools/qnx-run` is the test emulator: configure with
  `-DCMAKE_TOOLCHAIN_FILE=examples/qnx-unit/qnx-x86_64.cmake -DCMAKE_CROSSCOMPILING_EMULATOR="$PWD/tools/qnx-run;-t;60"`
  and a build folder inside the share, and `ctest` runs every test in the guest with a time limit
  of 60 s (`ctest --output-junit junit.xml` writes a JUnit file). [`AGENTS.md`](../AGENTS.md) has
  these commands in one block; the guest test runs that block as written (step "AGENTS.md").
  CMake applies the emulator only to tests whose command is a target name, not a path such as
  `./test_x`.
- `demo/cjson.sh` does this for an existing project: it clones cJSON v1.7.18, builds it with `qcc`
  in the share, and runs its own 22 test programs with `ctest` in the guest (22 of 22 passed;
  `COVERAGE=1` adds the coverage of `cJSON.c`; `tests/logs/cjson_20261113_030926.log`).
  `demo/scp-baseline.sh` runs the same tests through a runner that copies with `scp` and counts the
  copies. See [real-project.md](real-project.md).

**Exit status.**

| Status | Meaning |
|---|---|
| the program's | the program's own exit status; 128+N if signal N ended it, with N as QNX numbers it (139 for a segmentation fault; guest test, step "core dumps through the share") |
| 124 | the `-t` limit was reached and the guest stopped the program |
| 128+N | `qnx-run` got signal N and the guest stopped the program: 130 for SIGINT, 143 for SIGTERM, 129 for SIGHUP |
| 125 | `qnx-run` itself failed (bad usage, a program outside `QNX_SHARE`) |
| 255 | ssh could not reach the guest |

**Stopping.** The guest runs the program as a background job in its own process group. To stop
it, the guest sends SIGTERM to the process group and SIGKILL 2 s later (a constant in
`tools/qnx-run`), so child processes stop as well, also with `-u`. A process that leaves the
program's process group, for example a child that calls `setsid()`, gets neither signal and keeps
running; GNU `timeout` has the same scope, because it also signals a process group. If such a
process keeps the program's output open, `qnx-run` returns only when it kills its ssh client, 30 s
after the `-t` limit (constants below; seen with a test program outside the guest test). The guest
stops the program's process group in three cases:

- the `-t` limit is reached (status 124);
- `qnx-run` gets SIGINT, SIGTERM or SIGHUP (Ctrl-C, or ctest's `TIMEOUT_SIGNAL_NAME`): `qnx-run`
  sends a stop request through ssh, waits until the guest has stopped the program, and returns
  128+N;
- ctest's `TIMEOUT` ends `qnx-run` and its ssh client in a way that `qnx-run` cannot catch: the
  guest checks once a second whether its ssh session still exists and stops the program when it
  does not ([internals](internals.md#how-toolsqnx-run-stops-a-guest-program)).

With `-i` the host's stdin belongs to the program, so on a host signal `qnx-run` ends its ssh
client and the guest stops the program when it sees that the session has ended (from the code;
not in the guest test). If the guest does not answer, `qnx-run` kills its ssh client 15 s after a
host signal, or 30 s after the `-t` limit (constants in `tools/qnx-run`).

The guest test checks this with `examples/qnx-unit/tests/stuck_receive`, a program that waits in
`MsgReceive()` and, with the argument `fork`, has a child that waits as well (step "tools/qnx-run
stops the guest program", 6 checks, `tests/logs/guest_tests_20261113_025442.log` lines 451-488): `-t 3` returned
124 and left 0 of the 2 processes; the same with SIGTERM ignored (the SIGKILL path) returned 124
and left 0; with `-u qnxuser` both processes ran as uid 1000, and `-t 3` returned 124 and left 0; SIGINT returned 130 and SIGTERM 143, with 0 left when `qnx-run` returned; ctest
`TIMEOUT 5` (test `runner_timeout`, added with `-DQNX_UNIT_TIMEOUT_CHECK=ON`) left 0. SIGHUP is
not in the guest test. Excerpt: `evidence/qnx_run_stop_json.txt`.

**JSON result.** `tools/qnx-run --json` prints one line with these fields:

| Field | Meaning |
|---|---|
| `program`, `guest_program` | the program as given on the host, and its path in the guest |
| `exit_status` | the exit status in the table above |
| `signal`, `signal_name` | the signal that ended the program, numbered and named by the guest's `kill -l` (for example 11, `SIGSEGV`), or null |
| `timed_out`, `time_limit_s` | true when the guest reports that the `-t` limit stopped the program, or when the guest did not answer and `qnx-run` ended ssh 30 s after the limit, a constant (a program that exits with 124 by itself gives false); the limit in seconds (0: none) |
| `host_signal` | `SIGINT`, `SIGTERM` or `SIGHUP` when `qnx-run` got that signal, else null |
| `stdout`, `stderr` | the program's output, at most the last 64 KiB each; `stdout_bytes` and `stderr_bytes` give the full size, `stdout_truncated` and `stderr_truncated` say whether the text was cut |
| `stdout_file`, `stderr_file` | the files with the full output (in the `-o` folder) |
| `core_file` | the core file of a crash when `QNX_CORE_DIR` is set ("Core files through the share" below), else null |
| `junit_file` | the `-j` file, else null |
| `error` | a message when ssh failed (255), else null; when `qnx-run` itself fails (125), the line has only `exit_status` and `error` |

In `stdout` and `stderr`, bytes that are not UTF-8 and control characters other than tab and CR
are dropped (`js()` in `tools/qnx-run`). A line from the guest test (`tests/logs/guest_tests_20261113_025442.log`
line 491; the log prints the share and the repository folder as `SHARE` and `REPO`):

```json
{"program":"SHARE/qnx-unit/build/exit_status","guest_program":"/mnt/host/qnx-unit/build/exit_status","exit_status":3,"signal":null,"signal_name":null,"timed_out":false,"time_limit_s":60,"host_signal":null,"stdout":"exit_status: stdout line\n","stdout_bytes":25,"stdout_truncated":false,"stderr":"exit_status: stderr line\n","stderr_bytes":25,"stderr_truncated":false,"stdout_file":"REPO/tests/work/j1out/stdout.txt","stderr_file":"REPO/tests/work/j1out/stderr.txt","core_file":null,"junit_file":null,"error":null}
```

The guest test checks `--json` in step "tools/qnx-run --json" (3 checks, log lines 502-504: a
program that exits with 3; `-t 2` on `stuck_receive` with `timed_out` true and status 124; a
program that exits with 124 by itself, with `timed_out` false without `-t` and with `-t 60`, and a
JUnit file that names an exit-status failure, not a timeout) and in step "core dumps through the
share" (1 check, log line 176: `signal` 11, `signal_name` `SIGSEGV`, `core_file` set).

`examples/qnx-unit/` holds three unit tests built with `qcc`: a ring buffer (plain C), message
passing (`MsgSend`, `MsgReceive`, `MsgReply`, `MsgError`, and the priority that the server thread
runs at while it serves a client, on a default channel and on a `_NTO_CHF_FIXED_PRIORITY` channel),
and pulses (`MsgSendPulse`, a timer that delivers a pulse, the priority order of queued pulses).
Two more tests check the runner: exit status 3 reaches the host, and a host path argument reaches
the program as its guest path. `stuck_receive` (above) is built too; its ctest test exists only with
`-DQNX_UNIT_TIMEOUT_CHECK=ON`, so the default `ctest` run has 5 tests.

**Coverage.** The cJSON run above reports the coverage of library code under its tests
(`cJSON.c`: 88 % of lines, 76 % of branches). For the small example, `make coverage` builds the tests with `qcc -fprofile-arcs -ftest-coverage` (qcc
rejects the gcc driver option `--coverage`) into `B/cov`, with absolute object paths. It runs them
with `tools/qnx-run -e GCOV_PREFIX=/mnt/host -e GCOV_PREFIX_STRIP=N`, where N is the number of path
components of the share's host path: the gcov runtime in the guest then writes each `.gcda` file
through `/mnt/host` into `B/cov` on the host. gcovr (`GCOVR`, default `gcovr`; it calls the SDP's
`ntox86_64-gcov`, setting `GCOV`) writes `B/cov/coverage.txt` and `B/cov/html/index.html`; without
gcovr the target prints the summary of `ntox86_64-gcov`. `B` must be inside the share. Its report
covers the three test files themselves (83 of 83 lines), because the example has no separate
library under test.

**git bisect.** `demo/bisect.sh` shows `git bisect run` with a step that builds with `qcc` and runs
the test in the guest: `git bisect run sh -c 'qcc ... || exit 125; qnx-run ./test'`. The exit
status of `tools/qnx-run` fits `git bisect run`: 0 good, 1 to 127 except 125 bad (with `-t`, a test
that hangs returns 124 and counts as bad), 125 skip (also when `qnx-run` itself fails); above 127
(a signal ended the program: 128+N; ssh cannot reach the guest: 255) ends the bisect.

`-i` is used by the README run (commands for the restart check), `-e` by `make coverage`,
`demo/cjson.sh` and the shared-library step of the guest test, `-t` and `--json` by the guest
test steps above and the `AGENTS.md` block. Not tested: hosts other than Linux.

## A team's test machine: `tools/qnx-ci.sh`

The QNX SDP licence rules out hosted CI services, so a team runs its QNX tests on a Linux machine of
its own with QNX SDP 8.0 and QEMU. One command does the whole job:

```sh
tools/qnx-ci.sh "$IMAGE" "$SHARE" examples/qnx-unit path/to/project -DOPTION=ON --filter='.*/src/.*'
```

- It boots the image of `tools/make-image.sh` with `tools/qnx-vm start` (no VM of that image may run
  yet) and stops it at the end, also after an error (`CI_KEEP_VM=1` keeps it).
- Each `PROJECT` is a CMake source folder. It is configured with the toolchain file
  `examples/qnx-unit/qnx-x86_64.cmake` and built with qcc into `SHARE/ci/NAME`. The toolchain file
  sets `CMAKE_FIND_ROOT_PATH` to the SDP's target folders, so `find_package()` and
  `find_library()` find the QNX libraries (for example zlib) and not the host's. `-DVAR=VALUE`
  after a project goes to its CMake configure step; `--jobs=N` sets `ctest -j N` for that project
  (`--jobs=1` for a suite whose tests use fixed TCP ports); `--tests=REGEX` runs only the tests whose
  name matches (`ctest -R`); `--user=NAME` runs the project's tests as the guest user NAME
  (`tools/qnx-run -u`), for a suite that refuses to run as root; `--timeout=N` sets the time limit
  per test of that project to N seconds instead of `CI_TIMEOUT` (`tools/qnx-run -t N`, `ctest
  --timeout` N + 60); `--build-only` configures and builds the project with qcc and runs none of
  its tests (no JUnit file; `CI_OUT/NAME.built.txt` names the number of tests registered);
  `--filter=REGEX` and `--exclude=REGEX` go to gcovr. A project whose tests read files from its
  source tree must lie inside `SHARE`.
- CMake puts the emulator only in front of tests registered as `add_test(NAME n COMMAND target)`. After
  the build, `tools/qnx-ci.sh` reads the generated `CTestTestfile.cmake` files: a test whose command is
  a program of the build folder (an ELF file) gets `tools/qnx-run` in front of it there (the project's
  sources are not changed); a test whose command is something else, such as `sh script.sh`, would run
  on Linux, so it is left out (`ctest -E`) and named in the output. The output gives both counts.
- `ctest --output-junit` runs the tests: one at a time (`-j 1`) while coverage is on (the default;
  in 4 of 4 logged runs of `demo/ci.sh` the coverage counts were the same,
  [testing](testing.md#logs)), otherwise with `-j CI_JOBS` (default 4) or the project's `--jobs=N`;
  with `--timeout` of `CI_TIMEOUT` (or the project's
  `--timeout=N`) + 60 s for tests without their own `TIMEOUT`; the JUnit file keeps each test's full
  output (up to 1 MiB); the emulator is `tools/qnx-run -t 300` (the `CI_TIMEOUT` default) with
  `LD_LIBRARY_PATH` set to the build folder, and, with coverage (default), `GCOV_PREFIX` and
  `GCOV_PREFIX_STRIP`, so that the guest writes each `.gcda` file next to its object file.
- Crashed tests: after the boot, `tools/qnx-ci.sh` reads the dump folder of the guest's `dumper`
  (option `-d` in `pidin -p dumper -F '%A'`), replaces it by a link to `SHARE/ci/cores` for the run
  and puts it back at the end ([core files through the share](#core-files-through-the-share)). A test
  counts as crashed when it failed and its output holds "(core dumped)", which the guest's shell
  prints when the test program itself ended by a signal with a core file; a child process that a
  test crashes on purpose does not count. For each crashed test, the SDP's `ntox86_64-gdb` opens the
  newest core file of the test's program on the host, and the backtrace goes into the test's JUnit
  `<failure>` element and the output. The failure message names the signal, the core file and the
  first frame in the project, for example `crashed with SIGSEGV; core file parse_crash.core; first
  frame in the project: read_value at src/record.c:9`. Frames in the project's source or build folder
  keep file and line; other frames (the C library, other system libraries) show the function name
  only, and a run of more than two of them is shortened to its first and last frame.
  `demo/ci-crash.sh` runs `examples/ci-crash` (a test that passes, one that crashes, one whose child
  crashes on purpose, one that fails without a crash): 1 backtrace, in the crashed test only
  (log `tests/logs/ci_crash_20261113_031252.log`). `demo/trace-libxml2.sh` does the same for libxml2's `testapi`
  ([oss-suite.md](oss-suite.md#results)).
- Reports go to `SHARE/ci/results/`: `NAME.junit.xml` (ctest), `NAME.coverage.txt` and
  `NAME.cobertura.xml` (gcovr); the reports of a project are deleted before its build. The output
  names the counts and no times; it prints the share, the repository, the image folder and the SDP
  installation as `SHARE`, `REPO`, `IMAGE` and `<QNX>`.
- Settings: `CI_JOBS` (default 4), `CI_TIMEOUT` (seconds per test, default 300), `CI_COVERAGE=0`,
  `CI_OUT`, `GCOVR`, `GCOV`, `CI_CORES=0` (no core files and backtraces), `GDB` (default
  `ntox86_64-gdb`), `CI_BT_FRAMES` (frames per backtrace, default 20), and `QNX_SSH_PORT`,
  `QNX_SSH_KEY` as for `tools/qnx-vm`. Exit status 0
  when every project built and every test passed, 1 otherwise, 2 for bad usage or a VM that did not
  start.

`demo/ci.sh IMAGE SHARE` is the team example: it clones cJSON v1.7.18 into `SHARE/ci-src/`, makes the
change of [real-project.md](real-project.md#the-one-change-to-the-clone) and runs `tools/qnx-ci.sh` on
`examples/qnx-unit` and cJSON (log `tests/logs/ci_20261113_031200.log`). The form with `path/to/project`
above was not run as written. `demo/oss-suite.sh IMAGE SHARE` runs `tools/qnx-ci.sh` on eight
open-source C projects at fixed tags (seven libraries, libxml2 in two versions; libuv only built), and on Linux as a check of each suite ([oss-suite.md](oss-suite.md)).

## Other ways to share files with a QNX guest

| Way | How files reach the guest | Needs in the guest | Needs on the host | Copy after each build | Source |
|---|---|---|---|---|---|
| `scp` / `sftp` | copied over the network | an ssh server | an ssh client | yes, in both directions (cJSON's tests: 76 copies of 53 distinct files in per run, 68 copies of the 25 `.gcda` files back; [log](../tests/logs/scp_baseline_20261113_030937.log)) | [mkqnximage](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/m/mkqnximage.html) (the page names scp and sftp for moving files to and from the VM) |
| `rsync` over ssh | copies the files whose size or modification time changed, sending only their differences | rsync and an ssh server; rsync 3.4.1 is a QNX 8.0 package on [oss.qnx.com](https://oss.qnx.com/) (not tried here) | rsync and an ssh client | yes, the changed files; files that the guest writes (`.gcda`, core files) need a second rsync back | [rsync(1)](https://download.samba.org/pub/rsync/rsync.1) ("rsync must be installed on both the source and destination machines") |
| QNX Toolkit for VS Code, launch | the launch configuration uploads the program to the target (default folder `/tmp`) and runs it; extra files can be uploaded before the run and downloaded after it or while it runs | the `qconn` agent (default port 8000) for an IP target | VS Code with the QNX Toolkit | yes, done by each launch | [Customizing launch configurations](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.qnxtoolkit.user_guide/topic/customizing_launch_configurations.html), [Managing targets](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.qnxtoolkit.user_guide/topic/managing_targets.html) |
| `fs-nfs3` (NFS 3 client) | the guest mounts a folder of an NFS server over TCP/IP | `fs-nfs3` and networking | an NFS server | no; writes are buffered in the client by default and sent later (`-w delay=`, or `-w sync=hard`) | [fs-nfs3](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/f/fs-nfs3.html) |
| QNX Hypervisor shared file system (virtio-fs) | a QNX Hypervisor host shares its folders with its guests through a virtio-fs vdev and a FUSE daemon | a virtio-fs driver; the pages name drivers for Android and Linux guests | a QNX Hypervisor host | no | [Filesystem Sharing](https://www.qnx.com/developers/docs/7.1/com.qnx.doc.qavf.overview/topic/virtfs.html), [Required components](https://www.qnx.com/developers/docs/7.1/com.qnx.doc.qavf.overview/topic/virtfs_components.html) (7.1 pages; they call the framework experimental) |
| fs-9p | the QNX guest mounts a host folder through QEMU's virtio-9p PCI device, without a network | fs-9p (started at boot by the image of `tools/make-image.sh`) | QEMU with two options | no; fs-9p answers `write()` after QEMU's reply (`fs_write()` in `src/fs9p.c`) | [tests/logs/](../tests/logs/) |

fs-9p itself needs no network; `tools/qnx-run` logs in to the guest with ssh through QEMU's
user-mode network. Another way is the better choice for a physical board (`scp`, `fs-nfs3`, the
Toolkit) and for the Toolkit's debugger and profiler; the Toolkit can also show the target's files
in VS Code ([Remote filesystem operations](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.qnxtoolkit.user_guide/topic/remote_file_system_operations.html)).

## Core files through the share

A program that crashes in the guest can leave its core file in the host folder, where the SDP's
`ntox86_64-gdb` opens it with the host binary; nothing is copied. QNX's `dumper` writes core files
into its dump folder (option `-d`). The image of `tools/make-image.sh` runs
`dumper -U 30:30 -d /data/var/dumper -M 1000 -D cores` (read with `pidin -p dumper -F '%A'` in the
guest test). The guest test replaces that folder by a link into the share for one step and puts it
back afterwards (`tests/host_side.sh`, step "core dumps through the share"). The same steps as host
commands (not run in this form; the test runs them with its own ssh command):

```sh
mkdir -p "$SHARE/cores" && chmod 777 "$SHARE/cores"       # as in the test: writable for every user
tools/qnx-run sh -c 'mv /data/var/dumper /data/var/dumper.saved && ln -s /mnt/host/cores /data/var/dumper'
qcc -Vgcc_ntox86_64 -g -O0 -o "$SHARE/crash/crash" "$SHARE/crash/crash.c"
tools/qnx-run "$SHARE/crash/crash"; echo "exit status $?"   # 139: SIGSEGV (128 + 11)
QNX_CORE_DIR="$SHARE/cores" tools/qnx-run --json "$SHARE/crash/crash"   # "signal":11, "core_file":".../cores/crash.core"
ntox86_64-gdb -batch -ex bt "$SHARE/crash/crash" "$SHARE/cores/crash.core"
tools/qnx-run sh -c 'rm /data/var/dumper && mv /data/var/dumper.saved /data/var/dumper'
```

With `--json` and `QNX_CORE_DIR`, `qnx-run` waits after a crash signal until the size of the new
core file stays the same for 1 s (at most 20 s; constants in `tools/qnx-run`) and names the file
in `core_file`. In the 0.10.0 guest test the program ended with exit status 139 on the host,
`crash.core` appeared in the host folder, the `--json` line had `"signal":11`,
`"signal_name":"SIGSEGV"` and `core_file` = `SHARE/cores/crash.core`, and gdb printed the frames
`read_value`, `parse_record` and `main` with file and line (`tests/logs/guest_tests_20261113_025442.log`,
lines 163-181, 5 checks in this step; `evidence/core_dump.txt`). Not tested: a Quick Start Target Image (whether
it runs `dumper`, and with which folder).

## Options

| Option | Meaning |
|---|---|
| `-m path` | mountpoint (default `/mnt/host`) |
| `-t auto\|legacy\|modern` | PCI interface; `auto` uses legacy for transitional devices (1af4:1009) and virtio 1.x for modern-only devices (1af4:1049, QEMU option `disable-legacy=on`) |
| `-a tag` | use the device whose mount tag is `tag`; start one fs-9p per share. Devices that another driver has attached are skipped and not reset. Without `-a`: the first device that no other driver has attached |
| `-s bytes` | 9P msize to ask for (default 135168) |
| `-n count` | request slots, the most requests in flight (default 16, at most 64) |
| `-i priority` | base priority of the interrupt thread (default 21; 0 = the priority of fs-9p); while requests are in flight or clients wait for a free request slot, the thread runs at the priority of the highest of these clients, above or below the base; with none it returns to the base from above, and stays where it is from below until the next request |
| `-f` | fixed: keep the interrupt thread at the base priority, and no priority inheritance through the request slots (the behaviour of 0.5.0) |
| `-w` | a client that waits for a free request slot does not raise the slot's owner or the interrupt thread (the behaviour of 0.9.0; for comparison). By default the waiting server thread blocks on the slot's mutex, and the kernel runs the slot's owner at the waiter's priority until it gives the slot back ([internals](internals.md#qnx-features-that-fs-9p-uses), item 3) |
| `-U user` | after setup, run as `user` (name or `uid[:gid]`) with only the abilities `io` and `priority` |
| `-P` | with `-U`, keep only `io`: clients above the maximum priority for unprivileged processes (usually 63) are then served at that maximum |
| `-p` | poll the used ring instead of using the interrupt |
| `-r` | read-only mount (writes return `EROFS`) |
| `-d` | background mode; the command returns when the mountpoint is ready (exit status 0) or setup failed (1) |
| `-v` | log to stderr (repeat for every 9P message) |

fs-9p must be started as root (it attaches the PCI device, maps physical memory, attaches the
interrupt and registers a pathname). With `-U` it continues as a normal user.

## Other images

The two snippet files work in the `local/snippets/` folder of any `mkqnximage` image folder; this
repository tested them with the image that `tools/make-image.sh` builds.

### QNX 8.0 Quick Start Target Image

`tools/add-to-quickstart.sh` adds fs-9p to an existing Quick Start Target Image for QEMU without
rebuilding it. It works on the running guest over ssh: it copies `build/fs-9p` and
`image/fs-9p-supervise` to `/system/bin/` and adds a marked block to the boot script
`/system/etc/startup/post_startup.sh` (the first run keeps the original as
`post_startup.sh.before-fs-9p`). From the next boot on, fs-9p mounts the share at `/mnt/host` as
`qnxuser`, and `fs-9p-supervise` starts it again when a signal ends it.

Work on a copy of the image folder, or on a qcow2 overlay of its disk, not on a disk that other VMs
use. `QNX_DISK` makes `tools/qnx-share.sh` and `tools/qnx-vm` open that disk read-write instead of
`output/disk-qemu.vmdk` with `snapshot=on`, so the changes stay. The script needs a root login with
a key, and the image refuses root over ssh (`PermitRootLogin no`), so step 2 allows key logins once.

```sh
# 1. on the host: an overlay (the image disk is only read), then boot; this terminal is the console
make
qemu-img create -f qcow2 -F vmdk -b "$QSTI/output/disk-qemu.vmdk" my-disk.qcow2
QNX_DISK=my-disk.qcow2 tools/qnx-share.sh "$QSTI" "$SHARE" 2222
# 2. on that console, log in as root (root's home is /data/home/root) and paste your public key
mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA... you@host' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-root-key.conf; slay -s SIGHUP sshd
# 3. in a second host terminal (QNX_SSH_KEY=... selects the private key)
QNX_SSH_PORT=2222 tools/add-to-quickstart.sh
# 4. quit QEMU (Ctrl-a x) and start the image again in the background, now with /mnt/host at boot
QNX_DISK=my-disk.qcow2 tools/qnx-vm start "$QSTI" "$SHARE" 2222
tools/add-to-quickstart.sh --remove        # undo: removes the block and the two programs
```

Any other launcher works too if it adds the two QEMU
options `-fsdev local,id=fs0,path=FOLDER,security_model=none` and
`-device virtio-9p-pci,fsdev=fs0,mount_tag=hostshare`. Without the device, fs-9p prints an error at
boot and the boot goes on. The Quick Start launcher `mkqnximage --run` uses bridge networking; this
repository uses user-mode networking and did not test that launch path.

`tests/quickstart_test.sh` checks these steps on a private copy of the image (log
`tests/logs/quickstart_20261113_031046.log`, 16 checks passed): key setup on the serial console, two runs of the script (one block
only), a second boot with `/mnt/host` mounted without a typed command and fs-9p running as uid
1000, an automatic restart after `slay -9`, and `--remove` (the boot script has its old checksum).

### Starting fs-9p by hand

```sh
/system/bin/fs-9p -d -U qnxuser       # as root; returns when /mnt/host is ready
slay fs-9p                            # unmount (SIGTERM); the device is reset
```

At the unmount fs-9p writes to its standard error (in background mode `-d` only with `-v`) the line
`fs-9p: request slots at unmount: F of N free, B in use, L lost; I requests in flight`, then its
statistics lines. A slot that is not free while no request is in flight would be a leak; the guest
test checks for 16 of 16 free after its forked-writers step ([testing](testing.md#the-guest-test)).

With `security_model=none` the guest sees the host's file owners and modes, and QEMU accesses files
with the rights of the host user who runs it. In the image of `tools/make-image.sh`, `qnxuser` has
the user ID 1000, which is also the ID of the first user on many Linux hosts; then `qnxuser` has the
owner's rights on the host's files.

## Limitations of 0.10.0

- Hard links: `link()` returns `ENOSYS` (`fs_link()` in `src/fs9p.c`). Symbolic links work (guest
  test, step "symbolic links").
- Renaming a path below a linked folder returns `EXDEV`, so `mv` copies and removes instead.
- `statvfs()` answers from the host folder: total bytes equal within one block, free bytes within
  2 %, file nodes and name length equal (guest test, step "symbolic links"). QEMU scales the block
  size to the 9P message size, so `f_bsize` differs from the host's.
- x86_64 with PCI only: no virtio-mmio (aarch64 `virt` machine), no MSI-X (INTx interrupt).
- fs-9p and its programs also compile for aarch64le (`make VARIANT=gcc_ntoaarch64le B=build-a64`,
  0 warnings: [evidence/aarch64_build.txt](../evidence/aarch64_build.txt)), but every test ran on
  x86_64 QEMU only: running them on QEMU's aarch64 `virt` machine needs SDP packages that our test
  machine does not have (the `virt` startup program, the virtio block driver and a PCI hardware
  module).
- Tested on a Linux host with KVM only.
- Freeing a range inside a file (`F_FREESP` with an end before the end of the file) returns
  `ENOSYS`; changing the file size works.
- chown: with `security_model=none`, QEMU changes files with the rights of the host user who runs
  it. Other owners than that user give "Operation not permitted" unless QEMU runs as root.
- Permissions: the host decides. The guest checks only what the QNX `iofunc` helpers check.
- Append writes start at the file size known to the open file; a file that the host extends at the
  same time can be overwritten at its end.
- Open files do not survive a restart of the driver.
- `_IO_READ64` and `_IO_WRITE64` messages are not handled. Reads and writes of the test (up to
  100 MiB in one call) did not use them.
- Attributes are read from the host at open and at each `stat`; no cache across opens. Every open
  has its own attribute structure, so `fcntl()` record locks are not shared between two opens of
  the same file. Locking is not tested.
- `utime()` with 32-bit times is sign-extended; times after 2038 need `utimes()` or `utimensat()`.
- A client that is interrupted while waiting is answered when the host replies (no `Tflush`).
- With two clients at different priorities in flight at the same time, the interrupt thread is
  lowered to the next waiter's priority when the first request ends (from the code; not tested).
- A priority that reaches a waiting server thread after it started to wait (a later message or a
  mutex of another thread) raises the slot's owner through the kernel, but not the interrupt thread
  until the next request starts or ends (from the code; not tested).
- QEMU's 9P server on the Linux host does not run at QNX priorities; it serves requests in the order
  of its own threads, and its read throttling (used in the request-slot test) is shared by all
  requests of a device.
- The hand-over of a request slot to a waiting client of higher priority was tested with one slot
  (`-n 1`) and one low-priority reader that holds it (guest test, step "a reader at priority 40
  waits for the request slot that a reader at 10 holds"; `demo/priority.sh` part 3). Several slots
  with several owners at different priorities are not tested.
- `tools/qnx-run` uses the statuses 124, 125, 128+N and 255 for its own cases. A program that
  returns one of these values itself gives the same exit status. `--json` and `-j` tell the cases
  apart for 124: `timed_out` is true only when the `-t` limit stopped the program (reported by the guest, or
  ssh ended by `qnx-run` 30 s after the limit, a constant); a program that exits with 124 by itself gives false
  (guest test, step "tools/qnx-run --json"; `tests/logs/guest_tests_20261113_025442.log` line 504).
- `tools/qnx-run --json` keeps its output folders (`-o`, or a new folder in `$TMPDIR`); nothing
  deletes them.

## Troubleshooting

| Message or symptom | Cause and fix |
|---|---|
| `fs-9p: no virtio-9p device found` | QEMU was started without the `-fsdev` and `-device virtio-9p-pci` options, or `-a tag` names a tag that no device has. `fs-9p -v` prints the devices it finds. |
| `fs-9p: no free virtio-9p device ... found (... skipped: attached by another driver ...)` | Every matching device is served by another fs-9p instance already, for example the one started at boot. Stop it (`slay fs-9p`) or select another share with `-a`. |
| fs-9p stops at start with a permission error | fs-9p was not started as root. |
| `make-image: mkqnximage not found` | Source `qnxsdp-env.sh` of QNX SDP 8.0 first. |
| `tools/qnx-run` exits with 255 | ssh cannot reach the guest: check `QNX_SSH_PORT` and `QNX_SSH_KEY`, and that the image was built with `SSH_IDENT`. |
| `tools/qnx-run` exits with 124 | The `-t` limit was reached and the guest stopped the program. Look for a hang (for example a `MsgReceive()` that no client answers), or give a larger limit. |
| `tools/qnx-run` exits with 125 | Bad usage, or the program is outside `QNX_SHARE` (`qnx-run` prints the reason; with `--json` it is in `error`). Build into the share. |
| `ssh: ... Permission denied` for root on a Quick Start image | That image refuses root logins over ssh. Allow key logins for root once on the serial console ("QNX 8.0 Quick Start Target Image" above), or use the serial console. |
| `kex_exchange_identification: Connection closed by remote host` | Either sshd in the guest is not running yet, or it refuses the host for a while after repeated failed logins (OpenSSH `PerSourcePenalties`; with QEMU user networking every login comes from the same address). Fix the key, wait a few minutes, try again. |
| `scp: .../fs-9p: Resource busy` | The file being replaced is the running driver. Run `slay fs-9p`, wait until it has exited, then copy. |
| `Permission denied` when writing | The host user who runs QEMU has no write permission in the shared folder, or the guest user is not the owner of the file (see "Other images"). |
| `Bad file descriptor` on a file that was open before | The driver was restarted; open the file again. |
| `Arg list too long` with thousands of files | A limit of the guest's command line, not of fs-9p; use `find ... -exec cmd {} +`. |
| Times shown by `ls -l` in the guest differ from the host by hours | The guest clock and time zone are UTC by default; the stored times are equal. |
