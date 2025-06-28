// smacc_top.sv: PCPI front end for the SMACC accelerator
//
// Decodes PicoRV32 PCPI instructions with custom-0 opcode (7'b000_1011).
// Routes START/DATA/STOP/READ to smacc_ctrl, smacc_datapath, smacc_mem.
//
// Instruction encoding:
//   insn[6:0]   = 7'b000_1011  (RISCV_OPCODE_CUSTOM0)
//   insn[14:12] = funct3;  funct3[1:0]: 00=START  01=DATA  10=STOP  11=READ
//   insn[22:20] = imm[2:0] = field select for READ
//
// PCPI handshake: START/DATA/READ ack the cycle they are presented. A legal
// STOP holds pcpi_wait until the datapath pipeline drains (6 cycles), then
// acks on dp_done.
//
// READ returns one byte of the 64-bit output register, zero-extended:
//   [63:56] min  [55:48] max    [47:40] avg    [39:32] count
//   [31:24] stddev [23:16] delta [15:8] status [7:0] reserved

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
    logic        stop_wait_r;    // legal STOP in flight; CPU held on pcpi_wait

    logic        dp_start;
    logic [2:0]  stat_sel;
    logic        mem_clear, mem_we_data;
    logic [7:0]  status_byte;

    logic [DATA_W-1:0]   mem_min_out,   mem_max_out;
    logic [ACCUM_W-1:0]  mem_count_out, mem_sum_out, mem_sum_of_sq_out;
    logic                mem_overflow;

    logic [DATA_W-1:0]   dp_avg;
    logic [FIELD_W-1:0]  dp_stddev, dp_delta;
    logic                dp_done;

    logic [63:0]         out_reg;
    logic [FIELD_W-1:0]  min_field, max_field, avg_field, count_field;

    assign is_custom0 = pcpi_valid & (pcpi_insn[6:0] == RISCV_OPCODE_CUSTOM0);
    assign is_read    = is_custom0 & (pcpi_insn[13:12] == FLV_READ);
    assign stat_sel   = pcpi_insn[22:20];

    // insn_sent_r makes instr_valid a single-cycle strobe even when the
    // master holds pcpi_valid past the acknowledge (or through a stall).
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

    always_ff @(posedge clk) begin
        if (rst) begin
            stop_wait_r <= 1'b0;
        end else if (dp_start) begin
            stop_wait_r <= 1'b1;
        end else if (dp_done) begin
            stop_wait_r <= 1'b0;
        end
    end

    smacc_ctrl u_ctrl (
        .clk         (clk),
        .rst         (rst),
        .flavor      (pcpi_insn[13:12]),
        .insn_valid  (instr_valid),
        .dp_start    (dp_start),
        .mem_clear   (mem_clear),
        .mem_we_data (mem_we_data),
        .dp_done     (dp_done),
        .mem_overflow(mem_overflow),
        .status_byte (status_byte)
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
        .clk          (clk),
        .rst          (rst),
        .dp_start     (dp_start),
        .dp_clear     (mem_clear),
        .min_out      (mem_min_out),
        .max_out      (mem_max_out),
        .count_out    (mem_count_out),
        .sum_out      (mem_sum_out),
        .sum_of_sq_out(mem_sum_of_sq_out),
        .dp_avg       (dp_avg),
        .dp_stddev    (dp_stddev),
        .dp_delta     (dp_delta),
        .dp_done      (dp_done)
    );

    // Fields are 8 bits wide: min/max/count report their low byte (count
    // wraps after 255 samples). avg comes out of the datapath full width and
    // is clamped here.
    assign min_field   = mem_min_out[FIELD_W-1:0];
    assign max_field   = mem_max_out[FIELD_W-1:0];
    assign avg_field   = (dp_avg > 32'd255) ? 8'hFF : dp_avg[FIELD_W-1:0];
    assign count_field = mem_count_out[FIELD_W-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            out_reg <= '0;
        end else begin
            out_reg <= {min_field, max_field, avg_field, count_field,
                        dp_stddev, dp_delta, status_byte, 8'h00};
        end
    end

    assign pcpi_wait  = dp_start | stop_wait_r;
    assign pcpi_ready = (instr_valid & ~dp_start) | (stop_wait_r & dp_done);

    assign pcpi_wr = is_read & instr_valid;
    assign pcpi_rd = {24'b0, out_reg[(7 - stat_sel) * 8 +: 8]};

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

    ast_top_no_ready_while_waiting: assert property (
        @(posedge clk) disable iff (rst)
        (stop_wait_r && !dp_done) |-> !pcpi_ready
    ) else $error("[smacc_top] pcpi_ready asserted during STOP stall");

    ast_top_instr_valid_single_shot: assert property (
        @(posedge clk) disable iff (rst)
        (instr_valid & pcpi_valid) |=> (pcpi_valid |-> ~instr_valid)
    ) else $error("[smacc_top] instr_valid re-asserted within same pcpi_valid window");

`endif // SMACC_ASSERT

endmodule: smacc_top

`endif // SMACC_TOP_SV
