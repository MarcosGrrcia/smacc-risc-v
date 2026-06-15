// smacc_mem.sv: Statistics register file for SMACC.
// Stores min/max/count/sum/sum_of_squares; all updated in parallel on DATA.
// READ serves min/max/count directly from here (via smacc_top); sum and
// sum_of_squares feed the smacc_datapath finalization engine.

`ifndef SMACC_MEM_SV
`define SMACC_MEM_SV

`include "smacc_isa_defs.sv"

module smacc_mem (
    input  logic                   clk,
    input  logic                   rst,           // synchronous, active-high

    input  logic                   clear,         // START: synchronous clear
    input  logic                   write_enable,  // DATA: accumulate one sample
    input  logic [DATA_W-1:0]      data_in,

    // Registered outputs: these are the accumulator registers themselves.
    output logic [DATA_W-1:0]      min_out,
    output logic [DATA_W-1:0]      max_out,
    output logic [ACCUM_W-1:0]     count_out,
    output logic [ACCUM_W-1:0]     sum_out,
    output logic [ACCUM_W-1:0]     sum_of_sq_out,

    output logic                   overflow       // sticky; cleared by rst/clear
);

    localparam logic [ACCUM_W-1:0] ACCUM_MAX = {ACCUM_W{1'b1}};

    logic [ACCUM_W-1:0] data_in_ext;
    assign data_in_ext = {{(ACCUM_W-DATA_W){1'b0}}, data_in};

    // 32x32 -> 64 square. Operand gated with write_enable (operand
    // isolation) so the multiplier only switches on real DATA, not on every
    // CPU instruction that drives pcpi_rs1.
    logic [DATA_W-1:0]  sq_in;
    logic [ACCUM_W-1:0] sq;
    assign sq_in = write_enable ? data_in : '0;
    assign sq    = {{(ACCUM_W-DATA_W){1'b0}}, sq_in} *
                   {{(ACCUM_W-DATA_W){1'b0}}, sq_in};

    // Saturating accumulate: the widened add's carry-out is the overflow
    // test, so no separate compare is needed.
    logic [ACCUM_W:0] sum_nx, sum_sq_nx;
    assign sum_nx    = {1'b0, sum_out}       + {1'b0, data_in_ext};
    assign sum_sq_nx = {1'b0, sum_of_sq_out} + {1'b0, sq};

    logic sum_ovf, sq_ovf;
    assign sum_ovf = sum_nx[ACCUM_W];
    assign sq_ovf  = sum_sq_nx[ACCUM_W];

    // rst and clear are both synchronous with identical effect, so they
    // share one branch. Reset is synchronous design-wide (see smacc_ctrl).
    always_ff @(posedge clk) begin
        if (rst || clear) begin
            min_out       <= {DATA_W{1'b1}};  // 0xFFFF_FFFF (ISA_SPEC.md section 4.1)
            max_out       <= '0;
            count_out     <= '0;
            sum_out       <= '0;
            sum_of_sq_out <= '0;
            overflow      <= 1'b0;
        end else if (write_enable) begin
            if (data_in < min_out) begin
                min_out <= data_in;
            end
            if (data_in > max_out) begin
                max_out <= data_in;
            end
            count_out     <= count_out + 1;
            sum_out       <= sum_ovf ? ACCUM_MAX : sum_nx[ACCUM_W-1:0];
            sum_of_sq_out <= sq_ovf  ? ACCUM_MAX : sum_sq_nx[ACCUM_W-1:0];
            if (sum_ovf || sq_ovf) begin
                overflow <= 1'b1;
            end
        end
    end

    // Assertions
    `ifdef SMACC_ASSERT

    ast_clear_resets_min: assert property (
        @(posedge clk) disable iff (rst)
        clear |=> (min_out == {DATA_W{1'b1}})
    ) else $error("smacc_mem: min_out not 0xFFFFFFFF after clear");

    ast_clear_resets_accumulators: assert property (
        @(posedge clk) disable iff (rst)
        clear |=> (max_out == '0 && count_out == '0 && sum_out == '0 &&
                   sum_of_sq_out == '0 && overflow == 1'b0)
    ) else $error("smacc_mem: accumulators not zeroed after clear");

    ast_count_increments: assert property (
        @(posedge clk) disable iff (rst || clear)
        (write_enable && !clear) |=> (count_out == $past(count_out) + 1)
    ) else $error("smacc_mem: count did not increment on write_enable");

    ast_overflow_sticky: assert property (
        @(posedge clk) disable iff (rst)
        (overflow && !clear) |=> overflow
    ) else $error("smacc_mem: overflow flag cleared without rst or clear");

    ast_no_simultaneous_clear_write: assert property (
        @(posedge clk) disable iff (rst)
        !(clear && write_enable)
    ) else $warning("smacc_mem: clear and write_enable both asserted; DATA write discarded");

    `endif // SMACC_ASSERT

endmodule: smacc_mem

`endif // SMACC_MEM_SV
