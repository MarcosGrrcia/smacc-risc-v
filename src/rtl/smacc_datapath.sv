// smacc_datapath.sv - computes avg / stddev / delta after STOP
//
// 5-stage pipeline:
//   S1  latch sum, sum_sq, count; delta = max - min
//   S2  avg = sum / count, mean_sq = sum_sq / count
//   S3  avg_sq = avg * avg
//   S4  var = mean_sq - avg_sq (clamped to 0)
//   S5  stddev = isqrt(var), latch results
//
// dp_done is a 1-cycle pulse when S5 is written. The CPU is stalled the
// whole time so the mem registers can't change underneath us.

`ifndef SMACC_DATAPATH_SV
`define SMACC_DATAPATH_SV

module smacc_datapath (
    input  wire        clk,
    input  wire        rst,
    input  wire        dp_start,
    input  wire        dp_clear,       // START clears the old results
    input  wire [31:0] min_out,
    input  wire [31:0] max_out,
    input  wire [63:0] count_out,
    input  wire [63:0] sum_out,
    input  wire [63:0] sum_of_sq_out,
    output wire [31:0] dp_avg,         // top saturates this to 8 bits
    output wire [7:0]  dp_stddev,
    output wire [7:0]  dp_delta,
    output wire        dp_done
);

    // integer sqrt, one result bit per iteration. 8-bit samples means the
    // variance is < 2^16, so 32 bits in / 16 bits out is plenty.
    function [15:0] isqrt32;
        input [31:0] x;
        reg   [31:0] rem, root, b;
        integer i;
        begin
            rem  = x;
            root = 0;
            b    = 32'h4000_0000;
            for (i = 0; i < 16; i = i + 1) begin
                if (rem >= (root | b)) begin
                    rem  = rem - (root | b);
                    root = (root >> 1) | b;
                end else begin
                    root = root >> 1;
                end
                b = b >> 2;
            end
            isqrt32 = root[15:0];
        end
    endfunction

    function [7:0] sat8;
        input [31:0] x;
        sat8 = (|x[31:8]) ? 8'hFF : x[7:0];
    endfunction

    reg        s1_v, s2_v, s3_v, s4_v, done_r;

    reg [63:0] s1_count, s1_sum, s1_sum_sq;
    reg [31:0] s1_delta;

    reg [31:0] s2_avg;
    reg [63:0] s2_mean_sq;
    reg [31:0] s2_delta;

    reg [63:0] s3_avg_sq, s3_mean_sq;
    reg [31:0] s3_avg, s3_delta;

    reg [31:0] s4_var, s4_avg, s4_delta;

    reg [31:0] avg_r;
    reg [7:0]  stddev_r, delta_r;

    // negative only if something upstream went wrong; clamp to 0
    wire [63:0] s3_diff = s3_mean_sq - s3_avg_sq;

    always @(posedge clk) begin
        if (rst) begin
            s1_v   <= 0;
            s2_v   <= 0;
            s3_v   <= 0;
            s4_v   <= 0;
            done_r <= 0;
        end else begin
            s1_v   <= dp_start;
            s2_v   <= s1_v;
            s3_v   <= s2_v;
            s4_v   <= s3_v;
            done_r <= s4_v;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            s1_count  <= 0;
            s1_sum    <= 0;
            s1_sum_sq <= 0;
            s1_delta  <= 0;
        end else if (dp_start) begin
            s1_count  <= count_out;
            s1_sum    <= sum_out;
            s1_sum_sq <= sum_of_sq_out;
            s1_delta  <= max_out - min_out;
        end
    end

    // S2-S4 just run every cycle, the valid bits say where the STOP is
    always @(posedge clk) begin
        if (rst) begin
            s2_avg     <= 0;
            s2_mean_sq <= 0;
            s2_delta   <= 0;
            s3_avg_sq  <= 0;
            s3_mean_sq <= 0;
            s3_avg     <= 0;
            s3_delta   <= 0;
            s4_var     <= 0;
            s4_avg     <= 0;
            s4_delta   <= 0;
        end else begin
            s2_avg     <= s1_sum / s1_count;
            s2_mean_sq <= s1_sum_sq / s1_count;
            s2_delta   <= s1_delta;

            s3_avg_sq  <= {32'b0, s2_avg} * {32'b0, s2_avg};
            s3_mean_sq <= s2_mean_sq;
            s3_avg     <= s2_avg;
            s3_delta   <= s2_delta;

            s4_var     <= s3_diff[63] ? 32'd0 : s3_diff[31:0];
            s4_avg     <= s3_avg;
            s4_delta   <= s3_delta;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            avg_r    <= 0;
            stddev_r <= 0;
            delta_r  <= 0;
        end else if (dp_clear) begin
            avg_r    <= 0;
            stddev_r <= 0;
            delta_r  <= 0;
        end else if (s4_v) begin
            avg_r    <= s4_avg;
            stddev_r <= isqrt32(s4_var);   // < 128 for 8-bit data
            delta_r  <= sat8(s4_delta);
        end
    end

    assign dp_avg    = avg_r;
    assign dp_stddev = stddev_r;
    assign dp_delta  = delta_r;
    assign dp_done   = done_r;

endmodule

`endif
