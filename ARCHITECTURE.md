# SMACC: Statistical Math Accelerator for RISC-V

## Overview

A PicoRV32 RISC-V core extended through the PCPI coprocessor interface with
four custom instructions for computing statistics over a stream of samples.
One DATA instruction replaces the compare/add/multiply sequence software
would need per sample (PicoRV32 is built without the M extension here, so
squaring in software is especially slow).

## Instructions

All four use the RISC-V custom-0 opcode (`0x0B`); the SMACC ID in `funct3`
picks the operation (see [docs/ISA_SPEC.md](docs/ISA_SPEC.md)):

- START (ID 0): Clear all statistics, go to READY
- DATA  (ID 1): Submit one sample from `rs1`
- STOP  (ID 2): Compute avg/stddev/delta; the CPU stalls until done
- READ  (ID 3): Read one 8-bit field of the output register into `rd`

## Statistics Calculated

| Statistic | Updated              | Implementation                  |
| --------- | -------------------- | ------------------------------- |
| Min       | Every DATA           | Comparator, running minimum     |
| Max       | Every DATA           | Comparator, running maximum     |
| Count     | Every DATA           | Counter                         |
| Average   | STOP                 | sum / count                     |
| Stddev    | STOP                 | isqrt(sum_sq/count - avg^2)     |
| Delta     | STOP                 | max - min                       |

## Data Flow

1. START → min=0xFFFF_FFFF, max/count/sum/sum_of_squares=0, state READY
2. DATA (per sample) → min/max/count/sum/sum_of_squares update in one cycle
3. STOP → CPU stalls on `pcpi_wait` while the datapath pipeline runs
4. READ → returns one byte of the output register

## Implementation Modules

- smacc_isa_defs.sv: opcode, SMACC IDs, states, status bits
- smacc_ctrl.sv: FSM (IDLE/READY/ACCUMULATE/COMPUTE/DONE), error flag,
  status byte
- smacc_mem.sv: accumulator registers, updated on DATA
- smacc_datapath.sv: 5-stage pipeline for avg/stddev/delta
- smacc_top.sv: PCPI decode, STOP stall, 64-bit output register

## Key Design Decisions

1. PCPI coprocessor instead of memory-mapped registers: real ISA
   extension, no changes to the core, one instruction per sample.
2. 64-bit accumulators: sum and sum_of_squares of 32-bit samples need
   the extra headroom.
3. 8-bit output fields: the course sensors produce 8-bit data, so one
   64-bit register holds every statistic.
4. Pipelined datapath: the divides, the multiply, and the square root
   each get their own stage so no single stage is too long.
