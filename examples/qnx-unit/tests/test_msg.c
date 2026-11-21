/* test_msg.c - a unit test that needs the QNX kernel: a message-passing server (ChannelCreate,
 * MsgReceive, MsgReply, MsgError) and its client (ConnectAttach, MsgSend), including the priority
 * that the server thread runs at while it serves a client. QNX documents that a receiving thread
 * inherits the priority of the sending thread, unless the channel was created with
 * _NTO_CHF_FIXED_PRIORITY (System Architecture guide, "Priority inheritance and messages").
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <ctype.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <string.h>
#include <sys/neutrino.h>
#include "check.h"

enum { OP_UPPER = 1, OP_BAD = 2, OP_QUIT = 3 };
struct req { int op; char text[32]; };
struct rsp { int prio; char text[32]; };

static void *server(void *arg)
{
    int chid = *(int *)arg;
    for (;;) {
        struct req r;
        int rcvid = MsgReceive(chid, &r, sizeof r, NULL);
        if (rcvid == -1) return NULL;
        if (rcvid == 0) continue;                      /* a pulse; not used here */
        struct rsp a; memset(&a, 0, sizeof a);
        int pol; struct sched_param sp;
        pthread_getschedparam(pthread_self(), &pol, &sp);
        a.prio = sp.sched_curpriority;                 /* priority the server runs at now */
        if (r.op == OP_BAD) { MsgError(rcvid, ENOTSUP); continue; }
        for (size_t i = 0; i < sizeof a.text - 1 && r.text[i]; i++) a.text[i] = (char)toupper((unsigned char)r.text[i]);
        MsgReply(rcvid, EOK, &a, sizeof a);
        if (r.op == OP_QUIT) return NULL;
    }
}

/* Start a server thread at priority 10 on a new channel; send three requests at priority 30. */
static void run(unsigned chflags, const char *what, int want_prio)
{
    int chid = ChannelCreate(chflags);
    CHECK(chid != -1, "%s: ChannelCreate", what);
    pthread_attr_t ta; pthread_attr_init(&ta);
    struct sched_param sp; memset(&sp, 0, sizeof sp); sp.sched_priority = 10;
    pthread_attr_setinheritsched(&ta, PTHREAD_EXPLICIT_SCHED);
    pthread_attr_setschedpolicy(&ta, SCHED_FIFO);
    pthread_attr_setschedparam(&ta, &sp);
    pthread_t tid;
    CHECK(pthread_create(&tid, &ta, server, &chid) == EOK, "%s: server thread at priority 10", what);
    int coid = ConnectAttach(0, 0, chid, _NTO_SIDE_CHANNEL, 0);
    CHECK(coid != -1, "%s: ConnectAttach", what);
    CHECK(pthread_setschedprio(pthread_self(), 30) == EOK, "%s: client thread at priority 30", what);

    struct req r = { OP_UPPER, "hello qnx" };
    struct rsp a; memset(&a, 0, sizeof a);
    long st = MsgSend(coid, &r, sizeof r, &a, sizeof a);
    CHECK(st == EOK && strcmp(a.text, "HELLO QNX") == 0, "%s: MsgSend gets the reply \"%s\"", what, a.text);
    CHECK(a.prio == want_prio, "%s: the server thread ran at priority %d while serving (expected %d)", what, a.prio, want_prio);

    r.op = OP_BAD;
    st = MsgSend(coid, &r, sizeof r, &a, sizeof a);
    CHECK(st == -1 && errno == ENOTSUP, "%s: MsgError(ENOTSUP) reaches the client as errno ENOTSUP", what);

    r.op = OP_QUIT;
    MsgSend(coid, &r, sizeof r, &a, sizeof a);
    pthread_join(tid, NULL);
    ConnectDetach(coid);
    ChannelDestroy(chid);
}

int main(void)
{
    run(0, "default channel", 30);                         /* inherits the client's priority */
    run(_NTO_CHF_FIXED_PRIORITY, "fixed-priority channel", 10);
    return CHECK_DONE();
}
