# Task: make ctest pass in the QNX 8.0 guest

## Goal

`./run_tests.sh` in this folder must end with `100% tests passed, 0 tests failed out of 3`.
At the start, one of the three tests fails. Find the cause, fix it in `src/`, and show the
passing run.

## The project: kvstore

A small key-value store for QNX 8.0. A server thread receives requests on a QNX channel and
replies; the client functions send one QNX message per call; a pulse stops the server. The code
uses QNX kernel calls, so it builds only with the QNX toolchain (`qcc`) and runs only on QNX.

| File | Content |
|---|---|
| `src/kv.h` | the API (`kv_server_start`, `kv_connect`, `kv_put`, `kv_get`, `kv_del`, `kv_count`, `kv_server_stop`) |
| `src/kv_proto.h` | the messages between the client functions and the server thread |
| `src/kvserver.c` | the server thread |
| `src/kvclient.c` | the client functions |
| `tests/test_basic.c`, `tests/test_large.c`, `tests/test_stop.c` | the three ctest tests; each prints one `ok N` or `not ok N` line per check |
| `tests/check.h` | the check macros |
| `CMakeLists.txt`, `qnx-x86_64.cmake` | the CMake build with `qcc` |

## How to build and test

QNX SDP 8.0 and QEMU are on a lab server that the scripts reach over ssh (settings in
`env.local`). A QNX 8.0 guest runs in QEMU there. Inside the guest, the fs-9p driver mounts the
server's shared folder at `/mnt/host`, so the guest runs programs that were built into that
folder without copying them.

| Command | What it does |
|---|---|
| `./vm_ctl.sh status` | says whether the guest runs and whether `/mnt/host` is mounted |
| `./vm_ctl.sh start` | boots the guest and mounts the shared folder (run it if status says `guest not running`) |
| `./run_tests.sh` | copies `src/`, `tests/` and the CMake files into the shared folder, builds with `qcc` (CMake), and runs `ctest --output-on-failure`; ctest runs each test binary inside the guest through `tools/qnx-run` |
| `./run_tests.sh -R test_basic -V` | extra arguments go to ctest; this runs one test and shows all its output |
| `./qrun.sh build/test_basic` | runs one binary of the last build in the guest with `tools/qnx-run` and prints its output and exit status |
| `./vm_ctl.sh stop` | shuts the guest down |

`tools/qnx-run` starts a program from `/mnt/host` in the guest over ssh and returns its stdout,
stderr and exit status to the host; CMake uses it as `CMAKE_CROSSCOMPILING_EMULATOR`. Its usage
is in the header of `../../tools/qnx-run` and
in `../../docs/usage.md`.

## Rules

1. Fix the cause in `src/`. Do not edit `tests/`, `CMakeLists.txt`, `qnx-x86_64.cmake`,
   `env.local` or the scripts, and do not skip, weaken or remove a check.
2. Read and edit only the files of this folder. You may read, but not edit, the fs-9p folder
   named above. Do not open other folders under `[workspace]`.
3. Build and run only through `./run_tests.sh`, `./qrun.sh` and `./vm_ctl.sh`. Do not run other
   commands on the lab server, and never start a coding agent there.
4. QNX licence: do not open, print or copy files of the QNX SDP (headers, libraries,
   documentation) in this session, because this session's transcript may be published. For API
   questions, read the public QNX 8.0 documentation at https://www.qnx.com/developers/docs/8.0/.
5. No timing figures: do not measure or print run times (`run_tests.sh` removes ctest's times).
6. Do not ask anyone and do not contact anyone. Work until ctest passes or you cannot go on.
7. When you are done, run `./vm_ctl.sh stop`.

## Report

Write `REPORT.md` in this folder:
- the cause: file, line, and what was wrong;
- the change, as a diff;
- why the failure appeared only when the test ran on QNX;
- how many times you ran `./run_tests.sh` (a count; no times);
- the last lines of the passing `./run_tests.sh` output.
