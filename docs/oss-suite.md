# Open-source test suites in the QNX guest

`demo/oss-suite.sh` takes eight existing open-source C projects at fixed release tags (seven
libraries; libxml2 in two versions), builds each one with qcc, and runs the project's own `ctest` suite in the QNX 8.0 guest with
`tools/qnx-ci.sh`. Every test program starts from the shared folder through `tools/qnx-run`. The
script also builds the same sources with the host compiler and runs each suite on Linux, as a check
that the suite is complete at its tag; those counts are in the log, not in the tables below. No file
of these projects is part of this repository, and the script changes no file of their sources
(section 4 of the log counts the changed tracked files of each clone).

Each build change below works around a library's build files; the tables give the counts that
each library's own tests reported. The build changes of check and libxml2
below were checked against the project's public tracker and later releases; the libxml2 v2.13.5 crash is a known bug that upstream fixed; for
the libxml2 v2.15.4 crash no public report was found on 2026-11-13.

Log: [`tests/logs/oss_20261113_031340.log`](../tests/logs/oss_20261113_031340.log) (sources sha256 `ac061f948768` in its first line). The build
failures without the QNX-only options: [`tests/logs/oss_20261113_031620.log`](../tests/logs/oss_20261113_031620.log).

## The projects

| Project | Tag | Commit | What it is | Why it is in the set |
|---|---|---|---|---|
| [zlib](https://github.com/madler/zlib) | v1.3.1 | 51b7f2a | compression library | small suite; a common dependency |
| [libyaml](https://github.com/yaml/libyaml) | 0.2.5 | 2c891fc | YAML parser | small parser suite |
| [libdeflate](https://github.com/ebiggers/libdeflate) | v1.24 | 96836d7 | compression library | its test programs link the system zlib (`programs/CMakeLists.txt` line 74, `find_package(ZLIB)`), here the SDP's |
| [utf8proc](https://github.com/JuliaStrings/utf8proc) | v2.10.0 | a1b99da | Unicode library | its tests read Unicode data files |
| [check](https://github.com/libcheck/check) | 0.15.2 | 11970a7 | C unit-test framework | its suite uses `fork()`, signals and POSIX timers |
| [libxml2](https://gitlab.gnome.org/GNOME/libxml2) | v2.13.5 | de918d4 | XML library | its tests read their input files from the source tree, through the share |
| libxml2 (row `libxml2-2.15`) | v2.15.4 | 9649899 | the same library, a later release | its `dlopen()` check changed in v2.15.0, so it builds with its modules feature on |
| [libuv](https://github.com/libuv/libuv) | v1.53.0 | 840404c | event-loop library | its sources contain QNX code (`src/unix/qnx.c`); built only (see below) |

The QNX open-source ports site ([oss.qnx.com](https://oss.qnx.com)) lists a QNX 8.0 x86_64 build of
each of these projects. This run does not use those ports: it uses the upstream sources at the
tags above, unchanged.

## Results

Counts in the QNX guest, from the JUnit files that `ctest` wrote (log lines 219-233). A test is
one `ctest` test: one run of a test program, which can hold many test cases. No times.

| Project | run | passed | failed | skipped |
|---|---|---|---|---|
| zlib | 2 | 2 | 0 | 0 |
| libyaml | 2 | 2 | 0 | 0 |
| libdeflate | 8 | 8 | 0 | 0 |
| utf8proc | 9 | 9 | 0 | 0 |
| check | 2 | 2 | 0 | 0 |
| libxml2 v2.13.5 | 8 | 7 | 1 | 0 |
| libxml2 v2.15.4 | 8 | 7 | 1 | 0 |
| libuv | built, tests not run | - | - | - |
| total | 39 | 37 | 2 | 0 |

- libxml2 v2.13.5 and libuv were built for QNX with one QNX-only build option each, check
  with two, libxml2 v2.15.4 with none ([next section](#build-changes-and-upstream-status)). Without
  these options the QNX builds of check and libxml2 v2.13.5 fail
  ([`oss_20261113_031620.log`](../tests/logs/oss_20261113_031620.log)).
- libuv: its row has the option `--build-only`. `tools/qnx-ci.sh` configured and built libuv and its
  test programs with qcc and ran none of its 2 registered tests (log lines 193-197); its test suite
  was not run in this suite. The table shows "built, tests not run" and leaves the row out of the
  totals; the Linux run of this row is build-only as well.
- check: 7 of its 9 tests are shell scripts (`sh test_output.sh` and others). `tools/qnx-ci.sh`
  left them out, because they would run on Linux (log line 100); the 2 test programs ran in the guest.
- check is built with its own CMake option `-DCHECK_ENABLE_TIMEOUT_TESTS=OFF` (log line 96): check's
  timing-dependent self-tests are disabled in this suite, on both platforms.
- Test cases inside the test programs: the log names them where the output reports them (line 232).
  check's 2 test programs run check's own self-test suite: 1,808 checks in the guest. That suite
  tests check itself, so many of its checks fail on purpose, and check's master test compares each
  outcome with its list of expected results; both programs passed. For the other projects the log
  gives no count of test cases inside the programs.
- libxml2 v2.15.4: 14 of its 22 tests (`scripts_*` and `catalog*`) start a command that is not a
  program of the build folder; `tools/qnx-ci.sh` left them out (log line 159), and the 8 test
  programs ran in the guest. The Linux run ran all 22.
- utf8proc's 9 tests are registered without the emulator; `tools/qnx-ci.sh` put
  `tools/qnx-run` in front of them in the generated `CTestTestfile.cmake` (log line 79). zlib's
  2 tests the same (line 35).
- No file of the clones changed, except zlib's `zconf.h`, which zlib's own CMake file renames when it
  builds in another folder (log lines 209-210; zlib `CMakeLists.txt` lines 71-76).

### The tests that failed in the guest

- libxml2 v2.13.5, `testapi` (calls every public libxml2 function with many argument combinations). It
  ended with a memory fault. This is a known libxml2 bug: fs-9p reproduced it with one command and
  traced it to the line that upstream fixed in v2.13.6 (issue 825, reported from a QNX target in
  December 2024; details below). It is not a new finding.
  Traced with the core file, which the guest wrote into the share, and
  gdb on the host ([core files through the share](usage.md#core-files-through-the-share);
  [`evidence/oss_libxml2_testapi.txt`](../evidence/oss_libxml2_testapi.txt)). One command repeats
  the trace: `demo/trace-libxml2.sh IMAGE SHARE` fetches v2.13.5, builds it with qcc, and runs
  `testapi` in the guest through `tools/qnx-ci.sh`, which writes gdb's backtrace into the JUnit file
  (log [`tests/logs/trace_libxml2_20261113_031313.log`](../tests/logs/trace_libxml2_20261113_031313.log)). `testapi` calls
  `xmlParseDTD("foo", NULL)`; libxml2's `xmlSAX2ResolveEntity()` then reports "Can't resolve URI: %s"
  with the system ID, which is a null pointer
  ([SAX2.c lines 432-433](https://gitlab.gnome.org/GNOME/libxml2/-/blob/v2.13.5/SAX2.c#L432-L433)).
  ISO C requires a pointer to a string for `%s`, so a null pointer there is undefined behaviour in C; glibc prints `(null)` for a null pointer, so the
  test passes on Linux. In the guest the program stopped with SIGSEGV; the backtrace leads to
  that call.
  Upstream status (checked on 2026-11-12 in the public repository): libxml2 fixed it in v2.13.6 with
  [commit 110e44ec](https://gitlab.gnome.org/GNOME/libxml2/-/commit/110e44ec9c33096e306cdd9251029a4e54e277f9)
  ("SAX2: Fix xmlSAX2ResolveEntity if systemId is NULL"; on the master branch
  [commit 5c9abbf8](https://gitlab.gnome.org/GNOME/libxml2/-/commit/5c9abbf8)), and on the master
  branch (commit 21c8223a) `xmlSAX2ResolveEntity()` reaches the message only when `systemId` is not
  null. The upstream report, [issue 825](https://gitlab.gnome.org/GNOME/libxml2/-/issues/825), came
  from a test run on a cross-compiled QNX target in December 2024. The suite pins v2.13.5, the
  release before the fix, so this result reproduces a known bug that upstream has fixed (v2.13.6
  was released in February 2025).
- libxml2 v2.15.4, `testapi`. It ended with a memory fault as well, at another line. Its `main()`
  calls `xmlNewTextReaderFilename(NULL)` ([testapi.c line 830](https://gitlab.gnome.org/GNOME/libxml2/-/blob/v2.15.4/testapi.c#L830)), and
  `xmlNewTextReaderFilename()` passes the null `URI` to the format "failed to open %s"
  ([xmlreader.c line 2104](https://gitlab.gnome.org/GNOME/libxml2/-/blob/v2.15.4/xmlreader.c#L2104)); the backtrace in the JUnit entry has
  `xmlNewTextReaderFilename (URI=0x0) at .../xmlreader.c:2104` (log lines 176-191). As above, a null
  pointer for `%s` is undefined behaviour in C; the Linux run passed all 22 tests. Upstream status:
  observed; no public report found on 2026-11-13 (libxml2 issue tracker, open and closed issues, and
  merge requests searched; the queries are listed in [upstream-search.md](upstream-search.md)); the master branch (commit 21c8223a) has the same call at
  `xmlreader.c` line 2104.

## Build changes and upstream status

Each build change works around a portability issue of the library: its build files assume where
Linux keeps a function, or (libuv v1.51.0, an earlier run) its QNX code predated QNX 8.0. The QNX page linked for each one
names the library that has the function on QNX. The list after the table gives what each project's
public tracker and later releases show (read on 2026-11-12, libxml2 again on 2026-11-13; nobody
was contacted).

| Project | What happens with qcc | Source | QNX page | QNX-only option in `demo/oss-suite.sh` |
|---|---|---|---|---|
| check 0.15.2 | the CMake file looks for `clock_gettime()` in librt and for `struct itimerspec` in `<sys/time.h>`; both checks fail, so `lib/libcompat.h` declares its own `struct itimerspec`, `timer_settime()` and others, which conflict with `<time.h>` ("conflicting types for 'timer_settime'") | [`CMakeLists.txt` lines 299-303, 390-394](https://github.com/libcheck/check/blob/0.15.2/CMakeLists.txt#L299-L303); [`lib/libcompat.h` lines 253-273](https://github.com/libcheck/check/blob/0.15.2/lib/libcompat.h#L253-L273) | [`timer_settime()`](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/t/timer_settime.html), [`timer_create()`](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/t/timer_create.html), [`clock_gettime()`](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/c/clock_gettime.html): in libc; `timer_settime()` is declared in `<time.h>` | two build options: `-DCMAKE_C_FLAGS=-DHAVE_LIBRT=1` and `-DHAVE_STRUCT_ITIMERSPEC_IT_VALUE=1` |
| libxml2 v2.13.5 | the CMake file looks for `dlopen()` in libdl; it is not found, so `xmlmodule.c` compiles no `xmlModulePlatformOpen()` and the link of `xmllint` and the test programs fails | [`CMakeLists.txt` line 134](https://gitlab.gnome.org/GNOME/libxml2/-/blob/v2.13.5/CMakeLists.txt#L134); [`xmlmodule.c` lines 159-255](https://gitlab.gnome.org/GNOME/libxml2/-/blob/v2.13.5/xmlmodule.c#L159-L255) | [`dlopen()`](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/d/dlopen.html): in libc | `-DLIBXML2_WITH_MODULES=OFF` (the Linux build keeps modules on) |
| libuv v1.53.0 | the library builds; its test programs call `isinf()` and `isfinite()`, and libuv's CMake file links them without a math library; a trial build without `-lm` ended with undefined references to `__isinf` and `__isfinite` (that trial's log is not in this repository) | [`test/test-fs.c`](https://github.com/libuv/libuv/blob/v1.53.0/test/test-fs.c#L868) | [`isinf()`](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/i/isinf.html): in libm | `-DCMAKE_C_STANDARD_LIBRARIES=-lm` |

Upstream status of each build change:

- check: observed; no public report found on 2026-11-12. 0.15.2 (2020) is the latest release; the
  master branch still looks for `clock_gettime()` in librt (`CMakeLists.txt` line 393).
- libxml2 (`dlopen()`): observed in v2.13.5; libxml2 v2.15.0 (September 2025) changed this check to
  look for `dlopen()` with the libraries that CMake names for the platform
  ([merge request 331](https://gitlab.gnome.org/GNOME/libxml2/-/merge_requests/331), written for
  Haiku). CMake names no extra library for QNX. The v2.15.4 row shows the result: with no QNX-only
  option its QNX build has `HAVE_DLOPEN=1` and `LIBXML2_WITH_MODULES=ON` (log lines 240-241,
  printed by the row's `show:` options).
- libuv: an earlier run of this suite (its log is not in this repository) pinned v1.51.0, whose
  `src/unix/qnx.c` reads the system-page members `qtime->nsec` and `new_cpuinfo`, which QNX 8.0's
  headers do not declare; already fixed in v1.52.0 (February 2026) by
  [pull request 4801](https://github.com/libuv/libuv/pull/4801) ("Improved QNX support"), which
  answered [issue 4710](https://github.com/libuv/libuv/issues/4710) ("QNX 8.0 support?"). v1.53.0
  compiles with qcc. The missing math library of its test programs: libuv's tracker was not
  searched.

The QNX open-source ports project keeps forks of some of these libraries (for
example `qnx-ports/libuv`, branch `qnx-v1.51.0`); they are not used here.

## How the tests reach the guest

CMake starts a test through `CMAKE_CROSSCOMPILING_EMULATOR` only when the test is registered as
`add_test(NAME n COMMAND target)`. zlib and utf8proc register their tests in other forms,
so `ctest` would start the QNX programs on Linux. `tools/qnx-ci.sh` therefore reads the generated
`CTestTestfile.cmake` files after the build: a test whose command is a program of the build folder
gets `tools/qnx-run` in front of it, and a test whose command is anything else (check's shell
scripts) is left out and named ([usage](usage.md#a-teams-test-machine-toolsqnx-cish)). The
project sources stay unchanged. Every test program, data file and shared library is read by the
guest from the share; nothing is copied.

## Run it

```sh
source ~/qnx800/qnxsdp-env.sh                    # QNX SDP 8.0 (qcc)
demo/oss-suite.sh "$IMAGE" "$SHARE"              # all eight projects; IMAGE from tools/make-image.sh, no VM of it running
demo/oss-suite.sh "$IMAGE" "$SHARE" zlib check   # some of them
OSS_QNX_OPTS=0 OSS_LINUX=0 demo/oss-suite.sh "$IMAGE" "$SHARE" check libxml2   # the build failures
```

Needs git, cmake and ctest 3.21 or newer, a host C compiler, QEMU, python 3 and network access to
the repositories (utf8proc's CMake file also downloads two Unicode data files). The log names
counts and no times; host paths are printed as `SHARE`, `REPO`, `HOME`.
