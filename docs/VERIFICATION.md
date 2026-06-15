# SMACC Verification

How the design is tested, what the assertions guarantee, and how to
reproduce every result.

## Strategy

Three layers, all runnable from one script:

1. **Lint**: Verilator `-Wall`, kept warning-clean. Deliberate exceptions
   (interface-mandated unused ports, end-of-pipe truncation) are waived
   in-source with a comment explaining each waiver.
2. **Dynamic simulation**: a self-checking testbench drives the PCPI bus
   directly and compares all six statistics against hand-computed values,
   while SystemVerilog assertions watch the FSM, handshake, and datapath
   invariants from inside the design.
3. **Synthesis check**: Yosys generic synthesis confirms the RTL
   elaborates, infers no latches, and uses only synchronous-reset flops.

```sh
bash scripts/run_tests.sh          # lint + simulate, assertions enabled
bash scripts/run_tests.sh --wave   # same, plus smacc_tb.vcd for GTKWave
yosys -s scripts/synth.ys          # synthesis sanity + area report
```

## Test Plan (`src/tb/smacc_tb.sv`)

| Test | Scenario                          | What it proves                                            |
|------|-----------------------------------|-----------------------------------------------------------|
| T1   | 10-sample run (5 to 50)           | End-to-end math; live running stats; avg gated until done |
| T2   | STOP with no data                 | Illegal sequence sets sticky `STATUS_ERROR`               |
| T3   | DATA before START                 | Sample discarded, error set, START clears it              |
| T4   | Single sample                     | `stddev = delta = 0`; first sample visible immediately    |
| T5   | Five identical samples            | Variance is exactly zero (no integer-math residue)        |
| T6   | Two-point spread (0, 254)         | Exact stddev when variance is a perfect square            |
| T7   | Back-to-back runs                 | START fully clears state; no leakage between datasets     |
| T8   | Large samples (100000, 300000)    | Full 32-bit result path, values far beyond 8 bits         |
| T9   | START during finalization         | Engine aborts cleanly; BUSY clears; next run is correct   |
| T10  | All-zero samples                  | Every statistic reads exactly 0; count still advances     |
| T11  | Single max sample (2^32-1)        | Exact math at the very top of the input range             |
| T12  | Two max samples                   | Sum-of-squares overflow: saturation plus sticky ERROR     |
| T13  | 64 random samples (fixed seed)    | Hardware matches an independent software reference model  |

78 checks total. T1 through T12 use expected values derived by hand in an
adjacent comment, so a reviewer can confirm the math without running
anything; T13 computes its expected values in the bench with 64-bit
software arithmetic that mirrors the ISA semantics (truncating divides,
floored variance, integer square root).

## Latest Verified Run

Output of `bash scripts/run_tests.sh` (Verilator 5.020, assertions enabled,
lint clean), 78/78 checks passing:

```plaintext
-- T1: full run, 10 samples --
[PASS] T1 run min    = 5
[PASS] T1 run count  = 10
[PASS] T1 avg gated  = 0
[PASS] T1 min        = 5
[PASS] T1 max        = 50
[PASS] T1 count      = 10
[PASS] T1 avg        = 27
[PASS] T1 stddev     = 15
[PASS] T1 delta      = 45

-- T2: illegal STOP --
[PASS] T2 error      = 16

-- T3: DATA before START --
[PASS] T3 error set  = 16
[PASS] T3 error clr  = 0

-- T4: single sample --
[PASS] T4 run count  = 1
[PASS] T4 run min    = 200
[PASS] T4 min        = 200
[PASS] T4 max        = 200
[PASS] T4 count      = 1
[PASS] T4 avg        = 200
[PASS] T4 stddev     = 0
[PASS] T4 delta      = 0

-- T5: identical samples (5x50) --
[PASS] T5 min        = 50
[PASS] T5 max        = 50
[PASS] T5 count      = 5
[PASS] T5 avg        = 50
[PASS] T5 stddev     = 0
[PASS] T5 delta      = 0

-- T6: two-point spread (0, 254) --
[PASS] T6 min        = 0
[PASS] T6 max        = 254
[PASS] T6 count      = 2
[PASS] T6 avg        = 127
[PASS] T6 stddev     = 127
[PASS] T6 delta      = 254

-- T7: restart after DONE --
[PASS] T7 min        = 10
[PASS] T7 max        = 30
[PASS] T7 count      = 3
[PASS] T7 avg        = 20
[PASS] T7 stddev     = 8
[PASS] T7 delta      = 20

-- T8: large samples (100000, 300000) --
[PASS] T8 min        = 100000
[PASS] T8 max        = 300000
[PASS] T8 count      = 2
[PASS] T8 avg        = 200000
[PASS] T8 stddev     = 100000
[PASS] T8 delta      = 200000

-- T9: START aborts finalization --
[PASS] T9 busy       = 64
[PASS] T9 gated      = 0
[PASS] T9 status     = 128
[PASS] T9 min        = 7
[PASS] T9 max        = 7
[PASS] T9 count      = 2
[PASS] T9 avg        = 7
[PASS] T9 stddev     = 0
[PASS] T9 delta      = 0

-- T10: all-zero samples --
[PASS] T10 min       = 0
[PASS] T10 max       = 0
[PASS] T10 count     = 4
[PASS] T10 avg       = 0
[PASS] T10 stddev    = 0
[PASS] T10 delta     = 0

-- T11: single max sample (2^32-1) --
[PASS] T11 min       = 4294967295
[PASS] T11 max       = 4294967295
[PASS] T11 count     = 1
[PASS] T11 avg       = 4294967295
[PASS] T11 stddev    = 0
[PASS] T11 delta     = 0

-- T12: sum-of-squares overflow --
[PASS] T12 error     = 16
[PASS] T12 min       = 4294967295
[PASS] T12 max       = 4294967295
[PASS] T12 count     = 2
[PASS] T12 avg       = 4294967295
[PASS] T12 stddev    = 0
[PASS] T12 delta     = 0

-- T13: 64 random samples vs reference model --
[PASS] T13 min       = 17693
[PASS] T13 max       = 16080600
[PASS] T13 count     = 64
[PASS] T13 avg       = 7990567
[PASS] T13 stddev    = 4497741
[PASS] T13 delta     = 16062907

*** ALL TESTS PASSED *** (2415 cycles)
```

