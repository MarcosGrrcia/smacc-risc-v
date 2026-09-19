# SMACC Datapath Design

## 1. Two phases

The work is split into a fast accumulate phase and a slow finalize phase:

- **DATA**: comparators and adders update min/max/count/sum/sum-of-squares
  in parallel, one cycle per DATA instruction.
- **STOP**: a sequential engine computes the statistics that need division,
  over 162 cycles, in the background. The CPU isn't stalled. It polls
  `STATUS_DONE` (ISA_SPEC.md §7.3) or does other work.

```plaintext
STOP (acks same cycle)
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

| Operation | Cycles | Notes                                           |
|-----------|--------|-------------------------------------------------|
| START     | 1      | Synchronous clear of the accumulators           |
| DATA      | 1      | Comparators and accumulators, all in parallel   |
| STOP      | 1      | Just starts the engine; 162 cycles in background|
| READ      | 1      | Combinational mux over mem / engine / status    |

The critical path is the DATA accumulate in `smacc_mem`: a 32x32 multiply,
a 65-bit add, and the saturate mux. That comes with single-cycle DATA.
Everything in the engine is a short compare/subtract or add between
registers, and there's no combinational divider anywhere.

---

## 2. Min/max

Min and max are 32-bit registers that START sets to `0xFFFF_FFFF` and `0`.
On each DATA two comparators run in parallel:

```plaintext
data_in ──┬──> [< min?] ──> MUX ──> min_reg
          └──> [> max?] ──> MUX ──> max_reg
```

They latch on the same edge as the count and sum updates, so there's no
extra cycle. READ gets min/max/count straight from these registers, so the
running values are always current. Min reads as 0 while `count == 0` so the
`0xFFFF_FFFF` reset value never shows up in software.

---

## 3. Average

- **Accumulators:** 64-bit `sum` and `count`, enough for ~4 x 10^9
  max-valued 32-bit samples before saturating.
- **Overflow:** the add is one bit wider and its carry-out is the overflow
  flag (see §6). The accumulator saturates at `64'hFFFF...` and sets
  STATUS_ERROR.
- **Division:** `avg = sum / count` on the shared restoring divider, one
  quotient bit per cycle for 64 cycles, ~200 gates of compare/subtract
  logic. The quotient always fits in 32 bits (avg can't be bigger than the
  largest sample), except when `sum` saturated, and then the readout clamps
  at 2^32-1.
- **Precision:** truncating integer divide, so you lose the fraction and
  nothing else.

---

## 4. Standard deviation

```plaintext
stddev = sqrt( E[x^2] - E[x]^2 )
       = sqrt( sum_of_squares/count - (sum/count)^2 )
```

| Step | Cycles | Computation                                         |
|------|--------|-----------------------------------------------------|
| DIV1 | 64     | `avg = sum / count`                                 |
| DIV2 | 64     | `mean_sq = sum_of_squares / count` (same divider)   |
| VAR  | 1      | `variance = mean_sq - avg^2` (floored at 0)         |
| SQRT | 32     | `stddev = isqrt(variance)`                          |

avg^2 doesn't need a multiplier. avg is known once DIV1 is done and DIV2
never reads it, so a separate shift-add squarer runs during DIV2. It has its
own shift register and counter: avg shifts out MSB first while the
accumulator does `acc ← 2·acc + (bit ? avg : 0)`. That takes 32 cycles,
well inside DIV2's 64, so it doesn't add any latency.

The square root is a bit-serial restoring isqrt: 64-bit radicand, 32-bit
root, one root bit per cycle for 32 cycles. Same compare/subtract/shift
shape as the divider:

```systemverilog
b = 1 << 62;
repeat (32) begin
    if (rem >= (root | b)) begin rem -= (root | b); root = (root >> 1) | b; end
    else                   root >>= 1;
    b >>= 2;
end
```

`root | b` is the same as `root + b` here because `root`'s set bits always
stay above `b` (root shifts right by one each step while `b` drops by two).

The variance of 32-bit samples is at most ((2^32-1)/2)^2 < 2^62, so the
32-bit root never overflows.

---

## 5. Delta

```plaintext
delta = max - min    (32-bit subtract, clamped to 0 if max < min)
```

Computed once, in the load cycle. The clamp is just defensive: after the
first sample `min <= max` always holds, and `smacc_ctrl` won't start the
engine unless at least one DATA came in (there's an assertion for that in
`smacc_datapath`). Like avg and stddev, delta reads as 0 outside DONE.

