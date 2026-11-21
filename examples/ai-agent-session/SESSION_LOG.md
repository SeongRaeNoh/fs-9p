# Session log: make ctest pass in the QNX 8.0 guest

Task: `TASK.md` in this folder. Result: ctest passed after 2 iterations (2 runs of
`./run_tests.sh`). No timing figures are recorded in this log.

## Preparation (no test run)

- Read `TASK.md`, all files in `src/` and `tests/`, `CMakeLists.txt`, `qnx-x86_64.cmake`,
  `run_tests.sh`, `qrun.sh`, `vm_ctl.sh`, and the usage header of
  `../../tools/qnx-run` (read only).
- Reading `src/kvserver.c` gave one suspect before any run (inferred, not yet checked):
  `do_put()` line 53 takes the message length from `info->msglen`, while the receive buffer
  `union kv_recv` holds only `KV_RECV_BYTES` = 256 bytes.
- Ran `./vm_ctl.sh status`. Saw `guest not running`.
- Ran `./vm_ctl.sh start`. Saw `ssh ready`, then
  `fs-9p 0.6.0: mount tag "hostshare" mounted at /mnt/host (...)` and the `ls -ld /mnt/host` line.
  `./vm_ctl.sh status` then printed `guest running`.

## Iteration 1: run the tests unchanged

- Ran: `./run_tests.sh` (exit status 8).
- Saw:
  ```
  1/3 Test #1: test_basic .......................   Passed
  2/3 Test #2: test_large .......................***Failed
  ok 2 - put a 1000-byte value
  not ok 3 - get returns 1000 bytes (got 220)
  ok 4 - the bytes are the bytes that were put
  ok 5 - put a value of KV_VALUE_MAX (4096) bytes
  not ok 6 - get returns the 4096 bytes (got 220)
  not ok 7 - a value of 4097 bytes is refused with E2BIG (rc 0, errno 0)
  not ok 8 - count is 2
  5 of 9 checks passed
  3/3 Test #3: test_stop ........................   Passed
  67% tests passed, 1 tests failed out of 3
  ```
- Concluded:
  - Every stored value of a long put has 220 bytes. 220 = 256 (receive buffer) - 36
    (`sizeof(struct kv_hdr)`: 2 + 2 + 32). The server therefore computes the value length from the
    bytes that fit into the receive buffer, not from the length the client sent. This matches the
    suspect in `do_put()`.
  - The 4097-byte put is accepted because its computed length is also 220, so `E2BIG` is never
    returned, and `toolong` is stored; the count is then 3, so check 8 fails.
  - Checked in the public QNX 8.0 documentation (WebFetch):
    - `_msg_info` page (`.../8.0/com.qnx.doc.neutrino.lib_ref/topic/m/_msg_info.html`):
      [paraphrased for publication; the session quoted the page] `msglen` is the number of bytes
      that were received; `srcmsglen` is the length of the message that the client sent with
      `MsgSend*()`, which can be larger than `msglen`.
    - `ChannelCreate()` page (`.../topic/c/channelcreate.html`): lists no flag that `srcmsglen`
      depends on, so no channel flag has to be added.
  - The two other uses of `info.msglen` in `server_main()` (lines 86 and 93) check that the
    type field and the header arrived in the buffer; `msglen` is correct there.
- Changed: `src/kvserver.c`, `do_put()`:
  ```diff
  -    size_t msg_bytes = info->msglen;            /* length of the client's message */
  +    size_t msg_bytes = info->srcmsglen;         /* length of the client's message (msglen is only
  +                                                   the part that fit into the receive buffer) */
  ```

## Iteration 2: run the tests with the fix

- Ran: `./run_tests.sh` (exit status 0).
- Saw: the build printed no warnings or errors, and
  ```
  1/3 Test #1: test_basic .......................   Passed
  2/3 Test #2: test_large .......................   Passed
  3/3 Test #3: test_stop ........................   Passed
  100% tests passed, 0 tests failed out of 3
  ```
- Ran: `./qrun.sh build/test_large` and `./qrun.sh build/test_basic` to see every check.
- Saw: `ok 3 - get returns 1000 bytes (got 1000)`, `ok 6 - get returns the 4096 bytes (got 4096)`,
  `ok 7 - a value of 4097 bytes is refused with E2BIG (rc -1, errno 7)`, `ok 8 - count is 2`,
  `9 of 9 checks passed`, `exit status 0`; for test_basic: `16 of 16 checks passed`,
  `exit status 0`.
- Concluded: the cause is fixed; all checks of all three tests pass. No further change.
- Changed: nothing.

## End

- Why the failure appeared only on QNX: the code builds only with `qcc`, so it never ran outside
  the guest, and a compiler cannot tell `msglen` from `srcmsglen` (both are valid fields of the
  same type). The difference is QNX kernel run-time behaviour: `MsgReceive()` copies at most the
  256-byte receive buffer and reports the copied size in `msglen`. When a message fits into the
  buffer, `msglen` equals `srcmsglen`; `test_basic` sends at most a 236-byte message (200-byte
  value), so it passed with the bug. Only `test_large` sends messages longer than 256 bytes.
- Tried to write `REPORT.md` with the Write tool; the tool refused it ("Subagents should return
  findings as text, not write report files"). `REPORT.md` was therefore not written by this
  session; its content (cause, diff, explanation, run count, last output lines) is in this log
  and in the final message to the caller.
- Ran `./vm_ctl.sh stop`. Saw `stopped`. `./vm_ctl.sh status` then printed `guest not running`.