Worth noting in that transcript: T11 shows exact arithmetic at the largest
representable sample, where the single square 0xFFFFFFFE00000001 occupies
almost the entire 64-bit accumulator. T12 pushes one sample further and
shows the overflow contract: the accumulator saturates, ERROR latches, and
finalization still completes with deterministic values. T13's stddev of
4,497,741 comes out of the bit-serial divider and square root identical to
the software model's answer.

## Assertions (`+define+SMACC_ASSERT`)

Concurrent SVA properties live next to the logic they guard:

- **smacc_ctrl**: every legal FSM transition (and only those), error-flag
  set/sticky/clear semantics, `results_valid` only in DONE, FSM never
  silently returns to IDLE.
- **smacc_top**: PCPI contract: `pcpi_ready` implies `pcpi_valid`, ready is
  a single-cycle pulse, `pcpi_wr` only with ready.
- **smacc_datapath**: `min <= max` whenever samples exist, `dp_done` is a
  one-cycle pulse, abort returns the engine to idle, the restoring-divider
  invariant `remainder < divisor` holds on every iteration, finalization
  never starts with `count == 0`.
- **smacc_mem**: clear resets every accumulator, count increments by
  exactly one per accepted sample, the overflow flag is sticky.

Properties using multi-cycle sequence operators (`##N`), which Verilator
5.x does not support, are kept for commercial simulators and formal tools
behind `` `ifndef VERILATOR ``.

## Reproducing the numbers in the docs

- **Test transcript** (README): output of `bash scripts/run_tests.sh`.
- **Area/flop counts** (DATAPATH_DESIGN.md Section 7): `stat` section at the end
  of `yosys -s scripts/synth.ys`.
- **Finalization latency** (162 cycles): visible in the waveform as the gap
  between the STOP acknowledge and `STATUS_DONE`; the testbench bounds it
  via the poll loop.

## Capturing the Waveform (docs/img/waveform.png)

The image in the README was captured around test T1's STOP. To regenerate
or restyle it:

1. `bash scripts/run_tests.sh --wave` to produce `smacc_tb.vcd`.
2. `gtkwave smacc_tb.vcd` and add these signals from the SST panel:
   `dut.pcpi_valid`, `dut.pcpi_ready`, `dut.u_ctrl.state_r`,
   `dut.u_dp.dstate_r`, `dut.u_dp.dp_done`, `dut.u_dp.avg_r`,
   `dut.u_dp.stddev_r`, `dut.u_dp.delta_r`.
3. Right-click the buses and set Data Format to Decimal (the FSM values
   follow the enums in `smacc_isa_defs.sv` and `smacc_datapath.sv`).
4. Zoom to roughly cycles 25 to 205 (250 ns to 2050 ns): the first STOP,
   the 162-cycle FINALIZING window with the CPU still polling, and the
   `dp_done` pulse.
5. Export with File > Grab To File, saving over `docs/img/waveform.png`.

What to look for: `pcpi_valid`/`pcpi_ready` keep pulsing through the whole
FINALIZING window (the CPU is not stalled), the engine steps through
DIV1/DIV2/VAR/SQRT, and `delta_r`/`avg_r`/`stddev_r` settle to 45/27/15
before the FSM reaches DONE.

## C API Toolchain Check

`sw/example.c` (which exercises every wrapper in `sw/smacc.h`) compiles
clean for the target ISA:

```sh
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 -Wall -Wextra \
    -c sw/example.c -o build/example.o
```

Disassembling the object shows every emitted instruction word matching the
encoding table in ISA_SPEC.md Section 7.2 (rd/rs1 fields vary with the compiler's
register allocation):

```plaintext
0000000b    START
0007100b    DATA   rs1=a4
0000200b    STOP
0000378b    READ   sel=0 (MIN),    rd=a5
0010378b    READ   sel=1 (MAX),    rd=a5
0020378b    READ   sel=2 (AVG),    rd=a5
0030378b    READ   sel=3 (COUNT),  rd=a5
0040378b    READ   sel=4 (STDDEV), rd=a5
0050378b    READ   sel=5 (DELTA),  rd=a5
0060378b    READ   sel=6 (STATUS), rd=a5
```

These are the same words the testbench drives over PCPI, so the C API and
the verified RTL agree on the encoding by construction.

## Known Gaps

- The PicoRV32 + SMACC system wrapper (`smacc_system.sv`) is integration
  glue and is exercised only indirectly; a software-driven system test
  (program in ROM exercising the C API) is future work.
