# SMACC: Statistical Math Accelerator for RISC-V

SMACC is a coprocessor for the [PicoRV32](https://github.com/YosysHQ/picorv32)
RISC-V core that computes statistics over a stream of 32-bit samples: min,
max, count, average, standard deviation, and range. The CPU drives it with
four custom instructions over PicoRV32's PCPI interface.

SMACC started as our System-on-Chip course project in Fall 2024 (tagged
`v1.0`). Since then READ returns full 32-bit statistics instead of 8-bit
fields, the RTL has been cleaned up (synchronous reset throughout,
warning-free under Verilator `-Wall`), and the design has SVA checks.

## Instruction Set

All four instructions live in the RISC-V *custom-0* opcode space (`0x0B`);
see [docs/ISA_SPEC.md](docs/ISA_SPEC.md) for encodings:

| Instruction | Action                                                  |
|-------------|---------------------------------------------------------|
| `START`     | Clear all state, begin a new run                        |
| `DATA rs1`  | Accumulate one 32-bit sample (single cycle)             |
| `STOP`      | Compute avg/stddev/delta (stalls the CPU for 6 cycles)  |
| `READ rd,n` | Read statistic *n* as a full 32-bit value               |

## Quick Start

Requires [Verilator](https://verilator.org) >= 5.0 (and optionally
[Yosys](https://yosyshq.net/yosys/) + GTKWave):

```sh
bash scripts/run_tests.sh           # lint + run all 8 test groups (44 checks)
bash scripts/run_tests.sh --wave    # same, plus smacc_tb.vcd for GTKWave
yosys -s scripts/synth.ys           # synthesis sanity check + area report
```

## Repository Layout

```plaintext
src/rtl/      SMACC RTL + PicoRV32 base core
src/tb/       Self-checking testbench
docs/         ISA spec, datapath design
scripts/      Test runner and synthesis check
```

## Known Issues

- The datapath is big. Both divides are single-cycle combinational
  64/64 dividers, and they're most of the area (see
  [docs/DATAPATH_DESIGN.md](docs/DATAPATH_DESIGN.md)).
- STOP stalls the CPU until the pipeline drains.

## Authors

- **Marcos Garcia** ([@MarcosGrrcia](https://github.com/MarcosGrrcia))
- **Calvin L. Brown** ([@Cohbalt](https://github.com/Cohbalt))

## License

MIT; see [LICENSE](LICENSE). The bundled PicoRV32 core
([src/rtl/picorv32.v](src/rtl/picorv32.v)) is by Claire Xenia Wolf, ISC
license.
