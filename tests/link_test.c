/*
 * link_test.c - symbolic links and statvfs() through fs-9p, run in the QNX guest.
 * usage: link_test DIR
 *   DIR  folder in the mounted share that tests/host_side.sh prepared on the host:
 *          target.txt ("target content\n"), link.txt -> target.txt, chain1 -> chain2 -> target.txt,
 *          sub/inner.txt ("inner\n"), sub/innerlink -> inner.txt, dirlink -> sub,
 *          up/back -> ../sub, dangling -> no_such_file, loop_a -> loop_b -> loop_a,
 *          abs_null -> /dev/null (an absolute target, resolved in the guest's namespace)
 * Every step prints one line "STEP name rc=R errno=E (text) [detail]"; rc 0 is the expected result
 * unless the step name says which error is expected. tests/host_side.sh checks the host side.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>

static char dir[1024];

static const char *P(const char *name)
{
    static char b[4][1200]; static int i;
    i = (i + 1) % 4;
    snprintf(b[i], sizeof b[i], "%s/%s", dir, name);
    return b[i];
}

static void step(const char *name, int rc, int err, const char *detail)
{
    printf("STEP %s rc=%d errno=%d (%s)%s%s\n", name, rc, err, err ? strerror(err) : "ok", detail ? " " : "", detail ? detail : "");
}

/* read a whole small file into buf; returns bytes or -1 */
static int slurp(const char *path, char *buf, int cap)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    int n = (int)read(fd, buf, (size_t)cap - 1);
    int e = errno;
    close(fd);
    if (n < 0) { errno = e; return -1; }
    buf[n] = 0;
    return n;
}

static void read_step(const char *name, const char *path, const char *want)
{
    char buf[256], d[300];
    int n = slurp(path, buf, sizeof buf);
    int e = n < 0 ? errno : 0;
    int ok = n >= 0 && strcmp(buf, want) == 0;
    snprintf(d, sizeof d, "content %s", n < 0 ? "-" : ok ? "as expected" : "DIFFERENT");
    step(name, ok ? 0 : -1, e, d);
}

static void readlink_step(const char *name, const char *path, const char *want)
{
    char buf[256], d[300];
    ssize_t n = readlink(path, buf, sizeof buf - 1);
    int e = n < 0 ? errno : 0;
    if (n >= 0) buf[n] = 0;
    int ok = n >= 0 && strcmp(buf, want) == 0;
    snprintf(d, sizeof d, "target \"%s\" (%s)", n >= 0 ? buf : "-", ok ? "as expected" : "DIFFERENT");
    step(name, ok ? 0 : -1, e, d);
}

