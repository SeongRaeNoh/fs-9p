# An AI coding agent fixes a QNX-only bug through `tools/qnx-run`

**Earlier session, kept as history.** This session fixed a bug that another agent planted on
purpose, and it ran with fs-9p 0.6.0. The later recorded session fixes a crash that libxml2's own
tests found in the guest, with fs-9p 0.10.0:
[../ai-agent-session-libxml2/](../ai-agent-session-libxml2/).

A fresh AI coding agent got `TASK.md` and this small QNX 8.0 project, in which 1 of 3 ctest tests
failed in the QNX guest. It ran `./run_tests.sh` twice: the first run showed the failing checks,
the agent changed one line of `src/kvserver.c`, and the second run passed 3 of 3 tests. The test
files and the CMake files have the same sha256 before and after the session.

## What happened

- **The project.** kvstore: a server thread keeps a key-value table and answers QNX messages; the
  client functions send one message per call; a pulse stops the server. The code uses QNX kernel
  calls, so it builds only with `qcc` and runs only on QNX. Another AI agent wrote the project for
  this test and put one bug into `src/kvserver.c` on purpose. It kept the bug, the fix and the file
  hashes in a file that the fixing agent was not given.
- **The fixing agent.** A Claude Code subagent (model id `claude-opus-5-5` in its transcript),
  started with no earlier conversation. Its launch prompt named `TASK.md` and asked for a session
  log (prompt and all 15 tool calls: [TOOL_CALLS.md](TOOL_CALLS.md)). The tool calls opened only
  this folder, the header of `tools/qnx-run` and two public QNX 8.0 documentation pages.
- **Run 1** ([logs/run1.txt](logs/run1.txt)): `test_large` failed with 5 of 9 checks passed, for
  example `not ok 3 - get returns 1000 bytes (got 220)` and
  `not ok 7 - a value of 4097 bytes is refused with E2BIG (rc 0, errno 0)`.
- **The cause** ([SESSION_LOG.md](SESSION_LOG.md), iteration 1): every long value came back with
  220 bytes, and 220 = 256 (the server's receive buffer) - 36 (the message header). `do_put()` took
  the message length from `info->msglen`, the number of bytes that `MsgReceive()` copied into the
  buffer, instead of `info->srcmsglen`, the length that the client sent. The agent checked both
  fields on the public QNX 8.0 page of
  [`_msg_info`](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/m/_msg_info.html).
- **The fix** ([fix.diff](fix.diff)): `info->msglen` became `info->srcmsglen` in one line; the
  agent's new comment continues on a second line.
- **Run 2** ([logs/run2.txt](logs/run2.txt)): `100% tests passed, 0 tests failed out of 3`. Then
  `./qrun.sh` ran two test binaries directly: 9 of 9 and 16 of 16 checks
  ([logs/qrun_after_fix.txt](logs/qrun_after_fix.txt)).
- **Why only on QNX** (the agent's explanation in `SESSION_LOG.md`): a compiler accepts both
  fields; the difference is run-time behaviour of the QNX kernel. A message that fits into the
  256-byte buffer has `msglen` equal to `srcmsglen`, so `test_basic` (values up to 200 bytes) passed
  with the bug; only `test_large` sends longer messages.
- **Session log**: `SESSION_LOG.md`, written by the agent at the end of the session (calls 14 and
  15 in `TOOL_CALLS.md`; call 13, a first write under the name `REPORT.md`, was refused by the
  agent's file tool). The `logs/` files are the raw outputs of its commands.

## Tests unchanged

The author of the project recorded the first 16 hex digits of each sha256 before the session. After
the session the files had the same values; the files in this folder have them too (`sha256sum`).

| File | sha256 (first 16 hex digits) |
|---|---|
| `tests/check.h` | `3c0656ebbad48486` |
| `tests/test_basic.c` | `b227c8b03d9a72ee` |
| `tests/test_large.c` | `1e834b99e92a6fe2` |
| `tests/test_stop.c` | `84927261ea1e8263` |
| `CMakeLists.txt` | `826d0363e1745830` |
| `qnx-x86_64.cmake` | `ff05275621aeb1ee` |
| `session-scripts/run_tests.sh`, `qrun.sh`, `vm_ctl.sh` | `d64a49e8226aef4e`, `09b2633d1446af04`, `d67dbdca494ab0da` |
| `src/kvserver.c` as handed over (this folder, with the bug) | `9d1e827d41ba2fe8` |
| `src/kvserver.c` after the session (this folder plus `fix.diff`) | `5c3a7baaa996a8b0` |

The other source files (`src/kv.h`, `src/kv_proto.h`, `src/kvclient.c`) were not changed.

## Files

| File | Content |
|---|---|
| `TASK.md` | the task as the agent got it (paths replaced, see below) |
| `SESSION_LOG.md` | the agent's log of the session (one path and one quotation replaced, see below) |
| `TOOL_CALLS.md` | the launch prompt and the 15 tool calls |
| `fix.diff` | the agent's change; `patch -p1 < fix.diff` in this folder applies it |
| `logs/` | complete output of the two `./run_tests.sh` runs and of the `./qrun.sh` call |
| `src/`, `tests/`, `CMakeLists.txt`, `qnx-x86_64.cmake` | the project as handed over, with the bug |
| `run_tests.sh`, `qrun.sh`, `vm_ctl.sh`, `env.example` | the scripts, for your machine |
| `session-scripts/` | the scripts exactly as the session ran them; they call a VM script of the lab that is not published |

## Run it yourself

Needs what the repository's "Run unit tests in the guest from the host" section needs: QNX SDP 8.0,
QEMU with KVM, CMake 3.21 or newer, and an image made with `SSH_IDENT`.

```sh
cp env.example env.local      # then set REPO, SDP_ENV, IMAGE, SHARE, SSH_PORT, SSH_KEY
./vm_ctl.sh start             # boots the image with tools/qnx-share.sh in the background
./run_tests.sh                # 1 of 3 tests fails (test_large)
patch -p1 < fix.diff
./run_tests.sh                # 3 of 3 tests pass
./vm_ctl.sh stop
```

To repeat the experiment with your own agent, copy this folder without `fix.diff`, `SESSION_LOG.md`,
`TOOL_CALLS.md`, `logs/` and this README, and give the agent `TASK.md`.

## Changes made for publication

- `run_tests.sh`, `qrun.sh` and `vm_ctl.sh` differ from `session-scripts/`: an empty `BUILD_HOST`
  runs the commands on your machine; `vm_ctl.sh` starts the guest with `tools/qnx-share.sh` from an
  image of `tools/make-image.sh`, which mounts the share at boot; the session's script used a lab VM
  script, a second shared folder and a copy of fs-9p in the guest's `/tmp`. The reader versions
  were checked with stand-in commands for ssh, cmake, ctest and QEMU, not with QNX.
- `TASK.md`: the absolute path of `tools/qnx-run` and of `docs/usage.md` became `../../tools/qnx-run`
  and `../../docs/usage.md`; one folder of the session machine became `[workspace]`.
- `SESSION_LOG.md`: `../../entries/fs-9p/tools/qnx-run` became `../../tools/qnx-run`; two sentences
  that the agent quoted from the QNX documentation page are paraphrased, because this repository
  contains no QNX documentation text. The paraphrase is marked in the log.
- `TOOL_CALLS.md`: absolute paths are replaced by names in brackets.
- The session's `env.local` (settings of the lab) is not published.
