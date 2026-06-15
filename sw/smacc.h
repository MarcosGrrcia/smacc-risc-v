/*
 * smacc.h: C interface to the SMACC statistical accelerator (ISA v2.0).
 *
 * Emits the custom-0 instructions via the GNU assembler's .insn directive,
 * and works with the stock riscv32 GCC/binutils toolchain used for
 * PicoRV32, so no custom assembler support is needed.
 *
 * Usage:
 *     smacc_start();
 *     for (i = 0; i < n; i++) smacc_data(samples[i]);
 *     smacc_stop();
 *     smacc_wait_done();          // or do other work, then check status
 *     uint32_t avg = smacc_read_avg();
 *
 * STOP returns immediately; avg/stddev/delta read as 0 until
 * SMACC_STATUS_DONE is set (see docs/ISA_SPEC.md section 4.3, section 7.3).
 */

#ifndef SMACC_H
#define SMACC_H

#include <stdint.h>

/* READ statistic selectors (imm[2:0], ISA_SPEC.md section 3.4) */
#define SMACC_STAT_MIN    0
#define SMACC_STAT_MAX    1
#define SMACC_STAT_AVG    2
#define SMACC_STAT_COUNT  3
#define SMACC_STAT_STDDEV 4
#define SMACC_STAT_DELTA  5
#define SMACC_STAT_STATUS 6

/* Status byte flags (ISA_SPEC.md section 5) */
#define SMACC_STATUS_READY 0x80u /* initialized, accepting DATA          */
#define SMACC_STATUS_BUSY  0x40u /* finalization engine running          */
#define SMACC_STATUS_DONE  0x20u /* avg/stddev/delta valid               */
#define SMACC_STATUS_ERROR 0x10u /* sticky; cleared only by smacc_start  */

/* START: initialize statistics, clear error, state -> READY (funct3=000) */
static inline void smacc_start(void)
{
    __asm__ volatile (".insn i 0x0b, 0x0, x0, x0, 0");
}

/* DATA: submit one 32-bit sample (funct3=001) */
static inline void smacc_data(uint32_t sample)
{
    __asm__ volatile (".insn i 0x0b, 0x1, x0, %0, 0" : : "r"(sample));
}

/* STOP: begin background finalization; returns immediately (funct3=010) */
static inline void smacc_stop(void)
{
    __asm__ volatile (".insn i 0x0b, 0x2, x0, x0, 0");
}

/* READ: return one 32-bit statistic (funct3=011). A macro because `sel`
 * is encoded in the immediate and must be a compile-time constant. */
#define smacc_read(sel)                                                  \
    __extension__ ({                                                     \
        uint32_t result_;                                                \
        __asm__ volatile (".insn i 0x0b, 0x3, %0, x0, %1"                \
                          : "=r"(result_) : "I"(sel));                   \
        result_;                                                         \
    })

static inline uint32_t smacc_read_min(void)    { return smacc_read(SMACC_STAT_MIN); }
static inline uint32_t smacc_read_max(void)    { return smacc_read(SMACC_STAT_MAX); }
static inline uint32_t smacc_read_avg(void)    { return smacc_read(SMACC_STAT_AVG); }
static inline uint32_t smacc_read_count(void)  { return smacc_read(SMACC_STAT_COUNT); }
static inline uint32_t smacc_read_stddev(void) { return smacc_read(SMACC_STAT_STDDEV); }
static inline uint32_t smacc_read_delta(void)  { return smacc_read(SMACC_STAT_DELTA); }
static inline uint32_t smacc_status(void)      { return smacc_read(SMACC_STAT_STATUS); }

/* Spin until finalization completes (~162 cycles after smacc_stop). */
static inline void smacc_wait_done(void)
{
    while (!(smacc_status() & SMACC_STATUS_DONE))
        ;
}

#endif /* SMACC_H */
