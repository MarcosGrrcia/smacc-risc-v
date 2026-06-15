// smacc_datapath.sv: Sequential statistics finalization engine for SMACC.
//
// On STOP, computes the derived statistics (min/max/count come straight
// from smacc_mem instead):
//   avg    = sum / count                  (restoring divide, 64 cycles)
//   stddev = isqrt(sum_sq/count - avg^2)  (second divide + 32-cycle isqrt)
//   delta  = max - min                    (subtract at load)
//
// Fixed 162-cycle latency: 1 load + 64 + 64 divide + 1 variance + 32 isqrt.
// One divider is shared across both divides, and avg^2 is squared
// bit-serially during the second divide (which doesn't read avg), so no
// multiplier is needed here. The CPU is not stalled; it polls STATUS_DONE
// (ISA_SPEC.md section 7.3).
//
// Results hold after dp_done and are exposed by smacc_top only in ST_DONE,
// so partial values are never visible. All three fit 32 bits; avg saturates
// at 2^32-1 on the sum-overflow error path rather than wrapping.

`ifndef SMACC_DATAPATH_SV
`define SMACC_DATAPATH_SV

`include "smacc_isa_defs.sv"

module smacc_datapath (
    input  logic                clk,
    input  logic                rst,            // synchronous, active-high

    input  logic                dp_start_final, // one-cycle pulse: snapshot mem, start engine
    input  logic                dp_abort,       // one-cycle pulse: cancel in-flight run

    input  logic [DATA_W-1:0]   min_out,
    input  logic [DATA_W-1:0]   max_out,
    input  logic [ACCUM_W-1:0]  count_out,
    input  logic [ACCUM_W-1:0]  sum_out,
    input  logic [ACCUM_W-1:0]  sum_of_sq_out,

    output logic [DATA_W-1:0]   dp_avg,
    output logic [DATA_W-1:0]   dp_stddev,
    output logic [DATA_W-1:0]   dp_delta,
    output logic                dp_done         // one-cycle pulse: results committed
);

    typedef enum logic [2:0] {
        D_IDLE = 3'd0,
        D_DIV1 = 3'd1,  // avg     = sum / count
        D_DIV2 = 3'd2,  // mean_sq = sum_of_squares / count
        D_VAR  = 3'd3,  // variance = mean_sq - avg^2 (floored to 0)
        D_SQRT = 3'd4   // stddev  = isqrt(variance)
    } dp_fsm_e;

    dp_fsm_e            dstate_r;
    logic [5:0]         step_r;      // divide: 0..63, isqrt: 0..31

    // Shared restoring divider. Invariant div_rem_r < div_den_r keeps the
    // partial remainder within ACCUM_W bits after each subtract.
    logic [ACCUM_W-1:0] div_quo_r, div_rem_r, div_den_r;
    logic [ACCUM_W-1:0] f_sum_sq_r;  // dividend for the second divide
    logic [ACCUM_W-1:0] mean_sq_r;

    // Bit-serial restoring isqrt, one result bit per cycle. sq_root_r's set
    // bits stay above sq_b_r, so (sq_root_r | sq_b_r) == sq_root_r + sq_b_r.
    logic [ACCUM_W-1:0] sq_rem_r, sq_root_r, sq_b_r;

    logic [ACCUM_W-1:0] avg_sq_r;   // bit-serial avg^2, built during D_DIV2
    logic [DATA_W-1:0]  avg_r, stddev_r, delta_r;
    logic               done_r;

    // Divider step (combinational, so the last iteration commits same-cycle).
    logic [ACCUM_W:0]   div_shift;
    logic               div_ge;
    logic [ACCUM_W-1:0] div_rem_nx, div_quo_nx;

    assign div_shift  = {div_rem_r, div_quo_r[ACCUM_W-1]};
    assign div_ge     = (div_shift >= {1'b0, div_den_r});
    assign div_rem_nx = div_ge ? (div_shift[ACCUM_W-1:0] - div_den_r)
                               : div_shift[ACCUM_W-1:0];
    assign div_quo_nx = {div_quo_r[ACCUM_W-2:0], div_ge};

    // isqrt step
    logic [ACCUM_W-1:0] sq_try;
    logic               sq_ge;
    logic [ACCUM_W-1:0] sq_root_nx;

    assign sq_try     = sq_root_r | sq_b_r;
    assign sq_ge      = (sq_rem_r >= sq_try);
    assign sq_root_nx = sq_ge ? ((sq_root_r >> 1) | sq_b_r) : (sq_root_r >> 1);

    // Squaring step, MSB-first: acc <- 2*acc + (avg[31-k] ? avg : 0).
    // One 64-bit adder in place of a 32x32 multiplier.
    logic               mul_bit;
    logic [ACCUM_W-1:0] mul_nx;

    assign mul_bit = avg_r[5'd31 - step_r[4:0]];
    assign mul_nx  = (avg_sq_r << 1)
                   + (mul_bit ? {{(ACCUM_W-DATA_W){1'b0}}, avg_r} : '0);

    always_ff @(posedge clk) begin
        if (rst) begin
            dstate_r   <= D_IDLE;
            step_r     <= '0;
            done_r     <= 1'b0;
            div_quo_r  <= '0;
            div_rem_r  <= '0;
            div_den_r  <= '0;
            f_sum_sq_r <= '0;
            mean_sq_r  <= '0;
            sq_rem_r   <= '0;
            sq_root_r  <= '0;
            sq_b_r     <= '0;
            avg_sq_r   <= '0;
            avg_r      <= '0;
            stddev_r   <= '0;
            delta_r    <= '0;
        end else if (dp_abort) begin
            // Only idle the engine; stale data regs are safe because
            // smacc_top exposes results in ST_DONE, unreachable after abort.
            dstate_r <= D_IDLE;
            done_r   <= 1'b0;
        end else begin
            done_r <= 1'b0;  // dp_done is a one-cycle pulse

            case (dstate_r)
                D_IDLE: begin
                    if (dp_start_final) begin
                        // ctrl only finalizes from ST_ACCUMULATE, so count >= 1
                        // and min <= max; the delta guard is defensive only.
                        delta_r    <= (max_out >= min_out) ? (max_out - min_out) : '0;
                        div_den_r  <= count_out;
                        div_quo_r  <= sum_out;
                        div_rem_r  <= '0;
                        f_sum_sq_r <= sum_of_sq_out;
                        step_r     <= '0;
                        dstate_r   <= D_DIV1;
                    end
                end

                // Both divides share the same per-cycle step; only the
                // commit on the final (64th) iteration differs.
                D_DIV1, D_DIV2: begin
                    if (step_r == 6'd63) begin
                        step_r <= '0;
                        if (dstate_r == D_DIV1) begin
                            // avg fits 32 bits unless sum saturated; clamp then.
                            avg_r     <= (|div_quo_nx[ACCUM_W-1:DATA_W])
                                         ? {DATA_W{1'b1}}
                                         : div_quo_nx[DATA_W-1:0];
                            avg_sq_r  <= '0;  // arm the overlapped squarer
                            div_quo_r <= f_sum_sq_r;
                            div_rem_r <= '0;
                            dstate_r  <= D_DIV2;
                        end else begin
                            mean_sq_r <= div_quo_nx;
                            dstate_r  <= D_VAR;
                        end
                    end else begin
                        div_rem_r <= div_rem_nx;
                        div_quo_r <= div_quo_nx;
                        step_r    <= step_r + 6'd1;
                    end

                    // Build avg^2 in parallel during DIV2's first 32 cycles.
                    if (dstate_r == D_DIV2 && step_r < 6'd32) begin
                        avg_sq_r <= mul_nx;
                    end
                end

                D_VAR: begin
                    // Floor variance at 0 (mean_sq < avg^2 only after a
                    // sum_of_squares overflow upstream).
                    sq_rem_r  <= (mean_sq_r >= avg_sq_r) ? (mean_sq_r - avg_sq_r) : '0;
                    sq_root_r <= '0;
                    sq_b_r    <= {2'b01, {(ACCUM_W-2){1'b0}}};  // 1 << 62
                    step_r    <= '0;
                    dstate_r  <= D_SQRT;
                end

                D_SQRT: begin
                    if (step_r == 6'd31) begin
                        stddev_r <= sq_root_nx[DATA_W-1:0];
                        done_r   <= 1'b1;
                        dstate_r <= D_IDLE;
                    end else begin
                        sq_rem_r  <= sq_ge ? (sq_rem_r - sq_try) : sq_rem_r;
                        sq_root_r <= sq_root_nx;
                        sq_b_r    <= sq_b_r >> 2;
                        step_r    <= step_r + 6'd1;
                    end
                end

                default: begin
                    dstate_r <= D_IDLE;
                end
            endcase
        end
    end

    assign dp_avg    = avg_r;
    assign dp_stddev = stddev_r;
    assign dp_delta  = delta_r;
    assign dp_done   = done_r;

    // -------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------
`ifdef SMACC_ASSERT

    ast_dp_min_le_max: assert property (
        @(posedge clk) disable iff (rst)
        (count_out > '0) |-> (min_out <= max_out)
    ) else $error("[smacc_datapath] min_out > max_out while count_out > 0");

    ast_dp_done_single_cycle: assert property (
        @(posedge clk) disable iff (rst)
        dp_done |=> !dp_done
    ) else $error("[smacc_datapath] dp_done held for more than one cycle");

    ast_dp_abort_flushes: assert property (
        @(posedge clk) disable iff (rst)
        dp_abort |=> (dstate_r == D_IDLE && !dp_done)
    ) else $error("[smacc_datapath] engine not idled after dp_abort");

    ast_dp_start_nonzero_count: assert property (
        @(posedge clk) disable iff (rst)
        (dp_start_final && dstate_r == D_IDLE) |-> (count_out != '0)
    ) else $error("[smacc_datapath] finalization started with count == 0");

    ast_dp_rem_lt_den: assert property (
        @(posedge clk) disable iff (rst)
        (dstate_r == D_DIV1 || dstate_r == D_DIV2) |-> (div_rem_r < div_den_r)
    ) else $error("[smacc_datapath] divider invariant rem < den violated");

`endif // SMACC_ASSERT

endmodule: smacc_datapath

`endif // SMACC_DATAPATH_SV
