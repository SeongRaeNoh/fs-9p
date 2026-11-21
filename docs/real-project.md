# An existing project's own tests in the guest: cJSON

[cJSON](https://github.com/DaveGamble/cJSON) is a JSON parser in C (MIT licence) with its own test
suite: 22 test programs, most of them built on the Unity test framework, registered with CMake and
run by `ctest`. `demo/cjson.sh` clones it, builds it with `qcc` on the Linux host, and lets `ctest`
start every test program inside the QNX 8.0 guest, from the shared folder, through `tools/qnx-run`.
No file of cJSON is part of this repository; the script fetches it.

Back to the [README](../README.md). Log: [`tests/logs/cjson_20261113_030926.log`](../tests/logs/cjson_20261113_030926.log) (fs-9p 0.10.0, sources
`ac061f948768` in line 1).

## Result (cJSON v1.7.18, fs-9p 0.10.0)

| What | Count | Source in the log |
|---|---|---|
| test programs that `ctest` ran in the guest | 22 of 22 passed | line "100% tests passed, 0 tests failed out of 22" |
| Unity test cases inside those programs | 158, 0 failures, 1 ignored | line "Unity test cases in 21 programs" (summed from ctest's own log) |
| line coverage of `cJSON.c` under its tests, measured in the guest | 1223 of 1384 lines (88 %) | gcovr table "Lines" |
| branch coverage of `cJSON.c` | 703 of 922 branches (76 %) | gcovr table "Branches" |
| line and branch coverage of `cJSON_Utils.c` | 561 of 625 lines (89 %), 376 of 450 branches (83 %) | gcovr tables |

The log also names the first lines of `cJSON.c` that no test executed and an executed line with a
branch that no test took (line 135, 1 of its 4 branches), from the merged counts.

## What it uses of fs-9p

- Shared libraries with version links in the share: cJSON builds `libcjson.so.1.7.18` with the links
  `libcjson.so.1` and `libcjson.so`; every test program needs `libcjson.so.1`, which the guest's
  loader opens through the link (`LD_LIBRARY_PATH` set by `tools/qnx-run -e`, which maps the host
  build folder to its guest path).
- Test input files read through the share: `parse_examples` reads `inputs/*`, `json_patch_tests`
  reads `json-patch-tests/*.json`, relative to the test's working folder.
- Coverage counters written through the share: with `COVERAGE=1` the build has gcov counters; the
  guest writes the `.gcda` files into the host build folder (`GCOV_PREFIX`, `GCOV_PREFIX_STRIP`), and
  gcovr reads them on the host with the SDP's `ntox86_64-gcov`. cJSON's unit tests compile `cJSON.c`
  into each test program with `#include`, so the script gives gcovr the `.gcda` files of all test
  programs; gcovr adds the counts per source file.

## Compared with an scp runner

`demo/scp-baseline.sh` runs the same 22 tests without the shared folder. Its emulator
`demo/scp-run.sh` copies with `scp`, before every test run, the program, the shared libraries
that the program needs and the data files of the test into a new guest folder, runs the program
there over ssh, and in the coverage run copies the changed `.gcda` files back
([testing](testing.md#demos) describes the runner). The runner keeps no state between test runs,
because `ctest` calls the emulator once per test; a runner that kept copies between runs would copy
fewer files but would have to find changed files itself (not built here). Both logs come from the
same 0.10.0 sources (`ac061f948768` in line 1 of each).

| What | scp runner (`tests/logs/scp_baseline_20261113_030937.log`) | fs-9p (`tests/logs/cjson_20261113_030926.log`) |
|---|---|---|
| test programs passed, plain run and coverage run | 22 of 22 and 22 of 22 (lines 12, 17) | 22 of 22 and 22 of 22 (lines 46, 74) |
| files copied into the guest per run of the 22 tests | 76: 22 programs, 25 shared libraries, 29 data files; 53 different host files (lines 25, 26) | 0 (line 30 of the scp log: `tools/qnx-run` has no copy step) |
| files copied back in the coverage run | 68 `.gcda` files; 25 different files (lines 19, 26) | 0; the guest writes the 25 `.gcda` files through the share (line 77) |
| core files and report files copied back | 0 and 0: no test crashed; `ctest` writes its JUnit file on the host (lines 28, 29) | 0 |
| host paths that the runner translated | 68 in the plain run, 136 in the coverage run; over both runs: program 44, working folder 44, `LD_LIBRARY_PATH` 44, data 4, `.gcda` 68 (lines 25-27) | one rule: the shared folder is `/mnt/host` in the guest |
| line coverage of `cJSON.c` | 1223 of 1384 (88 %), from the copied-back files (line 20) | 1223 of 1384 (88 %) (line 82) |

The counts are numbers of files and paths; neither log contains times.

## Run it

With the guest running and the share mounted (the README quick start), the SDP environment sourced,
and CMake 3.21 or newer:

```sh
export QNX_IMAGE=~/fs9p-image            # or QNX_SHARE and QNX_SSH_PORT, as for tools/qnx-run
demo/cjson.sh ~/qnx-share/cjson          # a folder inside the shared folder
COVERAGE=1 demo/cjson.sh ~/qnx-share/cjson
```

Settings: `CJSON_TAG` (default `v1.7.18`), `CJSON_URL`, `GCOVR` (gcovr command), `PYTHON`.

The scp baseline needs a folder outside the share and the commands for the guest login and the
copy. The 0.10.0 log was made with the test machine's own wrappers for these two commands; the
form below was not run as written:

```sh
export QNX_SHARE=~/qnx-share             # only used to check that the work folder is outside it
SCP_RUN_SSH="ssh -p 2222 root@127.0.0.1" SCP_RUN_SCP="scp -P 2222" SCP_RUN_DEST="root@127.0.0.1:" \
  SCP_RUN_CORE=/data/var/dumper demo/scp-baseline.sh ~/scp-work
```

## The one change to the clone

cJSON registers its tests with a path (`add_test(NAME parse_number COMMAND "./parse_number")`).
CMake applies `CMAKE_CROSSCOMPILING_EMULATOR` only to tests whose command is a target name, so with
a path `ctest` would start the QNX program on Linux. The script changes the three `add_test` lines
of the clone to use the target name and prints the change; nothing else is changed.

## What the log does not contain

No times (the script removes ctest's times) and no host paths (printed as `WORK`, `SHARE`, `REPO`).
If a test fails, the script prints only the counts, not the names or the output of failing tests.
