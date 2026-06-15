/*
 * example.c: Minimal SMACC usage example.
 *
 * Streams a buffer of samples through the accelerator and reads back all
 * six statistics. Written for bare-metal PicoRV32 (no libc calls); build
 * with the riscv32 GCC toolchain, e.g.:
 *
 *   riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -c example.c
 */

#include <stdint.h>
#include "smacc.h"

typedef struct {
    uint32_t min, max, count, avg, stddev, delta;
} smacc_stats_t;

/* Returns 0 on success, -1 if the accelerator flagged an error
 * (illegal instruction sequence or accumulator overflow). */
int compute_stats(const uint32_t *samples, uint32_t n, smacc_stats_t *out)
{
    smacc_start();
    for (uint32_t i = 0; i < n; i++)
        smacc_data(samples[i]);

    smacc_stop();        /* returns immediately; engine runs ~162 cycles */
    smacc_wait_done();   /* or do other work and poll smacc_status() */

    if (smacc_status() & SMACC_STATUS_ERROR)
        return -1;

    out->min    = smacc_read_min();
    out->max    = smacc_read_max();
    out->count  = smacc_read_count();
    out->avg    = smacc_read_avg();
    out->stddev = smacc_read_stddev();
    out->delta  = smacc_read_delta();
    return 0;
}
