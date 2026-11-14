//
//  BenchAllocCounter.c
//  WurstfingerBenchAllocCounter
//
//  libmalloc calls `malloc_logger` (when non-NULL) after every zone
//  allocation, reallocation and free, with the arguments laid out as the
//  stack-logging machinery expects:
//
//    type bit 1 (2)  allocate       type bit 2 (4)  deallocate
//    type bit 3 (8)  arg1 is the zone
//    malloc/calloc:  arg1 = zone, arg2 = size          (no zone bit: arg1 = size)
//    realloc (2|4):  arg1 = zone, arg2 = old pointer, arg3 = new size
//                    (no zone bit: arg1 = old pointer, arg2 = new size)
//    free (4 only):  not counted
//
//  The hook runs inside malloc itself, so it must not allocate, lock or call
//  into anything that might: two relaxed atomic adds and nothing else.
//

#include "BenchAllocCounter.h"

#include <stdatomic.h>
#include <stdbool.h>

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                              uintptr_t result, uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

#define LOG_TYPE_ALLOCATE 2u
#define LOG_TYPE_DEALLOCATE 4u
#define LOG_TYPE_HAS_ZONE 8u

static _Atomic uint64_t allocation_count;
static _Atomic uint64_t allocation_bytes;
static malloc_logger_t *chained_logger;
static atomic_bool installed;

static void counting_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                            uintptr_t result, uint32_t skip) {
    if (type & LOG_TYPE_ALLOCATE) {
        bool zoned = (type & LOG_TYPE_HAS_ZONE) != 0;
        bool is_realloc = (type & LOG_TYPE_DEALLOCATE) != 0;
        uintptr_t size;
        if (is_realloc) {
            size = zoned ? arg3 : arg2;
        } else {
            size = zoned ? arg2 : arg1;
        }
        atomic_fetch_add_explicit(&allocation_count, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&allocation_bytes, (uint64_t)size, memory_order_relaxed);
    }
    if (chained_logger) {
        chained_logger(type, arg1, arg2, arg3, result, skip);
    }
}

void bench_alloc_counter_install(void) {
    if (atomic_exchange(&installed, true)) {
        return;
    }
    chained_logger = malloc_logger;
    malloc_logger = counting_logger;
}

uint64_t bench_alloc_count(void) {
    return atomic_load_explicit(&allocation_count, memory_order_relaxed);
}

uint64_t bench_alloc_bytes(void) {
    return atomic_load_explicit(&allocation_bytes, memory_order_relaxed);
}
