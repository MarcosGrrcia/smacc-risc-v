#!/usr/bin/env bash
# Build and run the SMACC testbench with Verilator.
#   ./scripts/run_tests.sh           # run the tests
#   ./scripts/run_tests.sh --wave    # also dump smacc_tb.vcd for GTKWave
set -e
cd "$(dirname "$0")/.."

WAVE=""
if [ "$1" == "--wave" ]; then
    WAVE="--trace +define+DUMP_VCD"
fi

verilator --binary --timing -Wno-fatal $WAVE -Isrc/rtl --top-module smacc_tb \
    -Mdir build/vtb -o smacc_tb_sim src/tb/smacc_tb.sv
./build/vtb/smacc_tb_sim
