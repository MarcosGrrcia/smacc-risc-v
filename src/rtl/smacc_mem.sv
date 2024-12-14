// smacc_mem.sv - running statistics registers
// min/max/count/sum/sum_of_squares, all updated in the same cycle on DATA

`ifndef SMACC_MEM_SV
`define SMACC_MEM_SV

module smacc_mem (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,          // START
    input  wire        write_enable,   // DATA
    input  wire [31:0] data_in,
    output reg  [31:0] min_out,
    output reg  [31:0] max_out,
    output reg  [63:0] count_out,
    output reg  [63:0] sum_out,
    output reg  [63:0] sum_of_sq_out,
    output reg         overflow
);

    wire [63:0] sq = {32'b0, data_in} * {32'b0, data_in};

    // sum_of_squares can overflow with only two samples near 2^32, so it
    // saturates and raises the error flag. sum would need ~2^32 samples,
    // so it isn't checked.
    wire sq_ovf = sum_of_sq_out > (64'hFFFF_FFFF_FFFF_FFFF - sq);

    always @(posedge clk) begin
        if (rst || clear) begin
            min_out       <= 32'hFFFF_FFFF;
            max_out       <= 0;
            count_out     <= 0;
            sum_out       <= 0;
            sum_of_sq_out <= 0;
            overflow      <= 0;
        end else if (write_enable) begin
            if (data_in < min_out) min_out <= data_in;
            if (data_in > max_out) max_out <= data_in;
            count_out     <= count_out + 1;
            sum_out       <= sum_out + data_in;
            sum_of_sq_out <= sq_ovf ? 64'hFFFF_FFFF_FFFF_FFFF : sum_of_sq_out + sq;
            if (sq_ovf) overflow <= 1;
        end
    end

endmodule

`endif
