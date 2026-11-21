/* test_pulse.c - a unit test that needs the QNX kernel: pulses (MsgSendPulse, MsgReceive returns
 * rcvid 0), a timer that delivers a pulse (timer_create with SIGEV_PULSE), and the order in which a
 * channel queues pulses of different priorities.
 * Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0. */
#include <errno.h>
#include <string.h>
#include <time.h>
#include <sys/neutrino.h>
#include "check.h"

int main(void)
{
    struct _pulse p;
    int chid = ChannelCreate(0);
    int coid = ConnectAttach(0, 0, chid, _NTO_SIDE_CHANNEL, 0);
    CHECK(chid != -1 && coid != -1, "channel and connection");

    CHECK(MsgSendPulse(coid, -1, 5, 1234) != -1, "MsgSendPulse(code 5, value 1234)");
    int rcvid = MsgReceive(chid, &p, sizeof p, NULL);
    CHECK(rcvid == 0 && p.code == 5 && p.value.sival_int == 1234, "MsgReceive returns the pulse: rcvid %d, code %d, value %d",
          rcvid, p.code, p.value.sival_int);

    /* two pulses queued while no thread receives: the higher priority comes out first */
    MsgSendPulse(coid, 10, 1, 0);
    MsgSendPulse(coid, 20, 2, 0);
    int c1 = -1, c2 = -1;
    if (MsgReceive(chid, &p, sizeof p, NULL) == 0) c1 = p.code;
    if (MsgReceive(chid, &p, sizeof p, NULL) == 0) c2 = p.code;
    CHECK(c1 == 2 && c2 == 1, "queued pulses come out by priority: code %d (priority 20), then code %d (priority 10)", c1, c2);

    struct sigevent ev;
    SIGEV_PULSE_INIT(&ev, coid, SIGEV_PULSE_PRIO_INHERIT, 6, 77);
    timer_t tid;
    CHECK(timer_create(CLOCK_MONOTONIC, &ev, &tid) == 0, "timer_create with a pulse event");
    struct itimerspec its; memset(&its, 0, sizeof its);
    its.it_value.tv_nsec = 10000000;                       /* one shot */
    CHECK(timer_settime(tid, 0, &its, NULL) == 0, "timer_settime (one shot)");
    rcvid = MsgReceive(chid, &p, sizeof p, NULL);
    CHECK(rcvid == 0 && p.code == 6 && p.value.sival_int == 77, "the timer delivers its pulse: code %d, value %d", p.code, p.value.sival_int);
    timer_delete(tid);
    ConnectDetach(coid);
    ChannelDestroy(chid);
    return CHECK_DONE();
}
