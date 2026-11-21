# Upstream search behind "no public report found"

The README, `docs/oss-suite.md`, the Devpost text and gallery image 3 (`12_oss_suite.png`) say that no public report of
the libxml2 v2.15.4 `testapi` crash (a null `URI` passed to a `%s` format in
`xmlNewTextReaderFilename()`, `xmlreader.c` line 2104) was found on 2026-11-13. This file lists that
search, so a reader can repeat it.

- Date: 2026-11-13.
- Where: the libxml2 project on GNOME GitLab, through its public REST API
  (`https://gitlab.gnome.org/api/v4/projects/GNOME%2Flibxml2/...`), without logging in.
- Issues, search `xmlNewTextReaderFilename`, open and closed: #6 and #7 (2018, about
  `xmlTextReaderNext*`); neither is about a null `URI`.
- Merge requests, same search, all states: none.
- Issues, search `testapi`, open and closed: 13 issues (#1157, #888, #825, #776, #717, #678, #620,
  #554, #403, #396, #254, #214, #33); none names `xmlNewTextReaderFilename`, "failed to open" or
  `xmlreader.c`.
- Issues, search `QNX`: #825 and #372.
- Open issues, search `failed to open`: 9 issues; none is about a null `URI` or `testapi`.
- Newest issues by creation date, read down to about #1188 (newest #1205, 2026-11-10): none names
  `xmlNewTextReaderFilename`, `testapi` or a null `%s` argument.
- Master branch: the newest commit that touches `xmlreader.c` is `39b66eb2` (2026-05-12); master's
  `xmlreader.c` and `testapi.c` are byte-identical to the v2.15.4 tag.

Limits: the pages were read with an automated fetch tool, so a match could have been missed;
confidential issues are not visible to an anonymous search. If a report is filed later, its link
replaces "no public report found" in the places named above.
