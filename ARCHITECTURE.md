# SMACC: Statistical Math Accelerator for RISC-V

## Overview

SMACC adds four custom instructions to a PicoRV32 core through its PCPI
coprocessor interface. They compute statistics over a stream of 32-bit
samples. One DATA instruction does what would otherwise be a few dozen to a
few hundred cycles of software per sample: update min/max, bump the count,
and add to a 64-bit sum and sum of squares (the squaring is the expensive
part on a core without the M extension).

## Instructions

All four use the RISC-V custom-0 opcode (`0x0B`), and `funct3` picks the
operation. Encodings are in [docs/ISA_SPEC.md](docs/ISA_SPEC.md).

- `START` (funct3=000): clear the accumulators, go to READY
- `DATA` (funct3=001): add the sample in `rs1`
- `STOP` (funct3=010): start computing avg/stddev/delta in the background
- `READ` (funct3=011): put the statistic selected by `imm[2:0]` in `rd`

## Statistics

| Statistic | Available            | How                                         |
| --------- | -------------------- | ------------------------------------------- |
| Min       | Always (live)        | Comparator                                  |
| Max       | Always (live)        | Comparator                                  |
| Count     | Always (live)        | Counter                                     |
| Average   | After STOP finishes  | sum / count on the shared divider           |
| Stddev    | After STOP finishes  | isqrt(sum_sq/count - avg^2), bit-serial     |
| Delta     | After STOP finishes  | max - min, taken when finalization starts   |

Everything comes back as a 32-bit value. The accumulators are 64-bit, and
readouts saturate instead of wrapping (count at 2^32-1).

## Flow

1. START: min=0xFFFF_FFFF, max/count/sum/sum_of_squares=0, state READY
2. DATA per sample: running stats update in one cycle and can be read any time
3. STOP: acks immediately; the engine runs for 162 cycles (state FINALIZING,
   STATUS_BUSY)
4. Software polls READ STATUS for STATUS_DONE, or does other work first
5. READ: avg/stddev/delta are valid now; min/max/count still readable

## Modules

- `smacc_isa_defs.sv`: ISA constants, enums, status masks
- `smacc_ctrl.sv`: FSM (IDLE/READY/ACCUMULATE/FINALIZING/DONE), sticky error,
  status byte
- `smacc_mem.sv`: min, max, count, sum, sum_of_squares; updated on DATA and
  read directly by READ
- `smacc_datapath.sv`: finalization engine, one restoring divider used for
  both divides plus a bit-serial isqrt, 162 cycles
- `smacc_top.sv`: PCPI decode, READ mux, wiring
- `smacc_system.sv`: PicoRV32 + smacc_top connected over PCPI

## Design decisions

1. PCPI coprocessor instead of memory-mapped registers. It's a real ISA
   extension, the core doesn't change, and DATA is one instruction.
2. Every result is 32 bits, the width of a RISC-V register. No packing
   several stats into one word.
3. 64-bit accumulators, so a 32-bit sample stream stays exact until the
   overflow point, which is flagged.
4. STOP doesn't stall, so the math can be slow and small. One bit-serial
   divider (used twice) and a bit-serial squarer for avg^2 replace the big
   combinational blocks of the original design: ~12.2 K generic cells vs
   ~78 K. The only multiplier left is the sum-of-squares one, which the
   single-cycle DATA needs.
5. avg/stddev/delta read as 0 unless the FSM is in DONE, so a result that's
   still being computed, or left over from an earlier run, never shows up.