static void err_step(const char *name, int rc, int want_errno)
{
    int e = rc < 0 ? errno : 0;
    char d[80];
    snprintf(d, sizeof d, "expected errno %d (%s): %s", want_errno, strerror(want_errno), rc < 0 && e == want_errno ? "yes" : "NO");
    step(name, rc < 0 && e == want_errno ? 0 : -1, e, d);
}

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: link_test DIR\n"); return 2; }
    snprintf(dir, sizeof dir, "%s", argv[1]);
    struct stat st; char d[200]; int rc;

    rc = lstat(P("link.txt"), &st);
    snprintf(d, sizeof d, "S_ISLNK=%d size=%lld", rc == 0 && S_ISLNK(st.st_mode), rc == 0 ? (long long)st.st_size : -1LL);
    step("lstat_link_is_link", rc == 0 && S_ISLNK(st.st_mode) ? 0 : -1, rc < 0 ? errno : 0, d);
    rc = stat(P("link.txt"), &st);
    snprintf(d, sizeof d, "S_ISREG=%d size=%lld", rc == 0 && S_ISREG(st.st_mode), rc == 0 ? (long long)st.st_size : -1LL);
    step("stat_link_follows_to_file", rc == 0 && S_ISREG(st.st_mode) && st.st_size == 15 ? 0 : -1, rc < 0 ? errno : 0, d);
    readlink_step("readlink_link", P("link.txt"), "target.txt");
    read_step("read_through_link", P("link.txt"), "target content\n");
    read_step("read_through_two_links", P("chain1"), "target content\n");
    read_step("read_through_folder_link", P("dirlink/inner.txt"), "inner\n");
    read_step("read_through_link_with_dotdot", P("up/back/inner.txt"), "inner\n");
    readlink_step("readlink_below_folder_link", P("dirlink/innerlink"), "inner.txt");
    rc = stat(P("dirlink"), &st);
    step("stat_folder_link_is_folder", rc == 0 && S_ISDIR(st.st_mode) ? 0 : -1, rc < 0 ? errno : 0, NULL);

    rc = stat(P("dangling"), &st);
    err_step("stat_dangling_ENOENT", rc, ENOENT);
    rc = lstat(P("dangling"), &st);
    step("lstat_dangling_is_link", rc == 0 && S_ISLNK(st.st_mode) ? 0 : -1, rc < 0 ? errno : 0, NULL);
    rc = open(P("loop_a"), O_RDONLY);
    if (rc >= 0) close(rc);
    err_step("open_loop_ELOOP", rc, ELOOP);

    int fd = open(P("abs_null"), O_WRONLY);
    int wr = fd >= 0 ? (int)write(fd, "x", 1) : -1;
    int e = fd < 0 || wr != 1 ? errno : 0;
    if (fd >= 0) close(fd);
    step("write_through_absolute_link_to_dev_null", fd >= 0 && wr == 1 ? 0 : -1, e, NULL);

    rc = symlink("target.txt", P("made_link"));
    step("symlink_create", rc, rc < 0 ? errno : 0, NULL);
    readlink_step("readlink_made_link", P("made_link"), "target.txt");
    read_step("read_through_made_link", P("made_link"), "target content\n");
    rc = symlink("target.txt", P("made_link"));
    err_step("symlink_existing_EEXIST", rc, EEXIST);
    rc = symlink("sub", P("made_dirlink"));
    step("symlink_create_folder_link", rc, rc < 0 ? errno : 0, NULL);
    fd = open(P("made_dirlink/created.txt"), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    wr = fd >= 0 ? (int)write(fd, "created\n", 8) : -1;
    e = fd < 0 || wr != 8 ? errno : 0;
    if (fd >= 0) close(fd);
    step("create_file_through_folder_link", fd >= 0 && wr == 8 ? 0 : -1, e, NULL);
    rc = mkdir(P("made_dirlink/newdir"), 0755);
    step("mkdir_through_folder_link", rc, rc < 0 ? errno : 0, NULL);
    rc = unlink(P("made_link"));
    step("unlink_removes_link", rc, rc < 0 ? errno : 0, NULL);
    rc = lstat(P("made_link"), &st);
    err_step("lstat_after_unlink_ENOENT", rc, ENOENT);
    rc = stat(P("target.txt"), &st);
    step("target_still_there", rc == 0 && st.st_size == 15 ? 0 : -1, rc < 0 ? errno : 0, NULL);
    rc = unlink(P("dirlink/innerlink"));
    step("unlink_below_folder_link", rc, rc < 0 ? errno : 0, NULL);

    struct statvfs sv;
    rc = statvfs(dir, &sv);
    step("statvfs", rc, rc < 0 ? errno : 0, rc == 0 ? sv.f_basetype : NULL);
    if (rc == 0)
        printf("STATVFS bsize=%lu frsize=%lu blocks=%llu bfree=%llu bavail=%llu files=%llu ffree=%llu namemax=%lu\n",
               (unsigned long)sv.f_bsize, (unsigned long)sv.f_frsize, (unsigned long long)sv.f_blocks,
               (unsigned long long)sv.f_bfree, (unsigned long long)sv.f_bavail, (unsigned long long)sv.f_files,
               (unsigned long long)sv.f_ffree, (unsigned long)sv.f_namemax);
    fd = open(P("target.txt"), O_RDONLY);
    rc = fd >= 0 ? fstatvfs(fd, &sv) : -1;
    e = rc < 0 ? errno : 0;
    if (fd >= 0) close(fd);
    step("fstatvfs_of_a_file", rc, e, NULL);
    return 0;
}
