#!/usr/bin/env bash
# Lint the RTL and run the full SMACC test suite (Verilator >= 5.0).
#
# Usage, from the project root:
#   bash scripts/run_tests.sh           # lint + simulate (assertions on)
#   bash scripts/run_tests.sh --wave    # also dump smacc_tb.vcd for GTKWave
set -euo pipefail
cd "$(dirname "$0")/.."

WAVE_ARGS=""
if [[ "${1:-}" == "--wave" ]]; then
    WAVE_ARGS="--trace +define+DUMP_VCD"
fi

echo "== Lint (verilator -Wall) =="
verilator --lint-only -Wall -Isrc/rtl --top-module smacc_top src/rtl/smacc_top.sv
echo "clean"

echo "== Build testbench =="
# shellcheck disable=SC2086  # WAVE_ARGS is intentionally word-split
verilator --binary --timing --assert +define+SMACC_ASSERT $WAVE_ARGS \
    -Isrc/rtl --top-module smacc_tb -Mdir build/vtb -o smacc_tb_sim \
    src/tb/smacc_tb.sv

echo "== Run =="
./build/vtb/smacc_tb_sim
