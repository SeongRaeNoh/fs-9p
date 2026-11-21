/* examples/ci-crash/tests/child_crash.c - passes: a child process crashes on purpose (as in test
 * suites that check crash handling), and the test checks that SIGSEGV ended it.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include "../src/record.h"

int main(void)
{
    struct record r;
    int st;
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }
    if (pid == 0) { parse_record("no value here", &r); _exit(0); }
    if (waitpid(pid, &st, 0) != pid) { perror("waitpid"); return 2; }
    int ok = WIFSIGNALED(st) && WTERMSIG(st) == SIGSEGV;
    printf("child ended by signal %d: %s\n", WIFSIGNALED(st) ? WTERMSIG(st) : 0, ok ? "as expected" : "not as expected");
    return ok ? 0 : 1;
}
