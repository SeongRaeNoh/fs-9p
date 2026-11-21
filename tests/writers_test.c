/*
 * writers_test.c - many forked processes write records into one file of the share while the parent
 * kills some of them with SIGKILL at random points; run in the QNX guest.
 * usage: writers_test FILE MODE WRITERS RECORDS KILLS SEED
 *   FILE     file in the mounted share; created or truncated
 *   MODE     shared: the parent opens FILE and every child writes through the inherited descriptor
 *            (one open file and one file offset for all, as when a test framework forks test
 *            processes that write into a file of their parent);
 *            append: every child opens FILE itself with O_APPEND
 *   WRITERS  number of child processes (at most 1000); RECORDS: records per child (at most 100000)
 *   KILLS    number of children that get SIGKILL, each after a random delay of 0 to 5 ms after the
 *            previous kill; SEED: seed of these choices. The children start writing together when
 *            the parent has forked the last one (they wait for the end of a pipe), and the first
 *            kill follows that start, so that most kills reach a child while it writes.
 * A record is 64 bytes: "w%04u r%05u " (writer and record number), 50 letters that follow from
 * both numbers, and a newline; a child writes its records in order with one write() each and exits
 * with status 1 at the first write() that does not return 64 (it prints the errno first).
 * After all children have ended, the parent reads FILE back and checks: the size is a multiple of
 * 64; every record is whole and correct; no record is there twice; each writer's records are in
 * order and form a prefix (records 0 to n-1); a child that exited with 0 has all its records.
 * Output: one line per child that did not exit with 0, the counts, and the last line
 * "RESULT: writers_test passed" or "RESULT: writers_test failed (...)".
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

#define REC 64
#define PAT 50

static void make_record(char *b, unsigned w, unsigned r)
{
    char h[32];
    snprintf(h, sizeof h, "w%04u r%05u ", w % 10000u, r % 100000u);
    memcpy(b, h, 13);
    for (unsigned i = 0; i < PAT; i++) b[13 + i] = (char)('a' + (w * 31u + r * 7u + i) % 26u);
    b[REC - 1] = '\n';
}

static unsigned long long rng;
static unsigned next_rand(void)
{
    rng = rng * 6364136223846793005ull + 1442695040888963407ull;
    return (unsigned)(rng >> 33);
}

static void writer(const char *file, int fd, int append, unsigned w, unsigned nrec, int go)
{
    char c;
    while (read(go, &c, 1) < 0 && errno == EINTR) {}   /* end of file: the parent has forked every child */
    close(go);
    if (append) {
        fd = open(file, O_WRONLY | O_APPEND);
        if (fd < 0) { fprintf(stderr, "writer %u: open: errno %d (%s)\n", w, errno, strerror(errno)); _exit(1); }
    }
    char b[REC];
    for (unsigned r = 0; r < nrec; r++) {
        make_record(b, w, r);
        ssize_t n = write(fd, b, REC);
        if (n != REC) {
            fprintf(stderr, "writer %u record %u: write returned %zd, errno %d (%s)\n", w, r, n, n < 0 ? errno : 0,
                    n < 0 ? strerror(errno) : "short write");
            _exit(1);
        }
    }
    _exit(0);
}

