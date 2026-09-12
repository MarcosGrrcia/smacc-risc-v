// SMACC RTL file list. Paths are relative to the project root.
//
//   verilator --lint-only -Wall -f src/rtl/smacc_rtl.f --top-module smacc_top
//
// smacc_isa_defs.svh is only ever included, so it isn't listed; the
// +incdir below is how the sources find it.
//
// smacc_system.sv and picorv32.v are left out on purpose. They're only
// needed when building the CPU and SMACC together.

+incdir+src/rtl

// Timescale for simulation, set here so the RTL files don't need one.
--timescale 1ns/1ps

src/rtl/smacc_mem.sv
src/rtl/smacc_ctrl.sv
src/rtl/smacc_datapath.sv
src/rtl/smacc_top.sv
