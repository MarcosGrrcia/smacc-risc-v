# SMACC Datapath Design

## 1. Two-Phase Architecture

SMACC splits the work into a fast accumulation phase and a slow, background
finalization phase:

- **DATA phase**: single-cycle accumulation: comparators and adders update
  the min/max/count/sum/sum-of-squares registers in parallel, once per DATA
  instruction.
- **STOP phase**: a sequential finalization engine computes the
  division-heavy statistics over 162 cycles **in the background**. The CPU
  is not stalled; it polls `STATUS_DONE` (ISA_SPEC.md §7.3) or does other work.

```plaintext
STOP dispatch (acks same cycle)
     │
     V
  ┌──────┐   ┌────────┐   ┌────────┐   ┌──────┐   ┌────────┐
  │ load │──>│  DIV1  │──>│  DIV2  │──>│ VAR  │──>│  SQRT  │──> dp_done
  │snap, │   │avg=    │   │msq=    │   │var=  │   │stddev= │
  │delta │   │sum/N   │   │ssq/N   │   │msq-  │   │isqrt   │
  └──────┘   └────────┘   └────────┘   │avg^2 │   │(var)   │
                                       └──────┘   └────────┘
  1 cycle    64 cycles    64 cycles    1 cycle    32 cycles    = 162 total
```

**Latency per operation:**

| Operation | Cycles | Notes                                               |
|-----------|--------|-----------------------------------------------------|
| START     | 1      | Synchronous clear of all accumulators               |
| DATA      | 1      | Combinational comparators + latched accumulators    |
| STOP      | 1      | Issue only; engine runs 162 cycles in background    |
| READ      | 1      | Combinational mux over mem / engine / status        |

**Critical path:** the DATA accumulate cone in `smacc_mem` (a 32x32
multiply, a 65-bit add, and a saturate mux), required by the single-cycle
DATA contract. Everything in the finalization engine is a short,
register-bounded compare/subtract or add. No combinational divider exists
anywhere in the design.

---

## 2. Min/Max Implementation

Min and max are 32-bit registers initialized to sentinel values (`0xFFFF_FFFF` and `0x0000_0000` respectively) on START.

On every DATA cycle, two comparators evaluate in parallel:

```plaintext
data_in ──┬──> [< min?] ──> MUX ──> min_reg
          └──> [> max?] ──> MUX ──> max_reg
```

Both comparators and muxes are purely combinational; the result is latched on the same clock edge as the counter and sum updates. No extra cycle is spent.

READ serves min/max (and count) directly from these registers, so running
values are always current. Min is gated to 0 while `count == 0` so the
sentinel is never visible to software.

---

## 3. Average Calculation

- **Accumulator width:** 64-bit (`sum`, `count`); enough for ~4 x 10^9 samples
  of max-valued 32-bit data before saturating.
- **Overflow detection:** `sum_ovf = (sum > ACCUM_MAX - data_in)` evaluated combinationally before every add; saturates at `64'hFFFF...` and sets STATUS_ERROR.
- **Division:** `avg = sum / count` runs on the shared restoring divider:
  one quotient bit per cycle, 64 cycles, ~200 gates of compare/subtract
  logic. The quotient mathematically fits 32 bits (avg <= max sample); the
  readout saturates at 2^32-1 in the sum-overflow error case.
- **Precision:** integer (truncating) division. The result is now returned
  at full 32-bit width, so the only loss is the discarded fraction (< 1).

---

## 4. Standard Deviation

**Formula:**

```plaintext
stddev = sqrt( E[x^2] - E[x]^2 )
       = sqrt( sum_of_squares/count - (sum/count)^2 )
```

Engine execution:

| Step | Cycles | Computation                                         |
|------|--------|-----------------------------------------------------|
| DIV1 | 64     | `avg = sum / count`                                 |
| DIV2 | 64     | `mean_sq = sum_of_squares / count` (reused divider) |
| VAR  | 1      | `variance = mean_sq - avg^2` (floored to 0)         |
| SQRT | 32     | `stddev = isqrt(variance)`                          |

`avg^2` needs no multiplier: avg is final when DIV2 begins and the divider
does not use it, so a one-adder MSB-first shift-add squarer
(`acc ← 2·acc + (avg[31-k] ? avg : 0)`) runs concurrently with the divide
at **zero added latency**.

**Only computed on STOP** because the formula needs a finalized count.

**isqrt** is a bit-serial restoring square root: 64-bit radicand in,
32-bit root out, one root bit per cycle for 32 cycles. Same
compare-subtract-shift structure as the divider:

```systemverilog
b = 1 << 62;
repeat (32) begin
    if (rem >= (root | b)) begin rem -= (root | b); root = (root >> 1) | b; end
    else                   root >>= 1;
    b >>= 2;
end
```

The `root | b` trick is exact because `root`'s set bits always stay above
`b` (each iteration shifts `root` right once while `b` drops two places).

**Range:** variance of 32-bit samples is at most ((2^32-1)/2)^2 < 2^62, so the
32-bit root never overflows, so no clamp is needed anywhere.

---

## 5. Delta (Max - Min)

```plaintext
delta = max - min    (32-bit subtraction, clamped to 0 if max < min)
```

