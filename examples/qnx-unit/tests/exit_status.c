/* exit_status.c - checks the runner, not QNX: writes one line to stdout and one to stderr and exits
 * with the status given as the first argument. With a second argument (a file), it exits with
 * status 4 if it cannot open the file; tools/qnx-run maps an absolute host path inside the share to
 * the guest path, so a test can name its data files with host paths.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
    printf("exit_status: stdout line\n");
    fprintf(stderr, "exit_status: stderr line\n");
    if (argc > 2) {
        FILE *f = fopen(argv[2], "r");
        printf("exit_status: open %s: %s\n", argv[2], f ? "ok" : "failed");
        if (!f) return 4;
        fclose(f);
    }
    return argc > 1 ? atoi(argv[1]) : 0;
}