int main(int argc, char **argv)
{
    if (argc != 7) { fprintf(stderr, "usage: writers_test FILE shared|append WRITERS RECORDS KILLS SEED\n"); return 2; }
    const char *file = argv[1];
    int append = strcmp(argv[2], "append") == 0;
    if (!append && strcmp(argv[2], "shared") != 0) { fprintf(stderr, "writers_test: MODE is shared or append\n"); return 2; }
    unsigned nw = (unsigned)strtoul(argv[3], NULL, 10), nrec = (unsigned)strtoul(argv[4], NULL, 10);
    unsigned nkill = (unsigned)strtoul(argv[5], NULL, 10);
    rng = strtoull(argv[6], NULL, 10);
    if (nw == 0 || nw > 1000 || nrec == 0 || nrec > 100000 || nkill > nw) { fprintf(stderr, "writers_test: bad counts\n"); return 2; }

    int fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { printf("open %s: errno %d (%s)\nRESULT: writers_test failed (open)\n", file, errno, strerror(errno)); return 1; }
    if (append) close(fd);
    fflush(stdout);

    pid_t *pid = calloc(nw, sizeof *pid);
    int *status = calloc(nw, sizeof *status);
    unsigned *order = calloc(nw, sizeof *order);
    if (!pid || !status || !order) return 1;
    unsigned nfork_fail = 0;
    int gp[2];
    if (pipe(gp) != 0) { printf("pipe: errno %d\nRESULT: writers_test failed (pipe)\n", errno); return 1; }
    for (unsigned w = 0; w < nw; w++) {
        pid[w] = fork();
        if (pid[w] == 0) { close(gp[1]); writer(file, fd, append, w, nrec, gp[0]); }
        if (pid[w] < 0) { printf("fork of writer %u: errno %d (%s)\n", w, errno, strerror(errno)); nfork_fail++; }
    }
    if (!append) close(fd);
    close(gp[0]);
    close(gp[1]);     /* start: every child's read() returns 0 */
    /* KILLS distinct writers in random order, each after a random delay of 0-5 ms */
    for (unsigned w = 0; w < nw; w++) order[w] = w;
    for (unsigned i = nw - 1; i > 0; i--) { unsigned j = next_rand() % (i + 1), t = order[i]; order[i] = order[j]; order[j] = t; }
    for (unsigned k = 0; k < nkill; k++) {
        struct timespec ts = { 0, (long)(next_rand() % 5001u) * 1000L };
        nanosleep(&ts, NULL);
        if (pid[order[k]] > 0) kill(pid[order[k]], SIGKILL);
    }
    unsigned nfin = 0, nkilled = 0, nerr = 0;
    for (unsigned w = 0; w < nw; w++) {
        if (pid[w] <= 0) continue;
        while (waitpid(pid[w], &status[w], 0) < 0 && errno == EINTR) {}
        if (WIFEXITED(status[w]) && WEXITSTATUS(status[w]) == 0) nfin++;
        else if (WIFSIGNALED(status[w]) && WTERMSIG(status[w]) == SIGKILL) nkilled++;
        else {
            nerr++;
            if (WIFEXITED(status[w])) printf("writer %u: exit status %d\n", w, WEXITSTATUS(status[w]));
            else if (WIFSIGNALED(status[w])) printf("writer %u: signal %d\n", w, WTERMSIG(status[w]));
            else printf("writer %u: wait status 0x%x\n", w, (unsigned)status[w]);
        }
    }

    /* read the file back through the share and check every record */
    unsigned char *seen = calloc((size_t)nw * nrec, 1);
    unsigned *count = calloc(nw, sizeof *count);
    int *last = malloc(nw * sizeof *last);
    if (!seen || !count || !last) return 1;
    for (unsigned w = 0; w < nw; w++) last[w] = -1;
    unsigned long nrecs = 0, nbad = 0, ndup = 0, norder = 0, ntail = 0;
    int rfd = open(file, O_RDONLY);
    if (rfd < 0) { printf("open for reading: errno %d (%s)\nRESULT: writers_test failed (read back)\n", errno, strerror(errno)); return 1; }
    char b[REC], want[REC];
    for (;;) {
        size_t got = 0;
        while (got < REC) {
            ssize_t n = read(rfd, b + got, REC - got);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            got += (size_t)n;
        }
        if (got == 0) break;
        if (got < REC) { ntail = got; break; }
        nrecs++;
        unsigned w, r;
        if (sscanf(b, "w%4u r%5u ", &w, &r) != 2 || w >= nw || r >= nrec) {
            if (nbad++ < 5) printf("bad record %lu: %.40s\n", nrecs - 1, b);
            continue;
        }
        make_record(want, w, r);
        if (memcmp(b, want, REC) != 0) { if (nbad++ < 5) printf("bad record %lu: %.40s\n", nrecs - 1, b); continue; }
        if (seen[(size_t)w * nrec + r]) { if (ndup++ < 5) printf("record w%u r%u twice\n", w, r); continue; }
        seen[(size_t)w * nrec + r] = 1;
        count[w]++;
        if ((int)r != last[w] + 1) { if (norder++ < 5) printf("writer %u: record %u after record %d\n", w, r, last[w]); }
        last[w] = (int)r;
    }
    close(rfd);
    struct stat st;
    long long size = stat(file, &st) == 0 ? (long long)st.st_size : -1;
    unsigned nlost = 0, nprefix_bad = 0;
    unsigned long from_killed = 0;
    unsigned k_none = 0, k_some = 0, k_all = 0;    /* killed writers with no, some, all records */
    for (unsigned w = 0; w < nw; w++) {
        if (pid[w] <= 0) continue;
        for (unsigned r = 0; r < count[w]; r++)
            if (!seen[(size_t)w * nrec + r]) { nprefix_bad++; printf("writer %u: %u records, record %u missing\n", w, count[w], r); break; }
        if (WIFEXITED(status[w]) && WEXITSTATUS(status[w]) == 0 && count[w] != nrec) {
            if (nlost++ < 5) printf("writer %u exited with 0 but has %u of %u records in the file\n", w, count[w], nrec);
        }
        if (WIFSIGNALED(status[w])) {
            from_killed += count[w];
            if (count[w] == 0) k_none++; else if (count[w] < nrec) k_some++; else k_all++;
        }
    }
    printf("mode %s: %u writers, %u records each, %u kills sent\n", append ? "append" : "shared", nw, nrec, nkill);
    printf("writers: %u exited with 0, %u ended by SIGKILL, %u ended otherwise (write error), %u forks failed\n", nfin, nkilled, nerr, nfork_fail);
    printf("file: %lld bytes, %lu whole records, %lu bytes after the last whole record\n", size, nrecs, ntail);
    printf("records: %lu wrong, %lu twice, %lu out of order; writers with a gap: %u; writers that exited with 0 and lack records: %u\n",
           nbad, ndup, norder, nprefix_bad, nlost);
    printf("killed writers: %u with none of their records, %u with some (killed while writing), %u with all; %lu records from killed writers\n",
           k_none, k_some, k_all, from_killed);
    int okk = nerr == 0 && nfork_fail == 0 && nbad == 0 && ndup == 0 && norder == 0 && ntail == 0 && nprefix_bad == 0 && nlost == 0 &&
              size == (long long)nrecs * REC;
    printf("RESULT: writers_test %s\n", okk ? "passed" : "failed (see the counts above)");
    return okk ? 0 : 1;
}
