# SMACC ISA Specification

**Statistical Math Accelerator: Custom RISC-V Extension**
Version 2.0 (draft)

Changes from v1.0: READ returns full 32-bit statistics; the packed 64-bit
output register and its 8-bit fields are gone. Instruction encodings are
unchanged.

---

## Table of Contents

1. [Instruction Format Overview](#1-instruction-format-overview)
2. [Opcode Summary](#2-opcode-summary)
3. [Bit-Level Encodings](#3-bit-level-encodings)
4. [Instruction Behavior](#4-instruction-behavior)
5. [Statistics and Status Flags](#5-statistics-and-status-flags)
6. [State Machine](#6-state-machine)
7. [Example Instruction Sequences](#7-example-instruction-sequences)
8. [Timing](#8-timing)
9. [Error Conditions](#9-error-conditions)

---

## 1. Instruction Format Overview

SMACC extends the RISC-V ISA with four custom 32-bit instructions. All four
share the RISC-V **custom-0** opcode space (`bits[6:0] = 7'b000_1011 = 0x0B`).
Each instruction is identified by its **SMACC ID**, carried in the `funct3`
field (`bits[14:12]`).

```plaintext
 31                                15 14   12 11       7 6            0
┌────────────────────────────────────┬───────┬──────────┬──────────────┐
│           operand fields           │funct3 │    rd    │    opcode    │
│          (vary per instr)          │ [2:0] │  [4:0]   │   0001011    │
└────────────────────────────────────┴───────┴──────────┴──────────────┘
                  17                     3        5            7
```

| Field    | Bits    | Width | Purpose                           |
| :------- | :-----: | :---: | :-------------------------------- |
| `opcode` | [6:0]   |   7   | Always `7'b000_1011` (custom-0)   |
| `rd`     | [11:7]  |   5   | Destination register (READ only)  |
| `funct3` | [14:12] |   3   | SMACC ID                          |
| `rs1`    | [19:15] |   5   | Source register (DATA only)       |
| `imm`    | [31:20] |  12   | Immediate (READ stat select)      |

---

## 2. Opcode Summary

| Mnemonic | SMACC ID | funct3   | Format | Description                                      |
| :------- | :------: | :------: | :----: | :----------------------------------------------- |
| `START`  | 0        | `3'b000` | R-type | Initialize all statistics, set READY             |
| `DATA`   | 1        | `3'b001` | I-type | Submit one sample, update running stats          |
| `STOP`   | 2        | `3'b010` | R-type | Compute avg/stddev/delta; CPU stalls until done  |
| `READ`   | 3        | `3'b011` | I-type | Read a selected 32-bit statistic into `rd`       |

Only `funct3[1:0]` is decoded; `funct3[2]` is a don't-care (see §9).

---

## 3. Bit-Level Encodings

### 3.1 START (SMACC ID 0)

**Format:** R-type. No operands. All non-opcode fields are `0`.

```plaintext
 31          25 24      20 19      15 14   12 11       7 6            0
┌──────────────┬──────────┬──────────┬───────┬──────────┬──────────────┐
│    funct7    │   rs2    │   rs1    │funct3 │    rd    │    opcode    │
│   0000000    │  00000   │  00000   │  000  │  00000   │   0001011    │
└──────────────┴──────────┴──────────┴───────┴──────────┴──────────────┘
```

**Machine encoding:** `32'h0000_000B`

### 3.2 DATA (SMACC ID 1)

**Format:** I-type. `rs1` holds the sample. `imm` and `rd` must be zero.

```plaintext
 31                     20 19      15 14   12 11       7 6            0
┌─────────────────────────┬──────────┬───────┬──────────┬──────────────┐
│        imm[11:0]        │   rs1    │funct3 │    rd    │    opcode    │
│       000000000000      │   src    │  001  │  00000   │   0001011    │
└─────────────────────────┴──────────┴───────┴──────────┴──────────────┘
```

**Machine encoding (rs1 = x`N`):** `32'h0000_100B | (N << 15)`

Example with `rs1 = x1`: `32'h0000_900B`

### 3.3 STOP (SMACC ID 2)

**Format:** R-type. No operands. All non-opcode fields are `0`.

```plaintext
 31          25 24      20 19      15 14   12 11       7 6            0
┌──────────────┬──────────┬──────────┬───────┬──────────┬──────────────┐
│    funct7    │   rs2    │   rs1    │funct3 │    rd    │    opcode    │
│   0000000    │  00000   │  00000   │  010  │  00000   │   0001011    │
└──────────────┴──────────┴──────────┴───────┴──────────┴──────────────┘
```

**Machine encoding:** `32'h0000_200B`

### 3.4 READ (SMACC ID 3)

**Format:** I-type. `imm[2:0]` selects the statistic; the full 32-bit value
is written to `rd`.

```plaintext
 31                     20 19      15 14   12 11       7 6            0
┌─────────────────────────┬──────────┬───────┬──────────┬──────────────┐
│        imm[11:0]        │   rs1    │funct3 │    rd    │    opcode    │
│       000000000SSS      │  00000   │  011  │   dst    │   0001011    │
└─────────────────────────┴──────────┴───────┴──────────┴──────────────┘
```

| `imm[2:0]` | Statistic    | Width  | Valid when                            |
| :--------: | :----------- | :----: | :------------------------------------ |
| `3'b000`   | Min          | 32-bit | After first DATA (reads 0 before)     |
| `3'b001`   | Max          | 32-bit | After first DATA                      |
| `3'b010`   | Average      | 32-bit | `DONE` (reads 0 otherwise)            |
| `3'b011`   | Count        | 32-bit | Always (saturates at 2^32-1)          |
| `3'b100`   | Stddev       | 32-bit | `DONE` (reads 0 otherwise)            |
| `3'b101`   | Delta        | 32-bit | `DONE` (reads 0 otherwise)            |
| `3'b110`   | Status flags | 32-bit | Always; status byte in bits [7:0]     |
| `3'b111`   | Reserved     | --     | Reads 0                               |

**Machine encoding (stat = `S`, rd = x`N`):** `32'h0000_300B | (S << 20) | (N << 7)`

Example: read Count into x2: `32'h0030_310B`

---

## 4. Instruction Behavior

### 4.1 START

**Precondition:** Any state. Forces the FSM to `READY`, clears the
accumulators, and clears `STATUS_ERROR`. avg/stddev/delta are only visible
in `DONE`, so leaving `DONE` hides them without clearing anything.

| Register         | Reset Value     | Width  |
| :--------------- | :-------------: | :----: |
| `min`            | `32'hFFFF_FFFF` | 32-bit |
| `max`            | `32'h0000_0000` | 32-bit |
| `count`          | `64'h0`         | 64-bit |
| `sum`            | `64'h0`         | 64-bit |
| `sum_of_squares` | `64'h0`         | 64-bit |

**Latency:** 1 cycle.

### 4.2 DATA

**Precondition:** State must be `READY` or `ACCUMULATE`. DATA in `IDLE` or
`DONE` sets `STATUS_ERROR` and the sample is discarded.

```systemverilog
if (rs1_val < min)  min <= rs1_val;
if (rs1_val > max)  max <= rs1_val;
count          <= count + 1;
sum            <= sum + rs1_val;
sum_of_squares <= sum_of_squares + rs1_val * rs1_val;   // 64-bit
```

**State transition:** `READY` → `ACCUMULATE` on the first DATA.

**Latency:** 1 cycle.

### 4.3 STOP

**Precondition:** State must be `ACCUMULATE`. STOP from any other state
sets `STATUS_ERROR`, acks immediately, and leaves the state unchanged.

**Behavior:** SMACC holds `pcpi_wait` high, stalling the CPU, while a
5-stage pipeline computes the derived statistics:

```plaintext
S1 : snapshot sum, sum_of_squares, count;  delta = max - min
S2 : avg = sum / count;  mean_sq = sum_of_squares / count
S3 : avg_sq = avg * avg
S4 : variance = mean_sq - avg_sq   (clamped to 0 if negative)
S5 : stddev = isqrt(variance);  results latched
```

STOP retires 6 cycles after it is issued, with the FSM in `DONE`.

**Latency:** 6 cycles (CPU stalled).

### 4.4 READ

**Precondition:** Any state. Non-destructive.

**Effect:**

```systemverilog
case (imm[2:0])
  3'b000: rd <= (count == 0) ? 32'h0 : min;
  3'b001: rd <= max;
  3'b010: rd <= done ? avg    : 32'h0;
  3'b011: rd <= (count > 32'hFFFF_FFFF) ? 32'hFFFF_FFFF : count[31:0];
  3'b100: rd <= done ? stddev : 32'h0;
  3'b101: rd <= done ? delta  : 32'h0;
  3'b110: rd <= {24'h0, status_byte};
  3'b111: rd <= 32'h0;
endcase
```

`done` means the FSM is in `DONE`.

**Latency:** 1 cycle.

---

## 5. Statistics and Status Flags

Every statistic is a full 32-bit unsigned value. The accumulators are
64-bit, so nothing is lost for a 32-bit sample stream until the overflow
conditions in §9.

### Status Byte

| Bit   | Mask   | Name           | Meaning                                         |
| :---: | :----: | :------------- | :---------------------------------------------- |
| 7     | `0x80` | `STATUS_READY` | Accelerator initialized, accepting DATA         |
| 6     | `0x40` | `STATUS_BUSY`  | STOP computation in progress                    |
| 5     | `0x20` | `STATUS_DONE`  | STOP complete; avg, stddev, and delta are valid |
| 4     | `0x10` | `STATUS_ERROR` | Invalid sequence or accumulator overflow        |
| 3:0   | --     | reserved       | Always `4'b0000`                                |

`STATUS_BUSY` is only set while the CPU is stalled, so software never sees it.

---

## 6. State Machine

```plaintext
         ┌───────────────────────┐
         │         IDLE          │
         └───────────┬───────────┘
                     │ START (from any state)
                     V
         ┌───────────────────────┐
         │         READY         │
         └───────────┬───────────┘
                     │ DATA
                     V
         ┌───────────────────────┐
         │      ACCUMULATE       │──┐ DATA
         └───────────┬───────────┘<─┘
                     │ STOP (CPU stalled)
                     V
         ┌───────────────────────┐
         │        COMPUTE        │
         └───────────┬───────────┘
                     │ pipeline done (6 cycles)
                     V
         ┌───────────────────────┐
         │         DONE          │
         └───────────────────────┘
```

| State        | `state[2:0]` | STATUS bits active |
| :----------- | :----------: | :----------------- |
| `IDLE`       | `3'b000`     | none               |
| `READY`      | `3'b001`     | `STATUS_READY`     |
| `ACCUMULATE` | `3'b010`     | `STATUS_READY`     |
| `COMPUTE`    | `3'b011`     | `STATUS_BUSY`      |
| `DONE`       | `3'b100`     | `STATUS_DONE`      |

`STATUS_ERROR` is a sticky flag, not a state. Only START clears it.

---

## 7. Example Instruction Sequences

### 7.1 Three Samples

```asm
smacc.start                     ; 32'h0000_000B
li      x1, 10
smacc.data x1                   ; 32'h0000_900B
li      x1, 30
smacc.data x1
li      x1, 20
smacc.data x1
smacc.stop                      ; 32'h0000_200B, stalls 6 cycles
                                ;   avg    = 60/3 = 20
                                ;   stddev = isqrt(1400/3 - 400) = isqrt(66) = 8
                                ;   delta  = 30 - 10 = 20
smacc.read x2, MIN              ; 32'h0000_310B, x2 = 10
smacc.read x3, MAX              ; 32'h0010_318B, x3 = 30
smacc.read x4, AVG              ; 32'h0020_320B, x4 = 20
smacc.read x5, COUNT            ; 32'h0030_328B, x5 = 3
smacc.read x6, STDDEV           ; 32'h0040_330B, x6 = 8
smacc.read x7, DELTA            ; 32'h0050_338B, x7 = 20
```

### 7.2 Machine Encoding Reference

| Assembly                | Hex Encoding  |
| :---------------------- | :-----------: |
| `smacc.start`           | `0x0000_000B` |
| `smacc.data x1`         | `0x0000_900B` |
| `smacc.stop`            | `0x0000_200B` |
| `smacc.read x2, MIN`    | `0x0000_310B` |
| `smacc.read x2, MAX`    | `0x0010_310B` |
| `smacc.read x2, AVG`    | `0x0020_310B` |
| `smacc.read x2, COUNT`  | `0x0030_310B` |
| `smacc.read x2, STDDEV` | `0x0040_310B` |
| `smacc.read x2, DELTA`  | `0x0050_310B` |
| `smacc.read x2, STATUS` | `0x0060_310B` |

### 7.3 Restart

START can be issued from `DONE` (or any other state) to begin a new
dataset; it clears everything from the previous run.

### 7.4 READ During Accumulation

Min, max, count, and status are live and can be read at any time without
disturbing the run. avg/stddev/delta read 0 until STOP completes.

---

## 8. Timing

| Operation | Cycles | Notes                                  |
| :-------- | :----: | :------------------------------------- |
| `START`   | 1      |                                        |
| `DATA`    | 1      | All accumulators update in parallel    |
| `STOP`    | 6      | CPU held on `pcpi_wait`                |
| `READ`    | 1      |                                        |

---

## 9. Error Conditions

| Condition                            | Response                                         |
| :----------------------------------- | :----------------------------------------------- |
| `DATA` in `IDLE` or `DONE`           | `STATUS_ERROR=1`, sample discarded               |
| `STOP` in `IDLE`, `READY`, or `DONE` | `STATUS_ERROR=1`, state unchanged                |
| `sum` overflow                       | `STATUS_ERROR=1`, saturates at `64'hFFFF...FFFF` |
| `sum_of_squares` overflow            | `STATUS_ERROR=1`, saturates at `64'hFFFF...FFFF` |

**Saturation, not wraparound:** no readout ever wraps. Count saturates at
2^32-1 (without raising ERROR), and the average saturates at 2^32-1 if
`sum` saturated. Once `STATUS_ERROR` is set the derived statistics should
be discarded.

`funct3[2]` is not decoded, so every custom-0 encoding maps to one of the
four instructions.

---

*Corresponds to RTL: `smacc_isa_defs.sv`, `smacc_ctrl.sv`, `smacc_mem.sv`,
`smacc_datapath.sv`, `smacc_top.sv`.*
