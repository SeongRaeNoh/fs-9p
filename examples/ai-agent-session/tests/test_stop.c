/* test_stop.c - pulses: an unknown pulse code is ignored, the stop pulse ends the server thread. */
#include <errno.h>
#include <pthread.h>
#include <sys/neutrino.h>
#include "kv.h"
#include "check.h"

int main(void)
{
    struct kv_server s;
    if (kv_server_start(&s) == -1) { perror("kv_server_start"); return 1; }
    int coid = kv_connect(&s);
    CHECK(coid != -1, "connect to the server's channel");
    CHECK(kv_put(coid, "k", "v", 1) == 0, "put k=v");

    struct sched_param sp;
    int pol;
    pthread_getschedparam(pthread_self(), &pol, &sp);
    CHECK(MsgSendPulse(coid, sp.sched_priority, _PULSE_CODE_MINAVAIL + 7, 0) == 0, "send a pulse with an unknown code");
    CHECK(kv_count(coid) == 1, "the server still answers after the unknown pulse");

    kv_close(coid);
    CHECK(kv_server_stop(&s) == 0, "the stop pulse ends the server thread (pthread_join returned)");
    return CHECK_DONE();
}
