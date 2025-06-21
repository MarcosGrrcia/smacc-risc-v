# SMACC Datapath Design

## 1. Two-Phase Architecture

SMACC splits the work into a fast accumulation phase and a finalization
phase:

- **DATA phase**: comparators and adders update min/max/count/sum/
  sum_of_squares in parallel, one cycle per DATA instruction.
- **STOP phase**: a 5-stage pipeline computes the statistics that need
  division. The CPU is stalled on `pcpi_wait` until it finishes.

```plaintext
STOP issued (pcpi_wait goes high)
     │
     V
  ┌──────┐   ┌────────┐   ┌────────┐   ┌──────┐   ┌────────┐
  │  S1  │──>│   S2   │──>│   S3   │──>│  S4  │──>│   S5   │──> dp_done
  │snap, │   │avg=    │   │avg_sq= │   │var=  │   │stddev= │    (pcpi_ready)
  │delta │   │sum/N   │   │avg*avg │   │msq-  │   │isqrt   │
  │      │   │msq=    │   │        │   │avg_sq│   │(var)   │
  │      │   │ssq/N   │   │        │   │      │   │        │
  └──────┘   └────────┘   └────────┘   └──────┘   └────────┘
```

**Latency per operation:**

| Operation | Cycles | Notes                                          |
|-----------|--------|------------------------------------------------|
| START     | 1      | Synchronous clear of all accumulators          |
| DATA      | 1      | Comparators + accumulators update in parallel  |
| STOP      | 6      | CPU stalled until the pipeline drains          |
| READ      | 1      | Mux over the output register                   |

---

## 2. Min/Max

Min and max are 32-bit registers reset to `0xFFFF_FFFF` and `0` on START.
On every DATA two comparators run in parallel:

```plaintext
data_in ──┬──> [< min?] ──> MUX ──> min_reg
          └──> [> max?] ──> MUX ──> max_reg
```

Everything is latched on the same edge as the count and sum updates, so
DATA never takes more than one cycle.

---

## 3. Average

- **Accumulators:** 64-bit `sum` and `count`.
- **Division:** `avg = sum / count` in pipeline stage S2 (combinational
  divider).
- **Precision:** integer division, the fraction is dropped. The output
  field is 8 bits and saturates at 255.

---

## 4. Standard Deviation

```plaintext
stddev = sqrt( E[x^2] - E[x]^2 )
       = sqrt( sum_of_squares/count - (sum/count)^2 )
```

| Stage | Computation                                 |
|-------|---------------------------------------------|
| S2    | `mean_sq = sum_of_squares / count`          |
| S3    | `avg_sq = avg * avg`                        |
| S4    | `variance = mean_sq - avg_sq` (clamped to 0)|
| S5    | `stddev = isqrt(variance)`                  |

**isqrt** is the bit-by-bit method: 16 iterations of compare, subtract,
shift, unrolled into combinational logic. 8-bit samples give a variance
under 2^16, so a 32-bit input and 16-bit result are more than enough.

---

## 5. Delta

`delta = max - min`, computed in S1 and saturated to 8 bits.

---

## 6. Design Tradeoffs

**Pipeline vs. one big combinational block.** Putting the two divides, the
multiply, and the square root in one cycle would make an extremely long
path. Splitting them over five stages keeps each stage to one heavy
operation.

**Stalling STOP.** STOP holds `pcpi_wait` until the results are ready.
At 6 cycles this costs almost nothing, and software can read the results
right after STOP returns without polling.

**8-bit output fields.** All statistics fit in one 64-bit register that
READ indexes by byte. The accumulators are still full width, so only the
readout is limited.

**Overflow.** `sum_of_squares` saturates and sets `STATUS_ERROR` when it
would overflow. `sum` is not checked; it would take about 2^32 samples.

---

## 7. Synthesis

`yosys -s scripts/synth.ys` (Yosys 0.33, generic `synth`, no technology
mapping), SMACC only:

| Module           | Cells      |
|------------------|------------|
| smacc_datapath   | 70,039     |
| smacc_mem        | 7,592      |
| smacc_top        | 165        |
| smacc_ctrl       | 54         |
| **Total**        | **77,847** |

1,010 flip-flops, all with synchronous reset. No inferred latches.

Nearly all of it is the datapath, and nearly all of the datapath is the two
64/64 combinational dividers in S2 (~31 K cells each when synthesized on
their own). They are also by far the longest path in the design: 64
dependent subtract/compare steps in a single cycle.
