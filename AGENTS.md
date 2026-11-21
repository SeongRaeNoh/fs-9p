# AGENTS.md: build and test QNX 8.0 code with fs-9p

For coding agents that change C or C++ code for QNX 8.0, in this repository or in a project set up
the same way. Tests run in a QNX 8.0 guest in QEMU. The guest mounts a host folder (the share) at
`/mnt/host` with fs-9p, so a program built on the host runs in the guest without copying, and files
that the guest writes (coverage counters, core files) appear in the host folder.

## Before the first command

- Load QNX SDP 8.0: `source ~/qnx800/qnxsdp-env.sh` (path of your installation). It provides `qcc`
  and `ntox86_64-gdb`.
- A guest must be running: `tools/qnx-vm status IMAGE`. Start one with
  `tools/qnx-vm start IMAGE SHARE` (README, "Quick start"), then `export QNX_IMAGE=IMAGE`;
  `tools/qnx-run` reads the share and the ssh port from there. Instead, you can set `QNX_SHARE`
  and `QNX_SSH_PORT`.
- Put every build folder inside the share (`$QNX_SHARE`). `tools/qnx-run` refuses a program outside
  it (exit status 125).

## Build, run, read

The guest test (`tests/host_side.sh`, step "AGENTS.md") runs this block as written, from the
repository root:

<!-- agents-run -->
```sh
B=$QNX_SHARE/agent-build                         # build folder inside the share
make -C examples/qnx-unit B="$B"                 # build the example's tests with qcc on the host
tools/qnx-run --json -t 60 "$B/test_ring"        # one test in the guest: one JSON line on stdout
tools/qnx-run --json -t 60 "$B/exit_status" 3    # a failing program: "exit_status":3
tools/qnx-run --json -t 3 "$B/stuck_receive"     # a hung program: stopped, "timed_out":true
cmake -S examples/qnx-unit -B "$B/cmake" -DCMAKE_TOOLCHAIN_FILE="$PWD/examples/qnx-unit/qnx-x86_64.cmake" \
      -DCMAKE_CROSSCOMPILING_EMULATOR="$PWD/tools/qnx-run;-t;60"
cmake --build "$B/cmake"
ctest --test-dir "$B/cmake" --output-junit junit.xml   # all tests in the guest; JUnit in $B/cmake/junit.xml
```

`tools/qnx-run --json` prints only the JSON line on stdout. Its fields:

| Field | Meaning |
|---|---|
| `exit_status` | 0: passed. Otherwise the program's exit status; 128+N: signal N ended it; 124: the `-t` limit was reached and the guest stopped the program; 125: qnx-run error (for example a program outside the share); 255: ssh could not reach the guest |
| `signal`, `signal_name` | the signal that ended the program, numbered and named by the guest (for example 11, `SIGSEGV`), or null |
| `timed_out` | true when the `-t` limit stopped the program |
| `stdout`, `stderr` | the program's output (at most the last 64 KiB each); the full text is in `stdout_file` and `stderr_file` |
| `core_file` | the core file of a crash, if `QNX_CORE_DIR` names the host folder that the guest's `dumper` writes into (docs/usage.md, "Core files through the share"); then run `ntox86_64-gdb -batch -ex bt PROGRAM CORE_FILE` |

## Rules

- Always pass `-t SECONDS`. A hung test is then stopped in the guest and cannot block you.
- Do not copy files into the guest (no scp): the guest already sees the share.
- Exit status 255: the guest is not running or not ready; run `tools/qnx-vm status IMAGE`.
- Tests of fs-9p itself: `tests/run_guest_tests.sh` with the settings of `tests/env.example`
  (docs/testing.md).
- A whole CMake project: `tools/qnx-ci.sh IMAGE SHARE PROJECT [--tests=REGEX]` boots the guest, runs
  the project's ctest suite in it and stops it. In the JUnit file, the `<failure>` element of a test
  that crashed holds gdb's backtrace of its core file, and its message names the signal and the
  first frame in the project with file and line (`demo/ci-crash.sh` shows one).
- Host-only tests of the 9P codec, without the SDP: `make host-check`.
