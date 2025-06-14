// smacc_isa_defs.sv: SMACC ISA constants for RISC-V Statistical Math Accelerator
// Include with: `include "smacc_isa_defs.sv"

`ifndef SMACC_ISA_DEFS_SV
`define SMACC_ISA_DEFS_SV

// custom-0 opcode (bits[6:0]), shared by all four SMACC instructions
localparam logic [6:0] RISCV_OPCODE_CUSTOM0 = 7'b000_1011;

// Operation selector: funct3[1:0] ("SMACC ID" in ISA_SPEC.md)
typedef enum logic [1:0] {
    FLV_START = 2'b00, // Initialize statistics, clear memory
    FLV_DATA  = 2'b01, // Submit one 32-bit sample
    FLV_STOP  = 2'b10, // Compute avg/stddev/delta (stalls until done)
    FLV_READ  = 2'b11  // Read one 8-bit field of the output register
} smacc_flavor_e;

// READ field selectors: imm[2:0]. Field n is byte (7-n) of the 64-bit
// output register, so sel 0 is the top byte.
typedef enum logic [2:0] {
    STAT_MIN    = 3'd0,
    STAT_MAX    = 3'd1,
    STAT_AVG    = 3'd2,
    STAT_COUNT  = 3'd3,
    STAT_STDDEV = 3'd4,
    STAT_DELTA  = 3'd5,
    STAT_STATUS = 3'd6,
    STAT_RSVD7  = 3'd7
} smacc_stat_sel_e;

typedef enum logic [2:0] {
    ST_IDLE       = 3'b000, // Power-on; no valid data
    ST_READY      = 3'b001, // START done; accepting DATA
    ST_ACCUMULATE = 3'b010, // >=1 DATA received; still accepting
    ST_COMPUTE    = 3'b011, // STOP in progress; CPU stalled on pcpi_wait
    ST_DONE       = 3'b100  // All statistics valid
} smacc_state_e;

localparam int unsigned DATA_W  = 32; // Sample width (rs1)
localparam int unsigned ACCUM_W = 64; // Accumulator width: count, sum, sum_of_squares
localparam int unsigned FIELD_W = 8;  // Width of each output register field

// Status byte flags (output register field 6)
localparam logic [7:0] STATUS_READY_MASK = 8'h80; // Initialized, accepting DATA
localparam logic [7:0] STATUS_BUSY_MASK  = 8'h40; // STOP computation in progress
localparam logic [7:0] STATUS_DONE_MASK  = 8'h20; // avg/stddev/delta valid
localparam logic [7:0] STATUS_ERROR_MASK = 8'h10; // Sticky; cleared only by START

`endif // SMACC_ISA_DEFS_SV
