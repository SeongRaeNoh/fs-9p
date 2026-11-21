# fs-9p - build with the QNX SDP 8.0 toolchain (qcc). Source the SDP environment first:
#   source <SDP install dir>/qnxsdp-env.sh
# Targets: all (default), clean. Output in build/ (fs-9p, v9p_probe, errno_test, attr_test, link_test,
# writers_test).
# host-check: host-only tests that need no QNX SDP (the 9P codec table test, a fuzz run of the reply
# parser, the errno table), built with the host C compiler (HOSTCC, default cc) into build/host/ with
# AddressSanitizer and UndefinedBehaviorSanitizer; .github/workflows/host-tests.yml runs this target.

CC      = qcc
VARIANT = gcc_ntox86_64
CFLAGS  = -V$(VARIANT) -O2 -g -Wall -Wextra -Wno-unused-parameter -std=gnu11
LDLIBS  = -lpci

CORE    = src/virtio_pci.c src/virtq.c src/p9.c src/p9_errno.c
HDRS    = $(wildcard src/*.h)
B       = build

all: $(B)/fs-9p $(B)/v9p_probe $(B)/errno_test $(B)/attr_test $(B)/link_test $(B)/writers_test

$(B):
	mkdir -p $(B)

$(B)/fs-9p: src/fs9p.c $(CORE) $(HDRS) | $(B)
	$(CC) $(CFLAGS) -o $@ src/fs9p.c $(CORE) $(LDLIBS)

$(B)/v9p_probe: tools/v9p_probe.c $(CORE) $(HDRS) | $(B)
	$(CC) $(CFLAGS) -o $@ tools/v9p_probe.c $(CORE) $(LDLIBS)

$(B)/errno_test: tests/errno_test.c src/p9_errno.c src/p9_errno.h | $(B)
	$(CC) $(CFLAGS) -o $@ tests/errno_test.c src/p9_errno.c

$(B)/attr_test: tests/attr_test.c | $(B)
	$(CC) $(CFLAGS) -o $@ tests/attr_test.c

$(B)/link_test: tests/link_test.c | $(B)
	$(CC) $(CFLAGS) -o $@ tests/link_test.c

$(B)/writers_test: tests/writers_test.c | $(B)
	$(CC) $(CFLAGS) -o $@ tests/writers_test.c

clean:
	rm -rf $(B)

# host-only tests (no SDP): tests/host/ and tests/errno_test.c
HOSTCC    ?= cc
HOSTFLAGS  = -O1 -g -Wall -Wextra -Wno-unused-parameter -std=gnu11 \
             -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
FUZZ_RUNS ?= 200000
HB         = $(B)/host

$(HB):
	mkdir -p $(HB)

$(HB)/p9_test: tests/host/p9_test.c tests/host/fake_virtq.c tests/host/fake_virtq.h src/p9.c src/p9.h src/p9_errno.c | $(HB)
	$(HOSTCC) $(HOSTFLAGS) -o $@ tests/host/p9_test.c tests/host/fake_virtq.c src/p9_errno.c -lpthread

$(HB)/p9_fuzz: tests/host/p9_fuzz.c tests/host/fake_virtq.c tests/host/fake_virtq.h src/p9.c src/p9.h src/p9_errno.c | $(HB)
	$(HOSTCC) $(HOSTFLAGS) -o $@ tests/host/p9_fuzz.c tests/host/fake_virtq.c src/p9_errno.c -lpthread

$(HB)/errno_test: tests/errno_test.c src/p9_errno.c src/p9_errno.h | $(HB)
	$(HOSTCC) $(HOSTFLAGS) -o $@ tests/errno_test.c src/p9_errno.c

host-check: $(HB)/p9_test $(HB)/p9_fuzz $(HB)/errno_test
	$(HB)/p9_test
	$(HB)/p9_fuzz -runs=$(FUZZ_RUNS) -seed=1
	$(HB)/errno_test

.PHONY: all clean host-check
