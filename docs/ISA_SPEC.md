# SMACC ISA Specification

**Statistical Math Accelerator: Custom RISC-V Extension**
Version 2.0

Changes from v1.0: READ returns full 32-bit statistics (the packed 64-bit
output register and its 8-bit fields are gone), STOP no longer stalls the
CPU (software polls `STATUS_DONE`), and operations are identified by their
`funct3` value rather than the former "SMACC ID" aliases. Instruction
encodings are **unchanged**: v1.0 binaries decode identically.

---

## Table of Contents

1. [Instruction Format Overview](#1-instruction-format-overview)
2. [Opcode Summary](#2-opcode-summary)
3. [Bit-Level Encodings](#3-bit-level-encodings)
4. [Instruction Behavior](#4-instruction-behavior)
   - 4.1 [START](#41-start-funct3--000)
   - 4.2 [DATA](#42-data-funct3--001)
   - 4.3 [STOP](#43-stop-funct3--010)
   - 4.4 [READ](#44-read-funct3--011)
5. [Statistics and Status Flags](#5-statistics-and-status-flags)
6. [State Machine](#6-state-machine)
7. [Example Instruction Sequences](#7-example-instruction-sequences)
8. [Timing](#8-timing)
9. [Error Conditions](#9-error-conditions)

---

## 1. Instruction Format Overview

SMACC extends the RISC-V ISA with four custom 32-bit instructions. All four
share the RISC-V **custom-0** opcode space (`bits[6:0] = 7'b000_1011 = 0x0B`).
The specific operation is selected by the `funct3` field (`bits[14:12]`).

```plaintext
 31                                15 14   12 11       7 6            0
┌────────────────────────────────────┬───────┬──────────┬──────────────┐
│           operand fields           │funct3 │    rd    │    opcode    │
│          (vary per instr)          │ [2:0] │  [4:0]   │   0001011    │
└────────────────────────────────────┴───────┴──────────┴──────────────┘
                  17                     3        5            7
```

| Field    | Bits    | Width | Purpose                          |
| :------- | :-----: | :---: | :------------------------------- |
| `opcode` | [6:0]   |   7   | Always `7'b000_1011` (custom-0)  |
| `rd`     | [11:7]  |   5   | Destination register (READ only) |
| `funct3` | [14:12] |   3   | SMACC operation selector         |
| `rs1`    | [19:15] |   5   | Source register (DATA only)      |
| `imm`    | [31:20] |  12   | Immediate (READ stat select)     |

---

## 2. Opcode Summary

| Mnemonic | funct3   | Format | Description                                            |
| :------- | :------: | :----: | :----------------------------------------------------- |
| `START`  | `3'b000` | R-type | Initialize all statistics, set READY                   |
| `DATA`   | `3'b001` | I-type | Submit one 32-bit sample, update running stats         |
| `STOP`   | `3'b010` | R-type | Begin finalization of avg/stddev/delta (non-stalling)  |
| `READ`   | `3'b011` | I-type | Read a selected 32-bit statistic into `rd`             |

Only `funct3[1:0]` is decoded; `funct3[2]` is a don't-care (see §9).

---

## 3. Bit-Level Encodings

### 3.1 START: Initialize

**Format:** R-type. No operands. All non-opcode fields are `0`.

```plaintext
 31          25 24      20 19      15 14   12 11       7 6            0
┌──────────────┬──────────┬──────────┬───────┬──────────┬──────────────┐
│    funct7    │   rs2    │   rs1    │funct3 │    rd    │    opcode    │
│   0000000    │  00000   │  00000   │  000  │  00000   │   0001011    │
└──────────────┴──────────┴──────────┴───────┴──────────┴──────────────┘
       7            5          5         3        5            7
```

**Machine encoding:** `32'h0000_000B`

---

### 3.2 DATA: Input Data Point

**Format:** I-type. `rs1` holds the 32-bit sample value already loaded into a RISC-V register. `imm` and `rd` must be zero.

```plaintext
 31                     20 19      15 14   12 11       7 6            0
┌─────────────────────────┬──────────┬───────┬──────────┬──────────────┐
│        imm[11:0]        │   rs1    │funct3 │    rd    │    opcode    │
│       000000000000      │   src    │  001  │  00000   │   0001011    │
└─────────────────────────┴──────────┴───────┴──────────┴──────────────┘
             12                5         3        5            7
```

| Field    | Value         | Notes                             |
| :------- | :-----------: | :-------------------------------- |
| `imm`    | `12'b0`       | Reserved, must be zero            |
| `rs1`    | `x0`-`x31`    | Register index holding the sample |
| `funct3` | `3'b001`      | Encodes DATA operation            |
| `rd`     | `5'b0`        | Reserved, must be zero            |
| `opcode` | `7'b000_1011` | RISC-V custom-0                   |

**Machine encoding (rs1 = x`N`):** `32'h0000_100B | (N << 15)`

Example with `rs1 = x1`: `32'h0000_900B`

---

### 3.3 STOP: Begin Finalization

**Format:** R-type. No operands. All non-opcode fields are `0`.

```plaintext
 31          25 24      20 19      15 14   12 11       7 6            0
┌──────────────┬──────────┬──────────┬───────┬──────────┬──────────────┐
│    funct7    │   rs2    │   rs1    │ funct3│    rd    │    opcode    │
│   0000000    │  00000   │  00000   │  010  │  00000   │   0001011    │
└──────────────┴──────────┴──────────┴───────┴──────────┴──────────────┘
       7            5          5         3        5            7
```

**Machine encoding:** `32'h0000_200B`

---

### 3.4 READ: Output Statistic

**Format:** I-type. `imm[2:0]` selects the statistic; the full 32-bit value
is written to `rd`.

```plaintext
 31                     20 19      15 14   12 11       7 6            0
┌─────────────────────────┬──────────┬───────┬──────────┬──────────────┐
│        imm[11:0]        │   rs1    │ funct3│    rd    │    opcode    │
│       000000000SSS      │  00000   │  011  │   dst    │   0001011    │
└─────────────────────────┴──────────┴───────┴──────────┴──────────────┘
             12                5         3        5            7
```

`SSS` = `imm[2:0]`, the statistic select field:

| `imm[2:0]` | Statistic    | Width  | Valid when                            |
| :--------: | :----------- | :----: | :------------------------------------ |
| `3'b000`   | Min          | 32-bit | After first DATA (reads 0 before)     |
| `3'b001`   | Max          | 32-bit | After first DATA                      |
| `3'b010`   | Average      | 32-bit | `STATUS_DONE` (reads 0 otherwise)     |
| `3'b011`   | Count        | 32-bit | Always (saturates at 2^32-1)          |
| `3'b100`   | Stddev       | 32-bit | `STATUS_DONE` (reads 0 otherwise)     |
| `3'b101`   | Delta        | 32-bit | `STATUS_DONE` (reads 0 otherwise)     |
| `3'b110`   | Status flags | 32-bit | Always; status byte in bits [7:0]     |
| `3'b111`   | Reserved     | --     | Reads 0                               |

**Machine encoding (stat = `S`, rd = x`N`):** `32'h0000_300B | (S << 20) | (N << 7)`

Example: read Count into x2 (`imm=3`, rd=x2): `32'h0030_310B`

---

## 4. Instruction Behavior

### 4.1 START (funct3 = 000)

**Precondition:** Any state. START forces the FSM to `READY`. If called from `ACCUMULATE` or `FINALIZING`, it aborts the in-progress sequence; it clears `STATUS_ERROR` in all cases.

**Effect on internal memory (`smacc_mem.sv`):**

| Register         | Reset Value     | Width  |
| :--------------- | :-------------: | :----: |
| `min`            | `32'hFFFF_FFFF` | 32-bit |
| `max`            | `32'h0000_0000` | 32-bit |
| `count`          | `64'h0`         | 64-bit |
| `sum`            | `64'h0`         | 64-bit |
| `sum_of_squares` | `64'h0`         | 64-bit |

Average, stddev, and delta are produced by the finalization engine
(`smacc_datapath.sv`) and are architecturally visible only while the FSM is
in `DONE`. Leaving `DONE` (which START forces) makes them read as 0, so no
explicit clear is needed.

**State transition:** → `READY`

**Latency:** 1 cycle.

---

### 4.2 DATA (funct3 = 001)

**Precondition:** State must be `READY` or `ACCUMULATE`. Issuing DATA in `IDLE`, `DONE`, or `FINALIZING` sets the ERROR flag and discards the sample.

**Input:** 32-bit unsigned value from RISC-V register `rs1`.

**Single-cycle parallel update:**

```systemverilog
// Comparators
if (rs1_val < min)  min <= rs1_val;
if (rs1_val > max)  max <= rs1_val;

// Accumulators
count          <= count + 1;
sum            <= sum + rs1_val;
sum_of_squares <= sum_of_squares + (rs1_val * rs1_val);  // 64-bit
// Average is NOT computed during DATA; it is finalized on STOP.
```

READ returns running min/max/count directly from these registers, so a READ
issued any time after a DATA retires observes the updated values (e.g.
READ COUNT immediately after the first DATA returns 1; see §7.5).

**State transition:** `READY` → `ACCUMULATE` (on first DATA); `ACCUMULATE` → `ACCUMULATE` (subsequent).

**Latency:** 1 cycle.

---

### 4.3 STOP (funct3 = 010)

**Precondition:** State must be `ACCUMULATE`. Issuing STOP from any other state (`IDLE`, `READY`, `FINALIZING`, or `DONE`) sets `STATUS_ERROR` and leaves the FSM state unchanged; no computation is attempted.

**Behavior:** STOP acknowledges on the same cycle it is issued; **the CPU is
not stalled**. It starts the finalization engine
(`smacc_datapath.sv`, see [DATAPATH_DESIGN.md](DATAPATH_DESIGN.md)), which
runs in the background for a fixed 162 cycles:

```plaintext
load :   1 cycle    snapshot accumulators; delta = max - min
DIV1 :  64 cycles   avg     = sum / count            (restoring divide)
DIV2 :  64 cycles   mean_sq = sum_of_squares / count (same divider, reused)
VAR  :   1 cycle    variance = mean_sq - avg^2       (floored to 0)
SQRT :  32 cycles   stddev  = isqrt(variance)        (bit-serial)
```

While the engine runs, the FSM reports `STATUS_BUSY`; software polls the
STATUS byte until `STATUS_DONE` is set (§7.3), then reads the results.
DATA issued during finalization is an error (§9); START aborts the engine
and re-arms a fresh run; READ is always allowed (derived statistics read as
0 until `STATUS_DONE`).

**State transition:** `ACCUMULATE` → `FINALIZING` → (162 cycles) → `DONE`

**Latency:** 1 cycle to issue; 162 cycles of background computation,
independent of `count` or sample values.

---

### 4.4 READ (funct3 = 011)

**Precondition:** Any state. READ is non-destructive and does not alter internal memory or FSM state.

**Effect:** Writes the selected statistic, as a full 32-bit value, to the
RISC-V destination register `rd`:

```systemverilog
case (imm[2:0])
  3'b000: rd <= (count == 0) ? 32'h0 : min;       // Min
  3'b001: rd <= max;                              // Max
  3'b010: rd <= done ? avg    : 32'h0;            // Average
  3'b011: rd <= (count > 32'hFFFF_FFFF)           // Count (saturating)
                ? 32'hFFFF_FFFF : count[31:0];
  3'b100: rd <= done ? stddev : 32'h0;            // Stddev
  3'b101: rd <= done ? delta  : 32'h0;            // Delta
  3'b110: rd <= {24'h0, status_byte};             // Status flags
  3'b111: rd <= 32'h0;                            // Reserved
endcase
```

`done` means the FSM is in the `DONE` state. Average, stddev, and delta read
as 0 everywhere else (before the first STOP, during finalization, after a new
START), so software never observes stale or partially-computed values.

**State transition:** None.

**Latency:** 1 cycle.

---

## 5. Statistics and Status Flags

All statistics are full 32-bit unsigned values. Internal accumulators are
64-bit, so no precision is lost for any 32-bit sample stream until the
explicit overflow conditions of §9.

| Statistic | Source                          | Availability                       |
| :-------- | :------------------------------ | :--------------------------------- |
| Min       | `smacc_mem` register (live)     | Continuous; 0 while count = 0      |
| Max       | `smacc_mem` register (live)     | Continuous                         |
| Count     | `smacc_mem` register (live)     | Continuous; saturates at 2^32-1    |
| Average   | finalization engine             | `DONE` state only                  |
| Stddev    | finalization engine             | `DONE` state only                  |
| Delta     | finalization engine             | `DONE` state only                  |

### Status Byte (READ with `imm[2:0] = 6`, zero-extended to 32 bits)

| Bit   | Mask   | Name           | Meaning                                         |
| :---: | :----: | :------------- | :---------------------------------------------- |
| 7     | `0x80` | `STATUS_READY` | Accelerator initialized, accepting DATA         |
| 6     | `0x40` | `STATUS_BUSY`  | Finalization in progress (engine running)       |
| 5     | `0x20` | `STATUS_DONE`  | STOP complete; avg, stddev, and delta are valid |
| 4     | `0x10` | `STATUS_ERROR` | Invalid opcode sequence or internal overflow    |
| 3:0   | --     | reserved       | Always `4'b0000`                                |

---

## 6. State Machine

```plaintext
                         ┌────────────────────────────────────────┐
                         │         START  (from any state)        │
                         │  → READY; mem cleared; STATUS_ERROR=0  │
                         └────────────────┬───────────────────────┘
                                          │
         ┌───────────────────────┐        │
         │         IDLE          │        │
         │   no valid data       │        │
         │   STATUS  = none      │        │
         └───────────┬───────────┘        │
                     │ START              │
                     V                    │
         ┌───────────────────────┐ <──────┘
         │         READY         │
         │     STATUS_READY=1    │
         └───────────┬───────────┘
                     │ DATA
                     V
         ┌───────────────────────┐
         │      ACCUMULATE       │──┐
         │     STATUS_READY=1    │  │ DATA (each sample)
         └───────────┬───────────┘<─┘
                     │ STOP (acks same cycle; CPU keeps running)
                     V
         ┌───────────────────────┐
         │       FINALIZING      │
         │     STATUS_BUSY=1     │
         │  engine computes avg, │
         │  stddev, delta in the │
         │  background (162 cyc) │
         └───────────┬───────────┘
                     │ done
                     V
         ┌───────────────────────┐
         │         DONE          │
         │     STATUS_DONE=1     │
         │   all fields valid    │
         └───────────────────────┘

READ is valid in any state; does not change state or internal registers.
DATA in IDLE, DONE, or FINALIZING → STATUS_ERROR=1, sample discarded, state unchanged.
STOP in IDLE, READY, FINALIZING, or DONE → STATUS_ERROR=1, state unchanged.
START in FINALIZING aborts the engine and re-arms a fresh run.
STATUS_ERROR is a sticky flag; it persists until cleared by START.
```

### State Encoding

| State name   | `state[2:0]` | STATUS bits active |
| :----------- | :----------: | :----------------- |
| `IDLE`       | `3'b000`     | none               |
| `READY`      | `3'b001`     | `STATUS_READY`     |
| `ACCUMULATE` | `3'b010`     | `STATUS_READY`     |
| `FINALIZING` | `3'b011`     | `STATUS_BUSY`      |
| `DONE`       | `3'b100`     | `STATUS_DONE`      |

`STATUS_ERROR` (bit 4 of the status byte) is an independent sticky flag, not a separate FSM state. It can be set in any state and is cleared only by `START`.

---

## 7. Example Instruction Sequences

### 7.1 Minimal: Three Samples

```asm
; Initialize accelerator
smacc.start                     ; 32'h0000_000B, clears all stats

; Load and submit sample 1 (value = 10)
li      x1, 10
smacc.data x1                   ; 32'h0000_900B, min=10, max=10, count=1

; Load and submit sample 2 (value = 30)
li      x1, 30
smacc.data x1                   ; min=10, max=30, count=2

; Load and submit sample 3 (value = 20)
li      x1, 20
smacc.data x1                   ; min=10, max=30, count=3
                                ; (avg/stddev/delta still read as 0)

; Begin finalization, returns immediately, engine runs 162 cycles
smacc.stop                      ; 32'h0000_200B

; Wait for completion (see 7.3)
poll:
  smacc.read  x9, STATUS        ; 32'h0060_348B
  andi        x9, x9, 0x20      ; STATUS_DONE
  beqz        x9, poll
                                ;   stddev = isqrt(((100+900+400)/3) - 20^2)
                                ;          = isqrt(466 - 400) = isqrt(66) = 8
                                ;   delta  = 30 - 10 = 20

; Read individual statistics into RISC-V registers (full 32-bit values)
smacc.read x2, MIN              ; 32'h0000_310B, x2 = 10
smacc.read x3, MAX              ; 32'h0010_318B, x3 = 30
smacc.read x4, AVG              ; 32'h0020_320B, x4 = 20
smacc.read x5, COUNT            ; 32'h0030_328B, x5 = 3
smacc.read x6, STDDEV           ; 32'h0040_330B, x6 = 8
smacc.read x7, DELTA            ; 32'h0050_338B, x7 = 20
smacc.read x8, STATUS           ; 32'h0060_340B, x8 = 0x20 (STATUS_DONE)
```

No standard assembler defines the `smacc.*` mnemonics, so use the C wrappers
in [`sw/smacc.h`](../sw/smacc.h), which emit these encodings via `.insn`.

### 7.2 Machine Encoding Reference

| Assembly                | Hex Encoding  | Notes              |
| :---------------------- | :-----------: | :----------------- |
| `smacc.start`           | `0x0000_000B` | No operands        |
| `smacc.data x1`         | `0x0000_900B` | rs1 = x1 (index 1) |
| `smacc.data x5`         | `0x0002_900B` | rs1 = x5 (index 5) |
| `smacc.stop`            | `0x0000_200B` | No operands        |
| `smacc.read x2, MIN`    | `0x0000_310B` | imm=0, rd=x2       |
| `smacc.read x2, MAX`    | `0x0010_310B` | imm=1, rd=x2       |
| `smacc.read x2, AVG`    | `0x0020_310B` | imm=2, rd=x2       |
| `smacc.read x2, COUNT`  | `0x0030_310B` | imm=3, rd=x2       |
| `smacc.read x2, STDDEV` | `0x0040_310B` | imm=4, rd=x2       |
| `smacc.read x2, DELTA`  | `0x0050_310B` | imm=5, rd=x2       |
| `smacc.read x2, STATUS` | `0x0060_310B` | imm=6, rd=x2       |

### 7.3 Post-STOP Completion Check

`STOP` returns immediately; software **must** confirm `STATUS_DONE` before
reading average, stddev, or delta (they read as 0 until then):

```asm
smacc.stop                      ; engine starts; CPU keeps executing

poll:
  smacc.read  x1, STATUS        ; read status flags
  andi        x1, x1, 0x20      ; test STATUS_DONE (bit 5 of status byte)
  beqz        x1, poll          ; ~162 cycles of polling on PicoRV32

; safe to read avg, stddev, and delta here
smacc.read  x2, STDDEV
smacc.read  x3, DELTA
```

The gap between STOP and the poll loop is free compute time: the CPU can do
unrelated work while the engine runs.

### 7.4 Restart After First Sequence

```asm
; First dataset
smacc.start
smacc.data  x1                  ; ... N samples ...
smacc.stop
; ... poll STATUS_DONE, read results ...

; Second dataset, START clears all accumulators
smacc.start                     ; resets from DONE to READY
smacc.data  x1                  ; fresh accumulation
smacc.stop
```

### 7.5 READ During Accumulation (Non-Destructive Monitor)

Min, Max, Count, and Status are served live from the accumulator registers
and can be polled mid-run without disturbing the accumulation. Average,
Stddev, and Delta read back as `0` until finalization completes.

```asm
smacc.start
li    x1, 50
smacc.data  x1                  ; min=50, max=50, count=1

smacc.read  x2, COUNT           ; x2 = 1, peek at running count
smacc.read  x3, STATUS          ; x3 = STATUS_READY (not DONE)

li    x1, 100
smacc.data  x1                  ; min=50, max=100, count=2

smacc.read  x2, MAX             ; x2 = 100, running max, no STOP required
smacc.read  x4, AVG             ; x4 = 0, average not finalized yet
smacc.stop                      ; begin finalization; poll before reading AVG
```

---

## 8. Timing

| Operation | Issue cycles | Notes                                                     |
| :-------- | :----------: | :-------------------------------------------------------- |
| `START`   | 1            | Synchronous clear                                         |
| `DATA`    | 1            | Comparators, counter, and accumulators update in parallel |
| `STOP`    | 1            | Plus 162 background cycles; CPU is **not** stalled        |
| `READ`    | 1            | Combinational mux                                         |

**Finalization latency:** fixed at 162 cycles (1 load + 64 divide + 64
divide + 1 variance + 32 isqrt), independent of count and sample values.
`pcpi_wait` is never asserted.

---

## 9. Error Conditions

| Condition                             | Response                                                               |
| :------------------------------------ | :--------------------------------------------------------------------- |
| `DATA` received in `IDLE` state       | `STATUS_ERROR=1`, sample discarded, state unchanged                    |
| `DATA` received in `DONE` state       | `STATUS_ERROR=1`, sample discarded, state unchanged                    |
| `DATA` received in `FINALIZING` state | `STATUS_ERROR=1`, sample discarded, state unchanged                    |
| `STOP` received in `IDLE` state       | `STATUS_ERROR=1`, state unchanged                                      |
| `STOP` received in `READY` state      | `STATUS_ERROR=1`, state unchanged (count=0, no computation attempted)  |
| `STOP` received in `FINALIZING` state | `STATUS_ERROR=1`, state unchanged (finalization already in progress)   |
| `STOP` received in `DONE` state       | `STATUS_ERROR=1`, state unchanged                                      |
| 64-bit overflow in `sum`              | `STATUS_ERROR=1`, `sum` saturates at `64'hFFFF_FFFF_FFFF_FFFF`         |
| 64-bit overflow in `sum_of_squares`   | `STATUS_ERROR=1`, saturates at `64'hFFFF_FFFF_FFFF_FFFF`               |

**Saturation, not wraparound:** readouts never wrap. Count saturates at
2^32-1 (without raising ERROR; the internal 64-bit counter stays exact for
sum/avg purposes). The average readout saturates at 2^32-1 in the
sum-overflow case. Whenever `STATUS_ERROR` is set, the derived statistics
are not meaningful and should be discarded.

**No "unknown opcode" case exists within custom-0:** the decoder keys only on `funct3[1:0]`, and all four combinations are defined (START/DATA/STOP/READ). `funct3[2]` is a don't-care, so any value of it aliases to one of these four operations; there is no SMACC-internal NOP path.

**`STATUS_ERROR` is sticky:** once set, it remains `1` until cleared by `START`. Software can detect an error by testing bit 4 (`0x10`) of the status byte. `START` resets `STATUS_ERROR` along with all accumulators.

---

*This specification corresponds to SMACC RTL modules: `smacc_isa_defs.sv`, `smacc_ctrl.sv`, `smacc_mem.sv`, `smacc_datapath.sv`, `smacc_top.sv`.*
