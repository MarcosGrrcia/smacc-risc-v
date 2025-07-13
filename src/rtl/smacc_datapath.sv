// smacc_datapath.sv: 5-stage pipeline that computes the derived statistics.
//
//   S1  snapshot accumulators, delta = max - min
//   S2  avg = sum / count, mean_sq = sum_of_squares / count
//   S3  avg_sq = avg * avg
//   S4  variance = mean_sq - avg_sq (floored at 0)
//   S5  stddev = isqrt(variance), results registered
//
// All three results are full 32-bit values; smacc_top gates them to 0
// outside ST_DONE.
//
// S1 captures on dp_start and S2-S4 free-run behind it; the valid bits only
// track where the STOP is. dp_done pulses when S5 is written, and smacc_top
// holds the CPU on pcpi_wait until then. Only one STOP is ever in flight.

`ifndef SMACC_DATAPATH_SV
`define SMACC_DATAPATH_SV

`include "smacc_isa_defs.sv"

module smacc_datapath (
    input  logic                clk,
    input  logic                rst,            // synchronous, active-high

    input  logic                dp_start,       // one-cycle pulse from smacc_ctrl

    input  logic [DATA_W-1:0]   min_out,
    input  logic [DATA_W-1:0]   max_out,
    input  logic [ACCUM_W-1:0]  count_out,
    input  logic [ACCUM_W-1:0]  sum_out,
    input  logic [ACCUM_W-1:0]  sum_of_sq_out,

    output logic [DATA_W-1:0]   dp_avg,
    output logic [DATA_W-1:0]   dp_stddev,
    output logic [DATA_W-1:0]   dp_delta,
    output logic                dp_done
);

    // 64-bit radicand -> 32-bit root, one bit per iteration. The variance of
    // 32-bit samples is below 2^62, so the root always fits.
    function automatic logic [DATA_W-1:0] isqrt64(input logic [ACCUM_W-1:0] x);
        logic [ACCUM_W-1:0] rem, root, b;
        integer             i;
        rem  = x;
        root = '0;
        b    = {2'b01, {(ACCUM_W-2){1'b0}}};
        for (i = 0; i < DATA_W; i = i + 1) begin
            if (rem >= (root | b)) begin
                rem  = rem - (root | b);
                root = (root >> 1) | b;
            end else begin
                root = root >> 1;
            end
            b = b >> 2;
        end
        isqrt64 = root[DATA_W-1:0];
    endfunction

    // S1
    logic                s1_v;
    logic [ACCUM_W-1:0]  s1_count, s1_sum, s1_sum_sq;
    logic [DATA_W-1:0]   s1_delta;
    // S2
    logic                s2_v;
    logic [DATA_W-1:0]   s2_avg;
    logic [ACCUM_W-1:0]  s2_mean_sq;
    logic [DATA_W-1:0]   s2_delta;
    // S3
    logic                s3_v;
    logic [ACCUM_W-1:0]  s3_avg_sq, s3_mean_sq;
    logic [DATA_W-1:0]   s3_avg, s3_delta;
    // S4
    logic                s4_v;
    logic [ACCUM_W-1:0]  s4_var;
    logic [DATA_W-1:0]   s4_avg, s4_delta;
    // S5 (results)
    logic                done_r;
    logic [DATA_W-1:0]   avg_r, stddev_r, delta_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_v   <= 1'b0;
            s2_v   <= 1'b0;
            s3_v   <= 1'b0;
            s4_v   <= 1'b0;
            done_r <= 1'b0;
        end else begin
            s1_v   <= dp_start;
            s2_v   <= s1_v;
            s3_v   <= s2_v;
            s4_v   <= s3_v;
            done_r <= s4_v;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_count  <= '0;
            s1_sum    <= '0;
            s1_sum_sq <= '0;
            s1_delta  <= '0;
        end else if (dp_start) begin
            s1_count  <= count_out;
            s1_sum    <= sum_out;
            s1_sum_sq <= sum_of_sq_out;
            s1_delta  <= max_out - min_out;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s2_avg     <= '0;
            s2_mean_sq <= '0;
            s2_delta   <= '0;
            s3_avg_sq  <= '0;
            s3_mean_sq <= '0;
            s3_avg     <= '0;
            s3_delta   <= '0;
            s4_var     <= '0;
            s4_avg     <= '0;
            s4_delta   <= '0;
        end else begin
            s2_avg     <= DATA_W'(s1_sum / s1_count);
            s2_mean_sq <= s1_sum_sq / s1_count;
            s2_delta   <= s1_delta;

            s3_avg_sq  <= {{(ACCUM_W-DATA_W){1'b0}}, s2_avg}
                        * {{(ACCUM_W-DATA_W){1'b0}}, s2_avg};
            s3_mean_sq <= s2_mean_sq;
            s3_avg     <= s2_avg;
            s3_delta   <= s2_delta;

            // mean_sq < avg_sq only after a sum_of_squares overflow
            s4_var     <= (s3_mean_sq >= s3_avg_sq) ? (s3_mean_sq - s3_avg_sq) : '0;
            s4_avg     <= s3_avg;
            s4_delta   <= s3_delta;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            avg_r    <= '0;
            stddev_r <= '0;
            delta_r  <= '0;
        end else if (s4_v) begin
            avg_r    <= s4_avg;
            stddev_r <= isqrt64(s4_var);
            delta_r  <= s4_delta;
        end
    end

    assign dp_avg    = avg_r;
    assign dp_stddev = stddev_r;
    assign dp_delta  = delta_r;
    assign dp_done   = done_r;

endmodule: smacc_datapath

`endif // SMACC_DATAPATH_SV
