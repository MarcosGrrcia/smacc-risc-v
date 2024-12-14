// smacc_isa_defs.sv - constants for the SMACC custom instructions
// See docs/ISA_SPEC.md for the encodings.

`ifndef SMACC_ISA_DEFS_SV
`define SMACC_ISA_DEFS_SV

`define SMACC_OPCODE    7'b0001011      // custom-0

// SMACC IDs (funct3[1:0])
`define FLV_START       2'b00
`define FLV_DATA        2'b01
`define FLV_STOP        2'b10
`define FLV_READ        2'b11

// READ field select (imm[2:0])
`define STAT_MIN        3'd0
`define STAT_MAX        3'd1
`define STAT_AVG        3'd2
`define STAT_COUNT      3'd3
`define STAT_STDDEV     3'd4
`define STAT_DELTA      3'd5
`define STAT_STATUS     3'd6

// FSM states
`define ST_IDLE         3'd0
`define ST_READY        3'd1
`define ST_ACCUMULATE   3'd2
`define ST_COMPUTE      3'd3
`define ST_DONE         3'd4

// status byte
`define STATUS_READY    8'h80
`define STATUS_BUSY     8'h40
`define STATUS_DONE     8'h20
`define STATUS_ERROR    8'h10

`endif
