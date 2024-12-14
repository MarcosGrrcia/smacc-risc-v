# SMACC: Statistical Math Accelerator for RISC-V

Final project for our System-on-Chip design course, Fall 2024.

SMACC is a coprocessor for the [PicoRV32](https://github.com/YosysHQ/picorv32)
RISC-V core that computes statistics over a stream of samples: min, max,
count, average, standard deviation, and range (max - min). It adds four
custom instructions in the custom-0 opcode space and connects to the core
through PicoRV32's PCPI interface.

## Instructions

| Instruction  | What it does                                        |
|--------------|-----------------------------------------------------|
| `START`      | Clear everything and start a new run                |
| `DATA rs1`   | Add one sample                                      |
| `STOP`       | Compute avg/stddev/delta (stalls the CPU ~6 cycles) |
| `READ rd, n` | Read field `n` of the output register into `rd`     |

Encodings and details are in [docs/ISA_SPEC.md](docs/ISA_SPEC.md). The
datapath is described in [docs/DATAPATH_DESIGN.md](docs/DATAPATH_DESIGN.md)
and the block diagram in [ARCHITECTURE.md](ARCHITECTURE.md).

## Layout

```plaintext
src/rtl/    SMACC RTL + PicoRV32
src/tb/     Testbench
docs/       ISA spec, datapath design
scripts/    run_tests.sh
```

## Running the tests

Needs [Verilator](https://verilator.org) 5.x.

```sh
./scripts/run_tests.sh           # build and run
./scripts/run_tests.sh --wave    # also writes smacc_tb.vcd
```

The testbench drives the PCPI bus directly and runs 7 tests (35 checks)
against hand-computed results.

## Limitations

- READ fields are 8 bits. That's fine for the course sensors (8-bit data),
  but for larger samples min/max/count only show their low byte and
  avg/delta saturate at 255.
- STOP stalls the CPU while the pipeline runs.
- `sum` isn't checked for overflow.

## Team

Marcos Garcia, Calvin Brown
