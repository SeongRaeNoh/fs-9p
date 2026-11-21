/* kv_proto.h - messages between the kvstore client functions and the kvstore server thread.
 *
 * Every request starts with struct kv_hdr. KV_PUT carries the value right after the header; the
 * value length is the rest of the message. KV_GET and KV_DEL carry the header only; KV_COUNT
 * carries only the type field.
 * Replies: KV_GET replies with the value (status = value length), KV_DEL with status 0,
 * KV_COUNT with status = number of keys, KV_PUT with status 0. Errors come back with MsgError().
 * The server stops when it receives a pulse with code KV_PULSE_STOP.
 */
#ifndef KV_PROTO_H
#define KV_PROTO_H
#include <stdint.h>
#include <sys/neutrino.h>
#include "kv.h"

#define KV_PUT   0x4b01
#define KV_GET   0x4b02
#define KV_DEL   0x4b03
#define KV_COUNT 0x4b04

#define KV_PULSE_STOP (_PULSE_CODE_MINAVAIL + 1)

struct kv_hdr {
    uint16_t type;              /* KV_PUT, KV_GET, KV_DEL, KV_COUNT */
    uint16_t zero;
    char     key[KV_KEY_MAX];   /* NUL-terminated */
};

/* the server's receive buffer: a header plus the first value bytes of a KV_PUT */
#define KV_RECV_BYTES 256

#endif
