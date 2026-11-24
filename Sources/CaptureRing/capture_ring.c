#include "capture_ring.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct cap_ring { uint8_t *buf; size_t cap, mask; _Atomic size_t head, tail; _Atomic uint64_t dropped; };

cap_ring_t *cap_ring_create(size_t cap) {
    if (cap == 0 || (cap & (cap - 1)) != 0) return NULL;
    cap_ring_t *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->buf = malloc(cap);
    if (!r->buf) { free(r); return NULL; }
    r->cap = cap; r->mask = cap - 1;
    atomic_init(&r->head, 0); atomic_init(&r->tail, 0); atomic_init(&r->dropped, 0);
    return r;
}
void cap_ring_destroy(cap_ring_t *r) { if (!r) return; free(r->buf); free(r); }
static void copy_in(cap_ring_t *r, size_t pos, const void *src, size_t len) {
    size_t off = pos & r->mask, first = len < r->cap - off ? len : r->cap - off;
    memcpy(r->buf + off, src, first); memcpy(r->buf, (const uint8_t *)src + first, len - first);
}
static void copy_out(cap_ring_t *r, size_t pos, void *dst, size_t len) {
    size_t off = pos & r->mask, first = len < r->cap - off ? len : r->cap - off;
    memcpy(dst, r->buf + off, first); memcpy((uint8_t *)dst + first, r->buf, len - first);
}
int cap_ring_write2(cap_ring_t *r, const void *a, size_t alen, const void *b, size_t blen) {
    size_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    if (r->cap - (head - tail) < alen + blen) { atomic_fetch_add_explicit(&r->dropped, 1, memory_order_relaxed); return 0; }
    copy_in(r, head, a, alen); if (blen) copy_in(r, head + alen, b, blen);
    atomic_store_explicit(&r->head, head + alen + blen, memory_order_release); return 1;
}
size_t cap_ring_readable(cap_ring_t *r) {
    return atomic_load_explicit(&r->head, memory_order_acquire) - atomic_load_explicit(&r->tail, memory_order_relaxed);
}
int cap_ring_read(cap_ring_t *r, void *dst, size_t len) {
    size_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    if (head - tail < len) return 0;
    copy_out(r, tail, dst, len); atomic_store_explicit(&r->tail, tail + len, memory_order_release); return 1;
}
uint64_t cap_ring_dropped(cap_ring_t *r) { return atomic_load_explicit(&r->dropped, memory_order_relaxed); }
