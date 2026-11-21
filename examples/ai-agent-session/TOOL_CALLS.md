# The fixing agent's launch prompt and tool calls

Extracted from the session transcript of the fixing agent (a Claude Code subagent; model id
`claude-opus-5-5` in the transcript). The transcript itself is not published: it contains the
text of two QNX documentation pages that the agent fetched. Absolute paths of the session machine
are replaced by names in brackets: `[session folder]` is the folder that is now
`examples/ai-agent-session/`, `[fs-9p repository]` is this repository, `[scratch folder]` is a
temporary folder of the agent, `[workspace]` and `[private folder]` are folders of the session
machine. Nothing else is changed.

## Launch prompt (complete)

```text
You are an AI coding agent. Your task is in [session folder]/TASK.md . Read it and do it, following its rules exactly.

Additional rules for this session:
- Keep a session log in [session folder]/SESSION_LOG.md as you work: for each iteration, what you ran (command), what you saw (the relevant output lines, no timing figures), what you concluded, and what you changed (file and a short diff). Number the iterations. This log may be published, so write it in plain English and keep it factual.
- Do not open [private folder]/ or any folder under [workspace]/ other than the two the task names.
- If your context passes about 150k tokens, write the log and end.
- Final message: whether ctest passed, the number of iterations, the cause you found and the fix, in under 200 words.
```

## Tool calls (all 15, in order)

The input column is the command or path as the agent sent it. The result column is a short
description of what came back, written when this file was made; the `logs/` files are the
complete outputs of calls 5, 10 and 11.

| # | Tool | Input | Result |
|---|---|---|---|
| 1 | Bash | `cat [session folder]/TASK.md; echo ---; ls -la [session folder]/` | TASK.md and the folder listing |
| 2 | Bash | `cd [session folder]/ && for f in src/* tests/* CMakeLists.txt qnx-x86_64.cmake run_tests.sh qrun.sh vm_ctl.sh; do echo "=== $f"; cat -n "$f"; done` | the files of `src/`, `tests/`, the CMake files and the three scripts |
| 3 | Bash | `cd [session folder]/ && ./vm_ctl.sh status; echo "rc=$?"; echo ---; sed -n 1,40p [fs-9p repository]/tools/qnx-run` | `guest not running`; the header of `tools/qnx-run` |
| 4 | Bash | `cd [session folder]/ && ./vm_ctl.sh start; echo "rc=$?"; ./vm_ctl.sh status; echo "rc=$?"` | `ssh ready`, fs-9p's line `mount tag "hostshare" mounted at /mnt/host (...)`, the `ls -ld /mnt/host` line, `guest running` |
| 5 | Bash | `cd [session folder]/ && ./run_tests.sh > [scratch folder]/run1.txt 2>&1; echo "rc=$?"; wc -l [scratch folder]/run1.txt; head -80 [scratch folder]/run1.txt` | exit status 8; the output is `logs/run1.txt` (1 of 3 tests failed) |
| 6 | ToolSearch | `select:WebFetch` | loads the WebFetch tool |
| 7 | WebFetch | https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/m/_msg_info.html | the public QNX 8.0 page of `_msg_info` (page text not published here) |
| 8 | WebFetch | https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/c/channelcreate.html | the public QNX 8.0 page of `ChannelCreate()` (page text not published here) |
| 9 | Edit | `[session folder]/src/kvserver.c` | `src/kvserver.c` changed; the change is `fix.diff` |
| 10 | Bash | `cd [session folder]/ && ./run_tests.sh > [scratch folder]/run2.txt 2>&1; echo "rc=$?"; cat [scratch folder]/run2.txt` | exit status 0; the output is `logs/run2.txt` (3 of 3 tests passed) |
| 11 | Bash | `cd [session folder]/ && ./qrun.sh build/test_large; ./qrun.sh build/test_basic \| tail -3` | `logs/qrun_after_fix.txt` (9 of 9 and 16 of 16 checks, exit status 0) |
| 12 | Bash | `cd [session folder]/ && ./vm_ctl.sh stop; echo "rc=$?"; ./vm_ctl.sh status; sed -n 49,70p src/kvserver.c` | `stopped`, `guest not running`, lines 49-70 of the changed `src/kvserver.c` |
| 13 | Write | `[session folder]/REPORT.md` | refused by the tool: "Subagents should return findings as text, not write report files. Include this content in your final response instead." |
| 14 | Write | `[session folder]/SESSION_LOG.md` | `SESSION_LOG.md` written |
| 15 | Edit | `[session folder]/SESSION_LOG.md` | `SESSION_LOG.md`: the line "Wrote `REPORT.md` in this folder." replaced by the paragraph on why the failure appeared only on QNX and the note that `REPORT.md` was refused |
