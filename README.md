# SMACC: Statistical Math Accelerator for RISC-V

SMACC is a coprocessor for the [PicoRV32](https://github.com/YosysHQ/picorv32)
RISC-V core that computes statistics over a stream of 32-bit samples: min,
max, count, average, standard deviation, and range. The CPU drives it with
four custom instructions over PicoRV32's PCPI interface.

SMACC started as our System-on-Chip course project in Fall 2024 (tagged
`v1.0`). Since then READ returns full 32-bit statistics instead of 8-bit
fields, the RTL has been cleaned up (synchronous reset throughout,
warning-free under Verilator `-Wall`), the design has SVA checks, and the
pipelined datapath has been replaced by a sequential engine that runs in
the background: STOP no longer stalls the CPU.

## Instruction Set

All four instructions live in the RISC-V *custom-0* opcode space (`0x0B`);
see [docs/ISA_SPEC.md](docs/ISA_SPEC.md) for encodings:

| Instruction | Action                                                  |
|-------------|---------------------------------------------------------|
| `START`     | Clear all state, begin a new run                        |
| `DATA rs1`  | Accumulate one 32-bit sample (single cycle)             |
| `STOP`      | Kick off avg/stddev/delta finalization (returns at once)|
| `READ rd,n` | Read statistic *n* as a full 32-bit value               |

## Quick Start

Requires [Verilator](https://verilator.org) >= 5.0 (and optionally
[Yosys](https://yosyshq.net/yosys/) + GTKWave):

```sh
bash scripts/run_tests.sh           # lint + run all 13 test groups (78 checks)
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

## Results

`yosys -s scripts/synth.ys` puts the accelerator at ~12.7 K generic cells,
down from ~78 K for the original pipelined design. STOP now takes a fixed
162 cycles in the background instead of stalling for 6. Details in
[docs/DATAPATH_DESIGN.md](docs/DATAPATH_DESIGN.md).

## Authors

- **Marcos Garcia** ([@MarcosGrrcia](https://github.com/MarcosGrrcia))
- **Calvin L. Brown** ([@Cohbalt](https://github.com/Cohbalt))

## License

MIT; see [LICENSE](LICENSE). The bundled PicoRV32 core
([src/rtl/picorv32.v](src/rtl/picorv32.v)) is by Claire Xenia Wolf, ISC
license.
