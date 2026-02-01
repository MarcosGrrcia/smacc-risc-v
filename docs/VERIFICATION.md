# SMACC Verification

How SMACC is tested, what the assertions check, and how to get the same
numbers the docs quote.

## Strategy

Everything runs from one script, in three steps:

1. **Lint**: Verilator `-Wall`, kept clean. The only waivers are for the
   PCPI input bits SMACC doesn't decode (`smacc_top.sv`), each with a
   comment.
2. **Simulation**: a self-checking testbench drives the PCPI bus directly
   and compares all six statistics to expected values, with the SVA in the
   RTL turned on.
3. **Synthesis**: Yosys generic synthesis to make sure the RTL elaborates,
   has no latches, and only uses synchronous-reset flops.

```sh
bash scripts/run_tests.sh          # lint + simulate, assertions on
bash scripts/run_tests.sh --wave   # same, and dumps smacc_tb.vcd for GTKWave
yosys -s scripts/synth.ys          # synthesis + area report
```

## Test plan (`src/tb/smacc_tb.sv`)

| Test | Scenario                          | What it checks                                            |
|------|-----------------------------------|-----------------------------------------------------------|
| T1   | 10-sample run (5 to 50)           | End-to-end math, live running stats, avg gated until done |
| T2   | STOP with no data                 | Illegal sequence sets sticky `STATUS_ERROR`               |
| T3   | DATA before START                 | Sample dropped, error set, START clears it                |
| T4   | Single sample                     | `stddev = delta = 0`, first sample visible right away     |
| T5   | Five identical samples            | Variance is exactly 0                                     |
| T6   | Two-point spread (0, 254)         | Exact stddev when the variance is a perfect square        |
| T7   | Back-to-back runs                 | START clears everything, nothing leaks between runs       |
| T8   | Large samples (100000, 300000)    | Full 32-bit results, well past 8 bits                     |
| T9   | START during finalization         | Engine aborts, BUSY clears, next run is correct           |
| T10  | All-zero samples                  | Every statistic reads 0, count still goes up              |
| T11  | Single max sample (2^32-1)        | Exact math at the top of the range                        |
| T12  | Two max samples                   | sum_of_squares overflow: saturates, sticky ERROR          |
| T13  | 64 random samples (fixed seed)    | Hardware matches a software reference model               |

78 checks in total. For T1 through T12 the expected values are worked out
by hand in a comment next to the test, so you can check the math without
running anything. T13 computes its expected values in the testbench with
64-bit arithmetic that follows the ISA (truncating divides, variance floored
at 0, integer square root).

## Latest run

`bash scripts/run_tests.sh` with Verilator 5.020, assertions on, lint
clean, 78/78 passing:

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

T11 and T12 are the edge cases. One 2^32-1 sample squares to
0xFFFFFFFE00000001, which just fits in 64 bits, and a second one overflows
it: the accumulator saturates, ERROR latches, and finalization still
finishes with deterministic values.

## Assertions (`+define+SMACC_ASSERT`)

The SVA sits next to the logic it checks:

- **smacc_ctrl**: every legal FSM transition and nothing else, error flag
  set/sticky/clear behavior, `results_valid` only in DONE, and the FSM never
  goes back to IDLE on its own.
- **smacc_top**: the PCPI rules. `pcpi_ready` only with `pcpi_valid`, ready
  is a one-cycle pulse, and `pcpi_wr` only with ready.
- **smacc_datapath**: `min <= max` whenever there are samples, `dp_done` is
  a one-cycle pulse, abort sends the engine back to idle,
  `remainder < divisor` on every divider step, and the engine never starts
  with `count == 0`.
- **smacc_mem**: clear resets every accumulator, count goes up by exactly
  one per accepted sample, and the overflow flag is sticky.

Properties that use `##N` sequences, which Verilator 5.x doesn't support,
are kept for commercial simulators and formal tools behind
`` `ifndef VERILATOR ``.

## Reproducing the numbers

- **Test transcript** (above): `bash scripts/run_tests.sh`.
- **Area/flop counts** (DATAPATH_DESIGN.md section 7): the `stat` output at
  the end of `yosys -s scripts/synth.ys`.
- **Finalization latency** (162 cycles): the gap between the STOP ack and
  `STATUS_DONE` in a `--wave` dump. The testbench's poll loop bounds it.

## Known gaps

- `smacc_system.sv` (PicoRV32 + SMACC) isn't simulated. The testbench
  drives `smacc_top` directly, so no program has been run on the CPU with
  it.