Computed once, in the load cycle, when the engine snapshots the
accumulators. The clamp is purely defensive: `min` resets
to `0xFFFF_FFFF` and `max` to `0`, so `min <= max` is guaranteed after the
first sample, and `smacc_ctrl` blocks STOP unless at least one DATA was
accumulated (asserted in `smacc_datapath`).

Like avg and stddev, delta is readable only in the `DONE`
state; at all other times READ returns 0 for it.

---

## 6. Design Tradeoffs

**Sequential engine instead of a pipeline.** Only one finalization is ever
in flight, so pipelining buys zero throughput; it only duplicates hardware.
An earlier revision used a 5-stage pipeline with two single-cycle 64/64
combinational dividers; it synthesized to ~78 K generic cells with the
dividers dominating both area and the critical path. The sequential engine
(one shared bit-serial divider reused for both divides, plus the overlapped
bit-serial squarer for avg^2) synthesizes to ~12.2 K cells, a 6.4x
reduction, and removes the long divider path entirely. The price is 162 cycles of latency, which the non-stalling STOP
makes invisible: the CPU polls or does other work, and on PicoRV32
(~4 CPI) the poll loop itself spans a comparable instruction count.

**Non-stalling STOP.** Stalling via `pcpi_wait` was viable at 6 cycles but
would be hostile at 162. Letting STOP retire immediately also deleted the
STOP-specific handshake state in `smacc_top` (a past source of handshake
bugs) and made the START-aborts-finalization path genuinely reachable and
testable.

**64-bit internal vs. 32-bit output.** Accumulators stay 64-bit so that no
32-bit sample stream loses precision before the explicit overflow point.
Every statistic is returned at full 32-bit width, the natural width of a
RISC-V destination register. Readouts saturate rather than wrap (count at
2^32-1; avg in the already-flagged sum-overflow case).

**Result gating instead of result clearing.** avg/stddev/delta live in the
engine's result registers and are muxed to 0 unless the FSM is in `DONE`.
START doesn't need to clear them, in-flight values are never visible, and a
stale result from a previous run can't leak after a restart.

**Bit-serial isqrt vs. lookup table.** A 2^32-entry table is obviously
impossible at this width; the bit-serial root costs ~300 gates plus three
64-bit working registers and shares its structural idiom with the divider.

**One multiplier in the whole design.** The only combinational multiplier
left is the 32x32 squarer in `smacc_mem`. It must stay single-cycle
because the ISA promises one-cycle DATA accumulation. Two power/area
measures keep it cheap:

- **Operand isolation:** the sample operand is gated with `write_enable`.
  `pcpi_rs1` toggles on nearly every CPU instruction, so an ungated
  multiplier would re-square garbage continuously; the gate reduces its
  switching activity to actual DATA operations only.
- **Carry-out overflow detection:** the saturating accumulators use the
  carry out of a widened add as the overflow test
  (`(a + b) > MAX ⟺ carry`), eliminating the two 64-bit subtract/compare
  chains a naive guard needs, so it is both smaller and faster.

---

## 7. Synthesis Considerations

**Reset and abort:** all SMACC state uses synchronous, active-high reset,
one consistent style across `smacc_ctrl`, `smacc_mem`, `smacc_datapath`,
and `smacc_top`, so every block leaves reset on the same clock edge and no
recovery/removal constraints are needed. `dp_abort` (START interrupting
finalization) returns the engine FSM to idle without touching the working
registers; stale contents are unreachable because results are gated by the
`DONE` state.

**Measured (Yosys 0.33, generic `synth`, no technology mapping):**

| Metric                       | 5-stage pipeline (v1) | Sequential engine (v2) |
|------------------------------|-----------------------|------------------------|
| Generic cells                | ~77.8 K               | ~12.2 K                |
| Flip-flops                   | 1,010                 | 915                    |
| Inferred latches             | 0                     | 0                      |
| Reset style of all flops     | synchronous           | synchronous            |
| Synthesis runtime            | ~80 s                 | ~7 s                   |

Cell breakdown from the latest `yosys -s scripts/synth.ys` run (12,172
cells; the SDFF variants are the 915 flops, all synchronous-reset and
mostly enable-gated):

```plaintext
$_ANDNOT_   5543      $_NOT_         330
$_AND_       384      $_ORNOT_       782
$_DFF_P_      10      $_OR_         1148
$_MUX_       322      $_SDFFE_PP0P_  872
$_NAND_      484      $_SDFFE_PP1P_   32
$_NOR_      1145      $_SDFF_PP0_      1
$_XNOR_      972      $_XOR_        1893
```

The remaining v2 area is dominated by the one 32x32 squaring multiplier in
`smacc_mem` and the 64-bit accumulator/working registers. The critical path
is the DATA accumulate cone (32x32 multiply + 65-bit add + saturate mux), which is
inherent to the single-cycle DATA contract. At ~12.2 K generic cells
alongside a ~30 K-cell PicoRV32, the balance is reasonable.

**Power:** nearly all flops infer as enable-gated (`$_SDFFE_*`), which
synthesis flows convert directly into integrated clock gates; the engine's
working registers only toggle during the 162-cycle finalization window, and
the operand-isolated multiplier only toggles on accepted DATA.

No RAM blocks are used; all state fits in flip-flops, keeping the design
portable and timing-predictable.
