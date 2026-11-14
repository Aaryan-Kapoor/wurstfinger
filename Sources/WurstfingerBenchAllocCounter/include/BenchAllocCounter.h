//
//  BenchAllocCounter.h
//  WurstfingerBenchAllocCounter
//
//  Counts heap allocations process-wide so the bench can report "allocations
//  per keystroke". Swift cannot declare libmalloc's `malloc_logger` hook (a
//  plain function-pointer global with no header), so the counter is C.
//

#ifndef BENCH_ALLOC_COUNTER_H
#define BENCH_ALLOC_COUNTER_H

#include <stdint.h>

/// Installs the counting hook. Idempotent; the first call chains any logger
/// that was already set (so a malloc-stack-logging session keeps working).
void bench_alloc_counter_install(void);

/// Allocation events since process start: every malloc, calloc, realloc and
/// aligned allocation that went through a malloc zone.
uint64_t bench_alloc_count(void);

/// Bytes requested by those events (the requested size, not the size class
/// libmalloc rounded it up to).
uint64_t bench_alloc_bytes(void);

#endif
