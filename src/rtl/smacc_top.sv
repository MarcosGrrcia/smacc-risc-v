// smacc_top.sv: SMACC Accelerator, PicoRV32 PCPI Integration
//
// Decodes PicoRV32 PCPI instructions with custom-0 opcode (7'b000_1011).
// Routes START/DATA/STOP/READ to smacc_ctrl, smacc_datapath, smacc_mem.
//
// Instruction encoding:
//   insn[6:0]   = 7'b000_1011  (RISCV_OPCODE_CUSTOM0)
//   insn[14:12] = funct3;  funct3[1:0]: 00=START  01=DATA  10=STOP  11=READ
//   insn[22:20] = imm[2:0] = stat_sel for READ
//
// PCPI handshake: every instruction acks the cycle it is presented
// (pcpi_wait tied low). STOP launches the 162-cycle engine in the
// background; software polls STATUS_DONE (ISA_SPEC.md section 7.3).
//
// READ returns full 32-bit values: min/max/count from smacc_mem,
// avg/stddev/delta from smacc_datapath (gated to 0 unless ST_DONE).

`ifndef SMACC_TOP_SV
`define SMACC_TOP_SV

`include "smacc_isa_defs.sv"
`include "smacc_ctrl.sv"
`include "smacc_datapath.sv"
`include "smacc_mem.sv"

module smacc_top (
    input  logic        clk,
    input  logic        rst,

    // PicoRV32 PCPI interface
    input  logic        pcpi_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] pcpi_insn,  // only [22:20], [13:12], [6:0] are decoded
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] pcpi_rs1,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] pcpi_rs2,   // unused; SMACC ops only read rs1
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        pcpi_wr,
    output logic [31:0] pcpi_rd,
    output logic        pcpi_wait,
    output logic        pcpi_ready
);

    logic        is_custom0;
    logic        is_read;

    logic        insn_sent_r;
    logic        instr_valid;

    logic        dp_start_final, dp_abort;
    logic [2:0]  stat_sel;
    logic        mem_clear, mem_we_data;
    logic [7:0]  status_byte;
    logic        results_valid;

    logic [DATA_W-1:0]   mem_min_out,    mem_max_out;
    logic [ACCUM_W-1:0]  mem_count_out,  mem_sum_out,  mem_sum_of_sq_out;
    logic                mem_overflow;

    logic [DATA_W-1:0]   dp_avg, dp_stddev, dp_delta;
    logic                dp_done;

    logic [31:0]         read_result;

    assign is_custom0 = pcpi_valid & (pcpi_insn[6:0] == RISCV_OPCODE_CUSTOM0);
    assign is_read    = is_custom0 & (pcpi_insn[13:12] == FLV_READ);
    assign stat_sel   = pcpi_insn[22:20];  // imm[2:0]; selects which statistic READ returns

    // insn_sent_r makes instr_valid a single-cycle strobe even when the
    // master holds pcpi_valid past the acknowledge.
    always_ff @(posedge clk) begin
        if (rst) begin
            insn_sent_r <= 1'b0;
        end else if (~pcpi_valid) begin
            insn_sent_r <= 1'b0;
        end else if (is_custom0 & ~insn_sent_r) begin
            insn_sent_r <= 1'b1;
        end
    end

    assign instr_valid = is_custom0 & ~insn_sent_r;

    smacc_ctrl u_ctrl (
        .clk           (clk),
        .rst           (rst),
        .flavor        (pcpi_insn[13:12]),
        .insn_valid    (instr_valid),
        .dp_start_final(dp_start_final),
        .dp_abort      (dp_abort),
        .mem_clear     (mem_clear),
        .mem_we_data   (mem_we_data),
        .dp_done       (dp_done),
        .mem_overflow  (mem_overflow),
        .status_byte   (status_byte),
        .results_valid (results_valid)
    );

    smacc_mem u_mem (
        .clk          (clk),
        .rst          (rst),
        .clear        (mem_clear),
        .write_enable (mem_we_data),
        .data_in      (pcpi_rs1),
        .min_out      (mem_min_out),
        .max_out      (mem_max_out),
        .count_out    (mem_count_out),
        .sum_out      (mem_sum_out),
        .sum_of_sq_out(mem_sum_of_sq_out),
        .overflow     (mem_overflow)
    );

    smacc_datapath u_dp (
        .clk           (clk),
        .rst           (rst),
        .dp_start_final(dp_start_final),
        .dp_abort      (dp_abort),
        .min_out       (mem_min_out),
        .max_out       (mem_max_out),
        .count_out     (mem_count_out),
        .sum_out       (mem_sum_out),
        .sum_of_sq_out (mem_sum_of_sq_out),
        .dp_avg        (dp_avg),
        .dp_stddev     (dp_stddev),
        .dp_delta      (dp_delta),
        .dp_done       (dp_done)
    );

    // READ result mux (ISA_SPEC.md section 4.4). Running stats come straight from
    // smacc_mem; derived stats are gated to 0 outside ST_DONE.
    always_comb begin
        case (stat_sel)
            STAT_MIN:    read_result = (mem_count_out == '0) ? '0 : mem_min_out;
            STAT_MAX:    read_result = mem_max_out;
            STAT_AVG:    read_result = results_valid ? dp_avg : '0;
            STAT_COUNT:  read_result = (|mem_count_out[ACCUM_W-1:DATA_W])
                                       ? {DATA_W{1'b1}}            // saturate, don't wrap
                                       : mem_count_out[DATA_W-1:0];
            STAT_STDDEV: read_result = results_valid ? dp_stddev : '0;
            STAT_DELTA:  read_result = results_valid ? dp_delta : '0;
            STAT_STATUS: read_result = {24'b0, status_byte};
            default:     read_result = '0;  // STAT_RSVD7
        endcase
    end

    // Non-stalling: every accepted instruction acknowledges immediately.
    assign pcpi_wait  = 1'b0;
    assign pcpi_ready = is_custom0 & ~insn_sent_r;

    assign pcpi_wr = is_read & ~insn_sent_r;
    assign pcpi_rd = read_result;

    // -------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------
`ifdef SMACC_ASSERT

    ast_top_ready_needs_valid: assert property (
        @(posedge clk) disable iff (rst)
        pcpi_ready |-> pcpi_valid
    ) else $error("[smacc_top] pcpi_ready asserted without pcpi_valid");

    ast_top_ready_single_cycle: assert property (
        @(posedge clk) disable iff (rst)
        pcpi_ready |=> ~pcpi_ready
    ) else $error("[smacc_top] pcpi_ready held for more than one cycle");

    ast_top_wr_requires_ready: assert property (
        @(posedge clk) disable iff (rst)
        pcpi_wr |-> pcpi_ready
    ) else $error("[smacc_top] pcpi_wr asserted without pcpi_ready");

    ast_top_instr_valid_single_shot: assert property (
        @(posedge clk) disable iff (rst)
        (instr_valid & pcpi_valid) |=> (pcpi_valid |-> ~instr_valid)
    ) else $error("[smacc_top] instr_valid re-asserted within same pcpi_valid window");

`endif // SMACC_ASSERT

endmodule: smacc_top

`endif // SMACC_TOP_SV