---

## 6. Tradeoffs

**Sequential engine instead of a pipeline.** Only one finalization is ever
in flight, so a pipeline doesn't buy any throughput, just more hardware. The
original design was a 5-stage pipeline with two single-cycle 64/64
combinational dividers. It came to ~78 K generic cells, and the dividers
were most of the area and the longest path. The sequential engine (one
divider used twice, plus the squarer for avg^2) is ~12.1 K cells, about
6.4x smaller, and the long divider path is gone. What it costs is 162
cycles of latency. With a non-stalling STOP that's hidden: at PicoRV32's
~4 CPI it's only about 40 instructions.

**Non-stalling STOP.** Holding `pcpi_wait` was fine at 6 cycles, not at
162. Letting STOP retire right away also got rid of the STOP handshake
logic in `smacc_top`, which had caused bugs before, and made the
START-during-finalization case something we could actually test.

**64-bit accumulators, 32-bit results.** The accumulators are 64-bit so a
32-bit sample stream doesn't lose anything before the overflow point. Every
statistic comes back as 32 bits. Readouts saturate instead of wrapping
(count at 2^32-1, avg in the sum-overflow case, which is already flagged).

**Gating results instead of clearing them.** avg/stddev/delta sit in the
engine's result registers and are muxed to 0 unless the FSM is in DONE.
START doesn't have to clear them, values mid-computation are never
visible, and old results from a previous run can't leak into a new one.

**Bit-serial isqrt instead of a lookup table.** A table is out of the
question at this width. The bit-serial root is ~300 gates plus three 64-bit
working registers, and it's built the same way as the divider.

**One multiplier.** The only combinational multiplier left is the 32x32
squarer in `smacc_mem`, and it has to stay single-cycle because DATA is.
Two things keep it cheap:

- The sample going into it is gated with `write_enable`. `pcpi_rs1`
  changes on almost every CPU instruction, so without the gate the
  multiplier would keep squaring garbage. With it, it only switches on
  real DATA.
- Overflow is the carry-out of the widened add (`(a + b) > MAX` exactly
  when it carries), which removes the two 64-bit subtract/compare chains a
  headroom check needs. Smaller and faster.

---

## 7. Synthesis

**Reset and abort:** everything uses synchronous active-high reset, the same
in all four blocks, so they come out of reset on the same edge and there
are no recovery/removal constraints. `dp_abort` (START during finalization)
just sends the engine FSM back to idle and leaves the working registers
alone. Whatever's left in them can't be read because results are gated on
DONE.

**Yosys 0.33, generic `synth`, no technology mapping:**

| Metric                       | 5-stage pipeline (v1) | Sequential engine (v2) |
|------------------------------|-----------------------|------------------------|
| Generic cells                | ~77.8 K               | ~12.1 K                |
| Flip-flops                   | 1,010                 | 953                    |
| Inferred latches             | 0                     | 0                      |

Cells from the latest `yosys -s scripts/synth.ys` (12,061 cells, 953 flops):

```plaintext
$_ANDNOT_   3639      $_NOT_         356
$_AND_       381      $_ORNOT_       699
$_DFF_P_      10      $_OR_         1174
$_MUX_       321      $_SDFFE_PP0P_  909
$_NAND_      494      $_SDFFE_PP1P_   32
$_NOR_      1174      $_SDFF_PP0_      2
$_XNOR_      986      $_XOR_        1884
```

943 of the 953 flops map to synchronous-reset cells (`$_SDFF*`) and almost
all of those have an enable. The other 10 are the FSM state bits in
`smacc_ctrl` and `smacc_datapath`, which Yosys re-encodes and whose reset
ends up in the next-state logic. By module: `smacc_mem` 7,318 cells,
`smacc_datapath` 4,036, `smacc_top` 658, `smacc_ctrl` 52.

Most of what's left is the 32x32 squarer in `smacc_mem` and the 64-bit
accumulator and working registers. Next to a ~30 K-cell PicoRV32, ~12.1 K
seems reasonable.

**Power:** almost all flops come out enable-gated (`$_SDFFE_*`), which a
clock-gating pass can turn into clock gates. The engine's working registers
only toggle during the 162-cycle finalization, and the multiplier only on
accepted DATA.

There are no RAMs. All state is in flip-flops.
