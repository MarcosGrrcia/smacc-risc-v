# SMACC: Statistical Math Accelerator for RISC-V

## Overview

A PicoRV32 RISC-V core extended via the PCPI coprocessor interface with four
custom instructions for streaming statistical calculations on 32-bit data.
One DATA instruction replaces tens to hundreds of software cycles per sample:
compare-and-update min/max, increment count, and accumulate a 64-bit sum and
sum of squares (the squaring alone is expensive on a core without the M
extension).

## Instructions

All four share the RISC-V custom-0 opcode (`0x0B`); `funct3` selects the
operation (see [docs/ISA_SPEC.md](docs/ISA_SPEC.md) for encodings):

- **START** (funct3=000): Initialize statistics, clear accumulators, set READY
- **DATA**  (funct3=001): Submit one 32-bit sample from `rs1`, update running stats
- **STOP**  (funct3=010): Begin background finalization of avg/stddev/delta (non-stalling)
- **READ**  (funct3=011): Return one 32-bit statistic, selected by `imm[2:0]`, into `rd`

## Statistics Calculated

| Statistic | Output timing        | Implementation                               |
| --------- | -------------------- | -------------------------------------------- |
| Min       | Continuous (DATA)    | Comparator, running minimum                  |
| Max       | Continuous (DATA)    | Comparator, running maximum                  |
| Count     | Continuous (DATA)    | Counter, incremented per DATA                |
| Average   | After STOP completes | sum/count on shared sequential divider       |
| Stddev    | After STOP completes | isqrt(sum_sq/count - avg^2), bit-serial      |
| Delta     | After STOP completes | max - min, computed when finalization starts |

All results are full 32-bit values. Readouts saturate rather than wrap
(count at 2^32-1); internal accumulators are 64-bit.

## Data Flow

1. START → min=0xFFFF_FFFF, max/count/sum/sum_of_squares=0, state READY
2. DATA, repeated per sample → running stats update in one cycle each; pollable via READ
3. STOP → acknowledges immediately; finalization engine runs 162 cycles in
   the background (state FINALIZING, STATUS_BUSY)
4. Software polls READ STATUS until STATUS_DONE (or does other work first)
5. READ → avg/stddev/delta now valid; min/max/count still readable

## Implementation Modules

- **smacc_isa_defs.sv**: ISA constants, enums, and status masks
- **smacc_ctrl.sv**: FSM (IDLE/READY/ACCUMULATE/FINALIZING/DONE), sticky
  error tracking, status byte
- **smacc_mem.sv**: Accumulator registers (min, max, count, sum,
  sum_of_squares); updated on DATA, served directly to READ
- **smacc_datapath.sv**: Sequential finalization engine: one shared
  restoring divider (used twice) plus bit-serial isqrt; 162-cycle fixed latency
- **smacc_top.sv**: PCPI decode, READ result mux, module integration
- **smacc_system.sv**: PicoRV32 + smacc_top wired together over PCPI
- **sw/smacc.h**: C inline-asm wrappers (`.insn`) so standard GCC can emit
  the custom instructions

## Key Design Decisions

1. **PCPI coprocessor, not MMIO**: true ISA extension with zero core
   modification; DATA costs one instruction per sample.
2. **32-bit results end-to-end**: every statistic comes back at the natural
   width of a RISC-V register; no packing, no truncation surprises.
3. **64-bit internal accumulators**: exact for any 32-bit stream until the
   explicit, error-flagged overflow point.
4. **Non-stalling STOP + bit-serial arithmetic**: finalization latency is
   hidden behind a status poll, so one small bit-serial divider (reused for
   both divides) and an overlapped bit-serial squarer for avg^2 replace the
   big combinational blocks: ~12.2 K generic cells total vs ~78 K for the
   pipelined predecessor, with one 32x32 multiplier left in the design
   (sum-of-squares, required by the single-cycle DATA contract).
5. **Result gating by FSM state**: avg/stddev/delta read as 0 except in
   DONE, so in-flight or stale values are never architecturally visible.
