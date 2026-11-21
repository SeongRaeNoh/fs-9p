# Files before and after the session

sha256, first 16 hex digits. "Before" was recorded when the task folder was made, before the session (`setup/before_libxml2.sha256` of the task folder, all 3890 files of the clone); "after" was computed by `make_example.py` after the session.

| File | Before | After |
|---|---|---|
| `testapi.c` | `d1757834551b3676` | `d1757834551b3676` |
| `runtest.c` | `4c0e05c3ba71326d` | `4c0e05c3ba71326d` |
| `runsuite.c` | `36b6e168cddcb2ad` | `36b6e168cddcb2ad` |
| `runxmlconf.c` | `11ad9ee328e17182` | `11ad9ee328e17182` |
| `testcatalog.c` | `3d0283d9e4c5dc4a` | `3d0283d9e4c5dc4a` |
| `testchar.c` | `9bc0e15a9c3f41e2` | `9bc0e15a9c3f41e2` |
| `testdict.c` | `450ccb5794d5017e` | `450ccb5794d5017e` |
| `testparser.c` | `bb0c69a966c61598` | `bb0c69a966c61598` |
| `testrecurse.c` | `9416455de231d538` | `9416455de231d538` |
| `testlimits.c` | `3c3c40057443601e` | `3c3c40057443601e` |
| `testModule.c` | `88b9867b758152bd` | `88b9867b758152bd` |
| `testdso.c` | `081394d3a4df71e7` | `081394d3a4df71e7` |
| `CMakeLists.txt` | `7eaa7ede8fcb6585` | `7eaa7ede8fcb6585` |
| `test/` (1469 files) | | 1469 of 1469 unchanged |
| `result/` (1982 files) | | 1982 of 1982 unchanged |

Changed by the session (the change is `fix.diff`):

| File | Before | After |
|---|---|---|
| `xmlreader.c` | `c6820eb7f3563845` | `feecaa1755eb6697` |

Files handed to the agent (`setup/session_files.sha256`), unchanged after the session:

| File | sha256 | After |
|---|---|---|
| `TASK.md` | `6c2ff505e60c6ff8` | `6c2ff505e60c6ff8` |
| `run.sh` | `113f300ddb7cd0ee` | `113f300ddb7cd0ee` |
| `server/srv.sh` | `cc57277a74e7e474` | `cc57277a74e7e474` |
| `fs-9p/README.md` | `cb73fadc3d78a572` | `cb73fadc3d78a572` |
| `fs-9p/AGENTS.md` | `ef8b2125301435e4` | `ef8b2125301435e4` |
| `fs-9p/docs/usage.md` | `bbec19037e3f1681` | `bbec19037e3f1681` |
| `fs-9p/tools/qnx-ci.sh` | `04b3f67d2051c1d4` | `04b3f67d2051c1d4` |
| `fs-9p/tools/qnx-run` | `4724b7611567b0ac` | `4724b7611567b0ac` |
| `fs-9p/tools/qnx-vm` | `5f0061d1544b0b9c` | `5f0061d1544b0b9c` |
| `fs-9p/tools/qnx-share.sh` | `6cb981c25a4af4bd` | `6cb981c25a4af4bd` |
| `fs-9p/examples/qnx-unit/qnx-x86_64.cmake` | `8c54a1d8750f7049` | `8c54a1d8750f7049` |
