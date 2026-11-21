# An AI coding agent fixes the libxml2 v2.15.4 crash in the QNX 8.0 guest

A fresh AI coding agent got `TASK.md`, an unchanged clone of libxml2 v2.15.4 and fs-9p's tools.
Its first run of `tools/qnx-ci.sh` showed that libxml2's test program `testapi` crashed with SIGSEGV
in the guest, with gdb's backtrace from the core file ([logs/001-ci.txt](logs/001-ci.txt)). The
agent traced the crash to `xmlNewTextReaderFilename(NULL)`, which passes the null pointer to a `%s`
format at `xmlreader.c` line 2104, and added a null check at the top of that function: the check
that `xmlReaderNewFile()` in the same file already has ([fix.diff](fix.diff)). Its second guest run
passed 8 of 8 test programs ([logs/002-ci.txt](logs/002-ci.txt)), and the Linux reference build
still passed ([logs/003-linux.txt](logs/003-linux.txt)). The test programs, `CMakeLists.txt`,
`test/` and `result/` have the same sha256 before and after the session ([HASHES.md](HASHES.md)).

Nobody planted this bug: libxml2's own tests found it in the guest. The earlier recorded session,
on a bug planted on purpose and with fs-9p 0.6.0, is kept as history in
[../ai-agent-session/](../ai-agent-session/).

## What the agent was given

- **The agent.** A Claude Code subagent (model id `claude-opus-5-5` in its transcript), started on
  2026-11-13 with no earlier conversation. Its launch prompt is in [TOOL_CALLS.md](TOOL_CALLS.md).
  Nobody sent it a message after the launch prompt.
