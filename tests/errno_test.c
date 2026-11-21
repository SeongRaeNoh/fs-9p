/*
 * errno_test.c - table test of the Linux-to-QNX errno mapping (run on the QNX target).
 * The expected pairs below are written independently of src/p9_errno.c (Linux numbers from the
 * Linux UAPI headers asm-generic/errno-base.h and errno.h; QNX values by name from <errno.h>).
 *
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "../src/p9_errno.h"

static const struct { unsigned lnx; int qnx; const char *name; } expect[] = {
    { 1, EPERM, "EPERM" }, { 2, ENOENT, "ENOENT" }, { 5, EIO, "EIO" }, { 9, EBADF, "EBADF" },
    { 11, EAGAIN, "EAGAIN" }, { 12, ENOMEM, "ENOMEM" }, { 13, EACCES, "EACCES" }, { 16, EBUSY, "EBUSY" },
    { 17, EEXIST, "EEXIST" }, { 18, EXDEV, "EXDEV" }, { 20, ENOTDIR, "ENOTDIR" }, { 21, EISDIR, "EISDIR" },
    { 22, EINVAL, "EINVAL" }, { 24, EMFILE, "EMFILE" }, { 27, EFBIG, "EFBIG" }, { 28, ENOSPC, "ENOSPC" },
    { 30, EROFS, "EROFS" }, { 31, EMLINK, "EMLINK" }, { 34, ERANGE, "ERANGE" },
    { 35, EDEADLK, "EDEADLK" }, { 36, ENAMETOOLONG, "ENAMETOOLONG" }, { 37, ENOLCK, "ENOLCK" },
    { 38, ENOSYS, "ENOSYS" }, { 39, ENOTEMPTY, "ENOTEMPTY" }, { 40, ELOOP, "ELOOP" },
    { 61, ENODATA, "ENODATA" }, { 71, EPROTO, "EPROTO" }, { 75, EOVERFLOW, "EOVERFLOW" },
    { 84, EILSEQ, "EILSEQ" }, { 95, ENOTSUP, "ENOTSUP" }, { 110, ETIMEDOUT, "ETIMEDOUT" },
    { 116, ESTALE, "ESTALE" }, { 122, EDQUOT, "EDQUOT" }, { 125, ECANCELED, "ECANCELED" },
    { 0, EIO, "unknown 0 -> EIO" }, { 58, EIO, "unused 58 -> EIO" }, { 9999, EIO, "unknown 9999 -> EIO" },
};

int main(void)
{
    int fail = 0, n = 0;
    for (unsigned i = 0; i < sizeof expect / sizeof expect[0]; i++, n++) {
        int got = p9_errno_to_qnx(expect[i].lnx);
        int ok = got == expect[i].qnx;
        printf("%s linux %4u %-22s -> qnx %3d \"%s\"\n", ok ? "ok  " : "FAIL", expect[i].lnx, expect[i].name, got, strerror(got));
        fail += !ok;
    }
    /* every table row: no duplicate Linux value, QNX value has a message */
    for (unsigned i = 0; i < p9_errno_table_len; i++, n++) {
        for (unsigned j = i + 1; j < p9_errno_table_len; j++)
            if (p9_errno_table[i].linux_errno == p9_errno_table[j].linux_errno) { printf("FAIL duplicate linux %d\n", p9_errno_table[i].linux_errno); fail++; }
        if (p9_errno_table[i].qnx_errno <= 0) { printf("FAIL %s maps to %d\n", p9_errno_table[i].name, p9_errno_table[i].qnx_errno); fail++; }
    }
    const char *msg = strerror(p9_errno_to_qnx(2));
    int ok = strcmp(msg, "No such file or directory") == 0;
    printf("%s strerror(map(2)) = \"%s\"\n", ok ? "ok  " : "FAIL", msg); fail += !ok; n++;
    printf("errno_test: %u table rows, %d checks, %d failures\n", p9_errno_table_len, n, fail);
    printf("RESULT: errno table test %s\n", fail ? "FAILED" : "passed");
    return fail ? 1 : 0;
}
