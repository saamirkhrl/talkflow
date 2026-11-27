#pragma once
#include <stdint.h>
#include <stddef.h>

// Why this exists: the Core Audio IOProc that delivers the computer-audio track runs on a real-time thread. It may
// not take a lock or allocate, so it writes each chunk (header + payload) into this ring and a normal thread drains
// it. The head index is published with ONE release store after header and payload are both copied in, so the
// consumer can never see half a chunk. Single producer, single consumer only.

typedef struct cap_ring cap_ring_t;   // opaque: Swift cannot import _Atomic fields

typedef struct {
    uint64_t hostTime;    // AudioTimeStamp.mHostTime of the first input frame
    uint64_t nowHost;     // inNow.mHostTime at the callback
    double   sampleTime;  // inInputTime.mSampleTime
    double   rate;        // native sample rate of the payload (the IOProc's tap format)
    uint32_t frames;      // mono Float32 frames in the payload that follows
    uint32_t nonZero;     // raw input samples whose bit pattern != 0
    float    peak;        // max abs raw input sample
    uint32_t flags;       // inInputTime.mFlags
} cap_chunk_header;

// NULL if capacityPow2 is 0, not a power of two, or malloc fails.
cap_ring_t *cap_ring_create(size_t capacityPow2);
void        cap_ring_destroy(cap_ring_t *r);
// All-or-nothing: 1 written, 0 dropped (and the drop counter is bumped).
int         cap_ring_write2(cap_ring_t *r, const void *a, size_t alen, const void *b, size_t blen);
size_t      cap_ring_readable(cap_ring_t *r);
// 1 if len bytes were available and copied, else 0 and nothing consumed.
int         cap_ring_read(cap_ring_t *r, void *dst, size_t len);
uint64_t    cap_ring_dropped(cap_ring_t *r);
