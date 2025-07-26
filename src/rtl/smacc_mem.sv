// smacc_mem.sv: Statistics register file for SMACC.
// Stores min/max/count/sum/sum_of_squares; all updated in parallel on DATA.

`ifndef SMACC_MEM_SV
`define SMACC_MEM_SV

`include "smacc_isa_defs.sv"

module smacc_mem (
    input  logic                   clk,
    input  logic                   rst,           // synchronous, active-high

    input  logic                   clear,         // START: synchronous clear
    input  logic                   write_enable,  // DATA: accumulate one sample
    input  logic [DATA_W-1:0]      data_in,

    output logic [DATA_W-1:0]      min_out,
    output logic [DATA_W-1:0]      max_out,
    output logic [ACCUM_W-1:0]     count_out,
    output logic [ACCUM_W-1:0]     sum_out,
    output logic [ACCUM_W-1:0]     sum_of_sq_out,

    output logic                   overflow       // sticky; cleared by rst/clear
);

    localparam logic [ACCUM_W-1:0] ACCUM_MAX = {ACCUM_W{1'b1}};

    logic [ACCUM_W-1:0] data_in_ext;
    logic [ACCUM_W-1:0] sq;
    assign data_in_ext = {{(ACCUM_W-DATA_W){1'b0}}, data_in};
    assign sq          = data_in_ext * data_in_ext;

    // Saturate instead of wrapping: check headroom before each add.
    logic sum_ovf, sq_ovf;
    assign sum_ovf = (sum_out       > (ACCUM_MAX - data_in_ext));
    assign sq_ovf  = (sum_of_sq_out > (ACCUM_MAX - sq));

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            min_out       <= {DATA_W{1'b1}};
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
            sum_out       <= sum_ovf ? ACCUM_MAX : (sum_out + data_in_ext);
            sum_of_sq_out <= sq_ovf  ? ACCUM_MAX : (sum_of_sq_out + sq);
            if (sum_ovf || sq_ovf) begin
                overflow <= 1'b1;
            end
        end
    end

endmodule: smacc_mem

`endif // SMACC_MEM_SV
