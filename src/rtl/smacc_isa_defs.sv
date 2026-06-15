// smacc_isa_defs.sv: SMACC ISA constants for RISC-V Statistical Math Accelerator
// Include with: `include "smacc_isa_defs.sv"

`ifndef SMACC_ISA_DEFS_SV
`define SMACC_ISA_DEFS_SV

// custom-0 opcode (bits[6:0]), shared by all four SMACC instructions
localparam logic [6:0] RISCV_OPCODE_CUSTOM0 = 7'b000_1011;

// Operation selector: funct3[1:0]. funct3[2] is a don't-care
// (ISA_SPEC.md section 9), so it aliases onto these four.
typedef enum logic [1:0] {
    FLV_START = 2'b00, // Initialize statistics, clear memory
    FLV_DATA  = 2'b01, // Submit one 32-bit sample
    FLV_STOP  = 2'b10, // Begin finalization of avg/stddev/delta (non-stalling)
    FLV_READ  = 2'b11  // Read one statistic into rd
} smacc_flavor_e;

// READ statistic selectors: imm[2:0] field of the READ instruction.
// Every READ returns a full 32-bit value (ISA_SPEC.md section 4.4).
typedef enum logic [2:0] {
    STAT_MIN    = 3'd0, // Running minimum (reads 0 until first DATA)
    STAT_MAX    = 3'd1, // Running maximum
    STAT_AVG    = 3'd2, // Average        (reads 0 unless state is DONE)
    STAT_COUNT  = 3'd3, // Sample count   (readout saturates at 2^32-1)
    STAT_STDDEV = 3'd4, // Std deviation  (reads 0 unless state is DONE)
    STAT_DELTA  = 3'd5, // max - min      (reads 0 unless state is DONE)
    STAT_STATUS = 3'd6, // Status flags byte, zero-extended
    STAT_RSVD7  = 3'd7  // Reserved, reads 0
} smacc_stat_sel_e;

typedef enum logic [2:0] {
    ST_IDLE       = 3'b000, // Power-on; no valid data
    ST_READY      = 3'b001, // START done; accepting DATA
    ST_ACCUMULATE = 3'b010, // >=1 DATA received; still accepting
    ST_FINALIZING = 3'b011, // STOP engine running; CPU free, poll STATUS_DONE
    ST_DONE       = 3'b100  // All statistics valid
} smacc_state_e;

localparam int unsigned DATA_W  = 32; // Sample width (rs1) and READ result width
localparam int unsigned ACCUM_W = 64; // Accumulator width: count, sum, sum_of_squares

// Status byte flags (READ with sel = STAT_STATUS, zero-extended to 32 bits)
localparam logic [7:0] STATUS_READY_MASK = 8'h80; // Initialized, accepting DATA
localparam logic [7:0] STATUS_BUSY_MASK  = 8'h40; // Finalization in progress
localparam logic [7:0] STATUS_DONE_MASK  = 8'h20; // avg/stddev/delta valid
localparam logic [7:0] STATUS_ERROR_MASK = 8'h10; // Sticky; cleared only by START

`endif // SMACC_ISA_DEFS_SV
