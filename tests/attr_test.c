/*
 * attr_test.c - attribute operations through fs-9p, run in the QNX guest.
 * usage: attr_test DIR UID GID GID2
 *   DIR      folder in the mounted share; the test makes one file per operation in it
 *   UID GID  owner and group of the host user who runs QEMU (QEMU may set them)
 *   GID2     another group of that host user (chgrp to it is allowed on the host)
 * Every step prints one line "STEP name rc=R errno=E (text) ..."; tests/host_side.sh checks each file
 * on the host afterwards. Files: size.bin (write, fsync, ftruncate down and up, truncate by path),
 * fmode.bin (fchmod), mode.bin (chmod), utime.bin (utime with times), utimes.bin (utimes with
 * microseconds), now.bin (utime(NULL)), own.bin (chown to UID GID, chgrp to GID2, chown to root:
 * the host refuses the last one unless QEMU runs as root), and chmod of DIR itself.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <utime.h>
#include <sys/stat.h>
#include <sys/time.h>

static void step(const char *name, int rc, const char *path)
{
    int e = rc < 0 ? errno : 0;
    struct stat st;
    if (stat(path, &st) == 0)
        printf("STEP %s rc=%d errno=%d (%s) size=%lld mode=%o uid=%d gid=%d atime=%lld mtime=%lld\n", name, rc, e,
               e ? strerror(e) : "ok", (long long)st.st_size, (unsigned)(st.st_mode & 07777), (int)st.st_uid,
               (int)st.st_gid, (long long)st.st_atime, (long long)st.st_mtime);
    else
        printf("STEP %s rc=%d errno=%d (%s) stat failed: %s\n", name, rc, e, e ? strerror(e) : "ok", strerror(errno));
    fflush(stdout);
}

static int mkfile(const char *dir, const char *name, char *path, size_t len)
{
    snprintf(path, len, "%s/%s", dir, name);
    unlink(path);
    return open(path, O_CREAT | O_RDWR | O_TRUNC, 0644);
}

int main(int argc, char **argv)
{
    if (argc != 5) { fprintf(stderr, "usage: %s DIR UID GID GID2\n", argv[0]); return 2; }
    const char *dir = argv[1];
    uid_t uid = (uid_t)atoi(argv[2]); gid_t gid = (gid_t)atoi(argv[3]), gid2 = (gid_t)atoi(argv[4]);
    char p[1024];
    struct stat st;

    int fd = mkfile(dir, "size.bin", p, sizeof p);
    if (fd < 0) { perror("open"); return 1; }
    step("write_10", write(fd, "0123456789", 10) == 10 ? 0 : -1, p);
    step("fsync", fsync(fd), p);
    step("ftruncate_4", ftruncate(fd, 4), p);
    step("ftruncate_10000", ftruncate(fd, 10000), p);
    step("fstat_size_is_10000", fstat(fd, &st) == 0 && st.st_size == 10000 ? 0 : -1, p);
    close(fd);
    step("truncate_6000", truncate(p, 6000), p);

    fd = mkfile(dir, "fmode.bin", p, sizeof p);
    step("fchmod_600", fchmod(fd, 0600), p);
    close(fd);
    close(mkfile(dir, "mode.bin", p, sizeof p));
    step("chmod_640", chmod(p, 0640), p);

    close(mkfile(dir, "utime.bin", p, sizeof p));
    struct utimbuf ub = { .actime = 1000000000, .modtime = 1200000000 };
    step("utime_1000000000_1200000000", utime(p, &ub), p);
    close(mkfile(dir, "utimes.bin", p, sizeof p));
    struct timeval tv[2] = { { 1300000000, 250000 }, { 1400000000, 500000 } };
    step("utimes_1300000000.25_1400000000.5", utimes(p, tv), p);
    close(mkfile(dir, "now.bin", p, sizeof p));
    ub.actime = ub.modtime = 1000000000;
    utime(p, &ub);
    step("utime_NULL_now", utime(p, NULL), p);

    close(mkfile(dir, "own.bin", p, sizeof p));
    step("chown_own_ids", chown(p, uid, gid), p);
    step("chgrp_gid2", chown(p, (uid_t)-1, gid2), p);
    step("chown_root_refused", chown(p, 0, 0), p);

    step("chmod_dir_750", chmod(dir, 0750), dir);
    printf("RESULT: attr_test done\n");
    return 0;
}
