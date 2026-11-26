/* Host regression for codec-only M4U cleanup. No hardware or Android headers. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../build/media/q5-omx-compat.c"

static int fake_errno, alloc_result, free_result, unlock_count;
static unsigned next_mva;
static struct { unsigned address, size; } unlocked[1024];
int *__errno(void) { return &fake_errno; }
int pthread_mutex_lock(void *p) { (void)p; return 0; }
int pthread_mutex_unlock(void *p) { (void)p; return 0; }
int munlock(const void *p, __SIZE_TYPE__ size) {
    assert(unlock_count < 1024);
    unlocked[unlock_count].address = (__UINTPTR_TYPE__)p;
    unlocked[unlock_count++].size = size;
    fake_errno = 99;
    return 0;
}
int original_alloc(void *p, int m, unsigned a, unsigned s, int sec, int c, unsigned *out) {
    (void)p; (void)m; (void)a; (void)s; (void)sec; (void)c;
    *out = ++next_mva;
    fake_errno = 7;
    return alloc_result;
}
int original_free(void *p, int m, unsigned a, unsigned s, unsigned v) {
    (void)p; (void)m; (void)a; (void)s; (void)v;
    fake_errno = 8;
    return free_result;
}
static unsigned alloc(unsigned address, unsigned size) {
    unsigned mva;
    assert(q5_alloc((void *)1, 3, address, size, 0, 0, &mva) == alloc_result);
    assert(fake_errno == 7);
    return mva;
}
static void release(unsigned mva) {
    /* Cleanup must use the tracked range even if a caller supplies zero VA. */
    assert(q5_free((void *)1, 3, 0, 0, mva) == free_result);
    assert(fake_errno == 8);
}
static void reset(void) {
    memset(mappings, 0, sizeof(mappings));
    tracking_overflow = alloc_result = free_result = unlock_count = next_mva = 0;
}
int main(void) {
    unsigned a, b, i;
    reset();
    a = alloc(0x1100, 0x100);
    assert(unlock_count == 0);
    release(a);
    assert(unlock_count == 1 && unlocked[0].address == 0x1000 && unlocked[0].size == 4096);
    release(a);
    assert(unlock_count == 1); /* Duplicate/unknown free cannot unlock twice. */

    reset();
    a = alloc(0x1100, 0x1300);
    b = alloc(0x2000, 0x1500);
    release(a);
    assert(unlock_count == 1 && unlocked[0].address == 0x1000 && unlocked[0].size == 4096);
    release(b);
    assert(unlock_count == 2 && unlocked[1].address == 0x2000 && unlocked[1].size == 8192);

    reset();
    a = alloc(0x2000, 0x1000);
    free_result = -1;
    release(a);
    assert(unlock_count == 0); /* Failed device unmap must retain DMA locks. */
    free_result = 0;
    release(a);
    assert(unlock_count == 1);

    reset();
    a = alloc(0x2000, 0x1000);
    alloc_result = -1;
    alloc(0x1000, 0x2000);
    assert(unlock_count == 1 && unlocked[0].address == 0x1000 && unlocked[0].size == 4096);
    release(a);
    assert(unlock_count == 2);

    reset();
    for (i = 0; i < SLOTS + 1; ++i) alloc(0x10000 + i * 4096, 4096);
    assert(tracking_overflow);
    release(1);
    assert(unlock_count == 0); /* Tracking exhaustion fails closed. */

    reset();
    a = alloc(0xfffff000, 0x2000);
    release(a);
    assert(unlock_count == 0); /* Reject wrapped 32-bit address ranges. */
    puts("M4U cleanup: overlap, failure, identity, overflow and errno checks passed");
    return 0;
}
