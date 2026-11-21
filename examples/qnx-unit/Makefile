# examples/qnx-unit - unit tests built with qcc on the host and run inside the QNX 8.0 guest by
# tools/qnx-run, without copying. Keep the build folder B inside the shared folder (QNX_SHARE).
#   make            build the tests with qcc (source qnxsdp-env.sh first), and stuck_receive, a
#                   program that never ends (for tools/qnx-run -t; not part of qnx-test)
#   make qnx-test   run every test in the guest; JUnit XML files go to $(B)/junit/
#   make coverage   build the tests with gcov counters into $(B)/cov and run them in the guest; the
#                   gcov runtime in the guest writes the .gcda files through the share into
#                   $(B)/cov on the host (GCOV_PREFIX, GCOV_PREFIX_STRIP); then a gcovr report
#                   ($(B)/cov/coverage.txt and $(B)/cov/html/index.html), or a gcov summary
#                   when gcovr is not installed
# Settings: QNX_SHARE (required by qnx-run), QNX_SSH or QNX_SSH_PORT, QNX_MOUNT (see tools/qnx-run -h);
# for coverage: GCOVR (default gcovr, for example "python3 -m gcovr"), GCOV (default ntox86_64-gcov
# of QNX SDP 8.0). qcc takes -fprofile-arcs -ftest-coverage (it rejects the gcc driver option --coverage).
# The same tests with CMake: see CMakeLists.txt (ctest uses qnx-run as the test emulator).
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
HERE    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
QNX_RUN ?= $(abspath $(HERE)../../tools/qnx-run)
CC      = qcc
CFLAGS  = -Vgcc_ntox86_64 -O2 -g -Wall -Wextra -std=gnu11
B       ?= build
TESTS   = test_ring test_msg test_pulse
COV     = $(B)/cov
GCOV    ?= ntox86_64-gcov
GCOVR   ?= gcovr
COVFLAGS = -Vgcc_ntox86_64 -O0 -g -std=gnu11 -fprofile-arcs -ftest-coverage -fprofile-update=atomic
SHARE_DIR = $(abspath $(or $(QNX_SHARE),$(shell cat "$(QNX_IMAGE)/qnx-vm/share" 2>/dev/null)))

all: $(addprefix $(B)/,$(TESTS) exit_status stuck_receive)

$(B):
	mkdir -p $(B)

$(B)/%: $(HERE)tests/%.c $(HERE)tests/check.h | $(B)
	$(CC) $(CFLAGS) -o $@ $<

# Every test runs in the guest; a failing test does not stop the others. The last two runs check
# the runner itself: the exit status 3 of a program must reach make unchanged, and a host path
# argument inside the share must reach the program as its guest path.
qnx-test: all
	@failed=0; \
	for t in $(TESTS); do \
	    echo "== $$t (in the QNX guest)"; \
	    $(QNX_RUN) -j $(B)/junit/$$t.xml -n $$t $(B)/$$t || { echo "FAILED: $$t, exit status $$?"; failed=$$((failed + 1)); }; \
	done; \
	echo "== exit_status 3 (must return 3)"; \
	$(QNX_RUN) $(B)/exit_status 3; rc=$$?; \
	if [ $$rc = 3 ]; then echo "exit status 3 reached make"; else echo "FAILED: exit status $$rc, expected 3"; failed=$$((failed + 1)); fi; \
	echo "== exit_status 0 with the host path of a file in B (host path argument)"; \
	$(QNX_RUN) $(B)/exit_status 0 $(abspath $(B))/exit_status || { echo "FAILED: host path argument"; failed=$$((failed + 1)); }; \
	echo "qnx-test: $$failed failed"; [ $$failed = 0 ]

# Coverage. The object path is absolute, so each .gcda path is the host path of $(COV)/NAME.gcda.
# In the guest, GCOV_PREFIX_STRIP drops the components of the share's host path and GCOV_PREFIX
# puts the mountpoint in front: the file lands in the same folder, seen through /mnt/host.
$(COV)/%.o: $(HERE)tests/%.c $(HERE)tests/check.h
	@mkdir -p $(COV)
	$(CC) $(COVFLAGS) -c -o $(abspath $@) $<
$(COV)/%: $(COV)/%.o
	$(CC) $(COVFLAGS) -o $@ $<
.PRECIOUS: $(COV)/%.o

coverage: $(addprefix $(COV)/,$(TESTS))
	@[ -n "$(SHARE_DIR)" ] || { echo "coverage: set QNX_SHARE (or QNX_IMAGE of tools/qnx-vm)"; exit 2; }
	@case "$(abspath $(COV))/" in "$(SHARE_DIR)"/*) ;; *) echo "coverage: B must be inside $(SHARE_DIR)"; exit 2 ;; esac
	@rm -f $(COV)/*.gcda; failed=0; \
	strip=$$(printf '%s' "$(SHARE_DIR)" | tr -cd / | wc -c); \
	for t in $(TESTS); do \
	    echo "== $$t (in the QNX guest, with gcov counters)"; \
	    $(QNX_RUN) -e GCOV_PREFIX=$${QNX_MOUNT:-/mnt/host} -e GCOV_PREFIX_STRIP=$$strip $(COV)/$$t || failed=$$((failed + 1)); \
	done; \
	echo "coverage: $$(ls $(COV)/*.gcda 2>/dev/null | wc -l) .gcda files written by the guest into $(COV)"; \
	if command -v $(firstword $(GCOVR)) >/dev/null 2>&1; then \
	    mkdir -p $(COV)/html; \
	    $(GCOVR) --gcov-executable $(GCOV) -r $(HERE) --filter '$(HERE)tests/' --txt $(COV)/coverage.txt \
	        --html-details $(COV)/html/index.html $(COV) || failed=$$((failed + 1)); \
	    cat $(COV)/coverage.txt; echo "coverage: HTML report $(COV)/html/index.html"; \
	else \
	    echo "coverage: $(firstword $(GCOVR)) not found; gcov summary:"; \
	    for t in $(TESTS); do (cd $(COV) && $(GCOV) -n $$t.o | grep -A1 "^File '.*tests/"); done; \
	fi; \
	echo "coverage: $$failed failed"; [ $$failed = 0 ]

clean:
	rm -rf $(B)

.PHONY: all qnx-test coverage clean
