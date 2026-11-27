/* Nougat has no AwesomePlayer time-source object. The MT6582 implementation
 * uses -1 when no usable playback clock exists (first frame / seeking).
 * Never dereference a legacy AwesomePlayer layout in the NuPlayer process.
 */
void q5_omx_legacy_time(void *legacy, long long *time_us)
    __asm__("_ZN7android13AwesomePlayer24mtk_omx_get_current_timeEPx");
void q5_omx_legacy_time(void *legacy, long long *time_us) {
    (void)legacy;
    if (time_us) *time_us = -1;
}

/* Only libvcodec_utility's two M4U imports are redirected here. The original
 * libm4u, SurfaceFlinger and other graphics clients remain untouched. Its
 * allocator calls mlock but its successful deallocator never calls munlock.
 * Keep overlapping pages locked until every tracked video mapping is gone.
 */
extern int pthread_mutex_lock(void *);
extern int pthread_mutex_unlock(void *);
extern int munlock(const void *, __SIZE_TYPE__);
extern int *__errno(void);
extern int original_alloc(void *, int, unsigned, unsigned, int, int, unsigned *)
    __asm__("_ZN9MTKM4UDrv13m4u_alloc_mvaEijjiiPj");
extern int original_free(void *, int, unsigned, unsigned, unsigned)
    __asm__("_ZN9MTKM4UDrv15m4u_dealloc_mvaEijjj");

#define SLOTS 256
#define PAGE 4096ULL
struct mapping {
    void *owner;
    unsigned module, address, size, mva;
    int active;
};
static struct mapping mappings[SLOTS];
/* Android ARM32's default private pthread_mutex_t initializer is zero. */
static unsigned mapping_mutex;
static int tracking_overflow;

static unsigned long long page_start(unsigned address) {
    return (unsigned long long)address & ~(PAGE - 1);
}
static unsigned long long page_end(unsigned address, unsigned size) {
    return ((unsigned long long)address + size + PAGE - 1) & ~(PAGE - 1);
}

static void unlock_unused(unsigned address, unsigned size) {
    unsigned long long page, end, run = 0;
    unsigned i;
    if (!address || !size || tracking_overflow) return;
    end = page_end(address, size);
    if (end > 0x100000000ULL) return;
    for (page = page_start(address); page < end; page += PAGE) {
        int in_use = 0;
        for (i = 0; i < SLOTS; ++i) {
            const struct mapping *m = &mappings[i];
            if (m->active && page >= page_start(m->address) &&
                page < page_end(m->address, m->size)) {
                in_use = 1;
                break;
            }
        }
        if (!in_use && !run) run = page;
        if (in_use && run) {
            munlock((void *)(__UINTPTR_TYPE__)run, (__SIZE_TYPE__)(page - run));
            run = 0;
        }
    }
    if (run) munlock((void *)(__UINTPTR_TYPE__)run, (__SIZE_TYPE__)(end - run));
}

int q5_alloc(void *, int, unsigned, unsigned, int, int, unsigned *)
    __asm__("_ZN9Q5KM4UDrv13m4u_alloc_mvaEijjiiPj");
int q5_alloc(void *owner, int module, unsigned address, unsigned size,
             int security, int coherent, unsigned *mva) {
    int result, saved_errno;
    unsigned i;
    pthread_mutex_lock(&mapping_mutex);
    result = original_alloc(owner, module, address, size, security, coherent, mva);
    saved_errno = *__errno();
    if (result == 0 && address && size) {
        for (i = 0; i < SLOTS && mappings[i].active; ++i) {}
        if (i == SLOTS) {
            /* Never unlock potentially live DMA pages if tracking is full. */
            tracking_overflow = 1;
        } else {
            struct mapping *m = &mappings[i];
            m->owner = owner; m->module = module; m->address = address;
            m->size = size; m->mva = *mva; m->active = 1;
        }
    } else if (result != 0) {
        /* An ioctl failure can occur after the original allocator's mlock. */
        unlock_unused(address, size);
    }
    pthread_mutex_unlock(&mapping_mutex);
    *__errno() = saved_errno;
    return result;
}

int q5_free(void *, int, unsigned, unsigned, unsigned)
    __asm__("_ZN9Q5KM4UDrv15m4u_dealloc_mvaEijjj");
int q5_free(void *owner, int module, unsigned address, unsigned size, unsigned mva) {
    int result, saved_errno;
    unsigned i;
    pthread_mutex_lock(&mapping_mutex);
    result = original_free(owner, module, address, size, mva);
    saved_errno = *__errno();
    if (result == 0) {
        for (i = 0; i < SLOTS; ++i) {
            struct mapping *m = &mappings[i];
            if (m->active && m->owner == owner && m->module == (unsigned)module && m->mva == mva) {
                unsigned old_address = m->address, old_size = m->size;
                m->active = 0;
                unlock_unused(old_address, old_size);
                break;
            }
        }
    }
    pthread_mutex_unlock(&mapping_mutex);
    *__errno() = saved_errno;
    return result;
}
