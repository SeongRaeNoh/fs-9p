/* stuck_receive.c - checks the runner, not QNX: a test that never ends. It waits in MsgReceive() on
 * a channel that no client knows, so only a signal ends it. Used to check that a time limit
 * (tools/qnx-run -t, the ctest TIMEOUT property) and a Ctrl-C on the host stop it inside the guest.
 * Arguments: "ignore-term" ignores SIGTERM (then only SIGKILL ends it); "fork" starts a child
 * process that waits the same way (the runner must stop the whole process group).
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/neutrino.h>

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "ignore-term") == 0)
            signal(SIGTERM, SIG_IGN);
        else if (strcmp(argv[i], "fork") == 0 && fork() == -1)
            perror("fork");
    }
    int chid = ChannelCreate(0);
    if (chid == -1) {
        perror("ChannelCreate");
        return 2;
    }
    printf("stuck_receive: a process waits in MsgReceive()\n");
    fflush(stdout);
    char buf[64];
    for (;;) {
        if (MsgReceive(chid, buf, sizeof buf, NULL) == -1) {
            perror("MsgReceive");
            return 2;
        }
    }
}