- **The task** ([TASK.md](TASK.md)): every test program that `tools/qnx-ci.sh` runs in the guest
  passes, and the Linux reference build still passes. Rules: no change to libxml2's test programs,
  `CMakeLists.txt`, `test/`, `result/` or the build options; no SDP files; on the web only the
  public QNX 8.0 documentation (not libxml2's repository or issue tracker); no timing figures.
- **Files.** The clone (tag v2.15.4, commit `9649899`); `run.sh` with `server/srv.sh`, its only way
  to the lab server that ran QEMU and the SDP ([session-scripts/](session-scripts/)); read-only
  copies of fs-9p's `README.md`, `AGENTS.md`, `docs/usage.md`, `tools/qnx-ci.sh`, `tools/qnx-run`,
  `tools/qnx-vm`, `tools/qnx-share.sh` and `examples/qnx-unit/qnx-x86_64.cmake`. The tool files have
  the same sha256 as this repository's at sources `ac061f948768`; the guest ran fs-9p 0.10.0
  (mount line, [logs/001-ci.txt](logs/001-ci.txt) line 7).
- **Not given.** The cause and the fix. The README copy had every passage about libxml2 removed and
  marked, because this repository's README states the cause. `TASK.md` does not say which program
  crashes; it names `testapi` only in the list of test programs that must not be edited. The copy
  of `docs/usage.md` names `testapi` in one sentence about a tracing demo; the agent printed only
  that file's line count.
- **Context from the harness.** The agent's harness also put two instruction files of the session
  machine into its context (a global instruction file and the index of a memory folder). Neither
  mentions libxml2.

## What it opened

- With the Read tool: `TASK.md`, `run.sh`, `server/srv.sh`.
- With shell commands: lines 1-80 of `tools/qnx-ci.sh` (its header), `AGENTS.md`, the outputs of
  its `run.sh` calls, the libxml2 files `xmlreader.c`, `testapi.c`, `CMakeLists.txt`,
  `config.h.cmake.in` and `include/libxml/xmlversion.h.in` (by line ranges and grep), and its own
  files in `scratch/`. Of the README copy and `docs/usage.md` it printed only the line counts.
- No web page, no file outside its task folder and no SDP file. The publication script flagged one
  path outside the folder, `/data/var/dumper`: the guest's folder for core files, quoted from a log
  in text that the agent wrote into its session log (call 30), not a file it opened.

## What happened

| Step | Calls | What the agent did | Output |
|---|---|---|---|
| Preparation | 1-6 | read the task, the runner and the header of `tools/qnx-ci.sh`; started `SESSION_LOG.md` | |
| Iteration 1 | 7-11 | `run.sh ci`: 7 of 8 passed, `testapi` crashed with SIGSEGV; `tools/qnx-ci.sh` printed gdb's backtrace from the core file: `xmlNewTextReaderFilename (URI=0x0)` at `xmlreader.c:2104`, called from `testapi.c:830`. The agent read both places. | [logs/001-ci.txt](logs/001-ci.txt) lines 19, 26, 34-47 |
| Iteration 2 | 12-25 | `testapi` stops at its first crash, so later null arguments would stay hidden. The agent built libxml2 and `testapi` with gcc on the session machine, linked with a wrapper (`scratch/nullfmt.c`, call 18) that aborts when a printf-family call gets NULL for `%s` or a file call gets a null path. The unchanged code stopped at the same call (call 21). It added the null check (call 24); the rebuilt program ran to the end with no wrapper message (call 25). This check ran on Linux only. | [SESSION_LOG.md](SESSION_LOG.md), iteration 2 |
| Iteration 3 | 26-27 | updated the log; `run.sh ci`: 8 of 8 passed, `tools/qnx-ci.sh exit status 0` | [logs/002-ci.txt](logs/002-ci.txt) lines 19, 26, 38 |
| Iteration 4 | 28-29 | `run.sh linux`: the reference build passed all its tests; `run.sh vm status`: `guest not running`; `git diff` | [logs/003-linux.txt](logs/003-linux.txt) line 53, [logs/004-vm.txt](logs/004-vm.txt) line 2 |
| Log | 30-32 | wrote the rest of `SESSION_LOG.md` and checked it | [SESSION_LOG.md](SESSION_LOG.md) |

`run.sh` calls: 4 (`ci` 2, `linux` 1, `vm status` 1). The agent made no `run`, `gdb` or `files`
call: the backtrace in the output of `tools/qnx-ci.sh` was enough.

## Every tool call

32 calls: Bash 26, Read 3, Edit 2, Write 1. Inputs in full: [TOOL_CALLS.md](TOOL_CALLS.md).

| # | Tool | What it did |
|---|---|---|
| 1 | Read | `TASK.md` |
| 2 | Bash | listed the task folder; line counts of `run.sh`, `srv.sh` and the fs-9p copies |
| 3 | Read | `run.sh` |
| 4 | Read | `server/srv.sh` |
| 5 | Bash | `tools/qnx-ci.sh` lines 1-80, `AGENTS.md`, `git status` and `git log -1` of the clone |
| 6 | Write | started `SESSION_LOG.md` |
| 7 | Bash | `run.sh ci`: exit status 1 ([logs/001-ci.txt](logs/001-ci.txt)) |
| 8 | Bash | printed `001-ci.txt` |
| 9 | Bash | `xmlreader.c` lines 2080-2125 and 180-200, `testapi.c` lines 820-835, grep for `xmlNewTextReaderFilename` in `testapi.c` |
| 10 | Bash | grep of `testapi.c` for `main` and `null`; lines 700-720 |
| 11 | Bash | `testapi.c` lines 30-90; file-name calls after line 826 |
| 12 | Bash | which compilers and CMake the session machine has; `testapi.c` lines 1380-1404 |
| 13 | Bash | file list of the clone; `config.h.cmake.in` |
| 14 | Bash | placeholders of `xmlversion.h.in`; options and source list of `CMakeLists.txt` |
| 15 | Bash | `CMakeLists.txt` excerpts (options and definitions) |
| 16 | Bash | `CMakeLists.txt` excerpts |
| 17 | Bash | placeholders of `xmlversion.h.in`; printf-family calls in `xmlstring.c` and the other sources |
| 18 | Bash | wrote `scratch/nullfmt.c`; generated `config.h` and `xmlversion.h` into `scratch/gen/` |
| 19 | Bash | checked the generated `xmlversion.h` |
| 20 | Bash | wrote `scratch/build.sh`; built libxml2 and `testapi` with gcc (exit status 0) |
| 21 | Bash | ran that `testapi` on the unchanged code: aborted at the null `%s` call |
| 22 | Bash | grep of `xmlreader.c` for `xmlTextReaderErr(`, `xmlReaderForFile` and `xmlReaderNewFile` |
| 23 | Bash | `xmlreader.c` lines 5010-5035, 5240-5285 and 5075-5105 |
| 24 | Edit | `xmlreader.c`: the null check ([fix.diff](fix.diff)) |
| 25 | Bash | rebuilt and ran that `testapi`: exit status 0 |
| 26 | Bash | added iterations 1 and 2 to `SESSION_LOG.md` |
| 27 | Bash | `run.sh ci`: exit status 0 ([logs/002-ci.txt](logs/002-ci.txt)) |
| 28 | Bash | `run.sh linux`: exit status 0 ([logs/003-linux.txt](logs/003-linux.txt)) |
| 29 | Bash | `run.sh vm status` ([logs/004-vm.txt](logs/004-vm.txt)); `git status` and `git diff` of the clone; lines 25-38 of `002-ci.txt` |
| 30 | Bash | added the result line, iterations 3 and 4 and the result section to `SESSION_LOG.md` |
| 31 | Edit | `SESSION_LOG.md`: one sentence now marks the glibc behaviour as inferred |
| 32 | Bash | checked the headings of `SESSION_LOG.md`; listed `results/calls/` |

## Tests unchanged

sha256 (first 16 hex digits) of the clone before the session (recorded for all 3,890 files when
the task folder was made) and after it. Full table, with the handed-over files: [HASHES.md](HASHES.md).

| File | Before | After |
|---|---|---|
| `testapi.c` | `d1757834551b3676` | `d1757834551b3676` |
| `runtest.c`, `runsuite.c`, `runxmlconf.c`, `testcatalog.c`, `testchar.c`, `testdict.c`, `testparser.c`, `testrecurse.c`, `testlimits.c`, `testModule.c`, `testdso.c` | [HASHES.md](HASHES.md) | unchanged |
| `CMakeLists.txt` | `7eaa7ede8fcb6585` | `7eaa7ede8fcb6585` |
| `test/` (1,469 files), `result/` (1,982 files) | | all unchanged |
| `xmlreader.c` (the only changed file) | `c6820eb7f3563845` | `feecaa1755eb6697` |

## Files

| File | Content |
|---|---|
| `TASK.md` | the task as the agent got it (one path replaced) |
| `SESSION_LOG.md` | the agent's log (redactions: see below) |
| `TOOL_CALLS.md` | the launch prompt, a table of the 32 calls and every input in full (redactions: see below) |
| `fix.diff` | the agent's change; `git apply fix.diff` in a libxml2 v2.15.4 clone applies it |
| `HASHES.md` | sha256 before and after |
| `logs/` | complete output of each `run.sh` call and the JUnit files of the two `ci` calls |
| `session-scripts/` | `run.sh` and `server/srv.sh` as the session ran them (lab paths replaced) |

## Run it yourself

Needs what `tools/qnx-ci.sh` needs (QNX SDP 8.0, QEMU with KVM, CMake 3.21 or newer) and an image
made with `tools/make-image.sh`. From the repository folder, with `IMAGE` and `SHARE` as in the
README's quick start:

```sh
git clone --depth 1 --branch v2.15.4 https://gitlab.gnome.org/GNOME/libxml2.git "$SHARE/src/libxml2"
CI_COVERAGE=0 CI_TIMEOUT=400 tools/qnx-ci.sh "$IMAGE" "$SHARE" "$SHARE/src/libxml2" \
    -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF          # testapi crashes; 7 of 8 pass
git -C "$SHARE/src/libxml2" apply "$PWD/examples/ai-agent-session-libxml2/fix.diff"
CI_COVERAGE=0 CI_TIMEOUT=400 tools/qnx-ci.sh "$IMAGE" "$SHARE" "$SHARE/src/libxml2" \
    -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF          # 8 of 8 pass
```

The session ran the same `tools/qnx-ci.sh` command with these settings through its lab runner
([logs/001-ci.txt](logs/001-ci.txt) line 3); the commands above were not run in this form.

To repeat the experiment with your own agent, give it `TASK.md`, a clone at v2.15.4 and the
repository's tools, without this folder.

## Changes made for publication

- **Statements about the QNX C library removed.** This repository publishes no result of a
  functional evaluation of a QNX component (the QNX licence does not allow it without approval).
  The agent's text said what the QNX C library does with a null `%s` argument,
  and the backtrace named the C-library functions of its frames #0 and #3. Each such statement
  and frame name is replaced by "[detail about the QNX C library removed]": 14 places, in
  `SESSION_LOG.md` (lines 17, 18, 29, 101), `TOOL_CALLS.md` (lines 43, 178, 371, 372, 383, 482),
  `logs/001-ci.txt` (lines 38, 40) and `logs/001-ci.junit.xml` (lines 169, 171). Nothing else in
  the agent's text was changed. The crash is in libxml2's code: passing a null pointer for `%s` is
  undefined behaviour in C.
- **Kept on purpose.** The agent's statements about glibc; the frame `testapi(vsnprintf+0x58)` of
  its own wrapper in the Linux build (iteration 2); its sentence that its Linux check does not cover
  other differences between the two C libraries.
- **Paths and names.** Local paths, lab paths, the lab server's name and user names are replaced by
  names in brackets; in `session-scripts/`, also the lab task folder's name, two internal labels in
  comments and the path of the image's ssh key. The runner had already printed server folders as
  `SHARE`, `IMAGE`, `REPO` and `LINUX_BUILD` and removed ctest's times.
- **Times.** In the two JUnit files, the `time` value of the test suite (a measured run time) and
  the clock time of the `timestamp` are removed (lines 8-9); this repository publishes no timing
  figures.
- **Not published.** The session transcript (it holds the harness's system prompt and every tool
  output in full) and the agent's final message (a summary of `SESSION_LOG.md`'s result section).
