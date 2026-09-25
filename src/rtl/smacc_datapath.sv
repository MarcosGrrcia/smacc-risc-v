// smacc_datapath.sv: finalization engine for the derived SMACC statistics.
//
// Started by a dp_start_final pulse from smacc_ctrl, this block snapshots the
// accumulators in smacc_mem and computes
//   avg    = sum / count
//   stddev = isqrt(sum_of_squares/count - avg^2)
//   delta  = max - min
// raising dp_done for one cycle once all three result registers are final.
// min, max and count are served straight from smacc_mem and never pass
// through here.
//
// The engine runs in the background while the CPU polls STATUS_DONE. One
// bit-serial divider handles both divides, and a shift-add squarer computes
// avg^2 during the second divide, so there's no multiplier or combinational
// divider in here. See docs/DATAPATH_DESIGN.md for the cycle budget.
//
// Results are held until the next run starts and are exposed by smacc_top
// only in ST_DONE, so partial values are never visible to software.

module smacc_datapath #(
    parameter int unsigned DATA_W  = 32,  // sample and result width
    parameter int unsigned ACCUM_W = 64   // accumulator width; must be 2*DATA_W
) (
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

    // The isqrt takes an ACCUM_W-bit radicand and produces a DATA_W-bit root,
    // which only works when the accumulators are exactly double the sample
    // width. Checked at elaboration so a width change fails loudly.
    initial begin
        if (ACCUM_W != 2 * DATA_W) begin
            $fatal(1, "smacc_datapath: ACCUM_W (%0d) must be 2*DATA_W (%0d)",
                   ACCUM_W, DATA_W);
        end
    end

    // Iteration counts: one quotient, root, or partial-product bit per cycle.
    localparam int unsigned DIV_ITERS  = ACCUM_W;
    localparam int unsigned SQRT_ITERS = DATA_W;
    localparam int unsigned MUL_ITERS  = DATA_W;

    localparam int unsigned STEP_W    = $clog2(DIV_ITERS);
    localparam int unsigned MUL_CNT_W = $clog2(MUL_ITERS);

    localparam logic [STEP_W-1:0]    DIV_LAST  = STEP_W'(DIV_ITERS - 1);
    localparam logic [STEP_W-1:0]    SQRT_LAST = STEP_W'(SQRT_ITERS - 1);
    localparam logic [MUL_CNT_W-1:0] MUL_LAST  = MUL_CNT_W'(MUL_ITERS - 1);

    // First isqrt trial bit: the highest even bit position, so that the root
    // bit it represents squares back into the top of the radicand.
    localparam logic [ACCUM_W-1:0] SQRT_B_INIT = ACCUM_W'(1) << (ACCUM_W - 2);

    typedef enum logic [2:0] {
        D_IDLE = 3'b000,
        D_DIV1 = 3'b001,  // avg      = sum / count
        D_DIV2 = 3'b010,  // mean_sq  = sum_of_squares / count
        D_VAR  = 3'b011,  // variance = mean_sq - avg^2 (floored at 0)
        D_SQRT = 3'b100   // stddev   = isqrt(variance)
    } dp_state_e;

    dp_state_e             dstate_r, dstate_next;
    logic [STEP_W-1:0]     step_r;  // divide: 0..DIV_ITERS-1, isqrt: 0..SQRT_ITERS-1

    // Shared restoring divider. div_shreg_r is loaded with the dividend and
    // shifts left one place per cycle: the dividend leaves through the MSB
    // into the partial remainder while the quotient enters at the LSB, so one
    // register covers both roles and holds the quotient when the run ends.
    logic [ACCUM_W-1:0]    div_shreg_r, div_rem_r, div_den_r;
    logic [ACCUM_W-1:0]    sum_sq_hold_r;  // dividend held back for the second divide
    logic [ACCUM_W-1:0]    mean_sq_r;

    // Bit-serial restoring isqrt: sq_b_r walks the trial bit down the root.
    logic [ACCUM_W-1:0]    sq_rem_r, sq_root_r, sq_b_r;

    // Bit-serial squarer for avg^2.
    logic [ACCUM_W-1:0]    avg_sq_r;
    logic [DATA_W-1:0]     mul_shreg_r;
    logic [MUL_CNT_W-1:0]  mul_cnt_r;
    logic                  mul_busy_r;

    logic [DATA_W-1:0]     avg_r, stddev_r, delta_r;
    logic                  done_r;

    logic div_last_step, sqrt_last_step;

    assign div_last_step  = (step_r == DIV_LAST);
    assign sqrt_last_step = (step_r == SQRT_LAST);

    // ---------------------------------------------------------------------
    // Divider step
    // ---------------------------------------------------------------------
    // The trial subtraction is one bit wider so its borrow-out doubles as the
    // rem >= den comparison. Since rem < den on every step (asserted below),
    // the shifted remainder always fits back in ACCUM_W bits.
    logic [ACCUM_W:0]      div_rem_shl, div_rem_sub;
    logic                  div_ge;
    logic [ACCUM_W-1:0]    div_rem_next, div_shreg_next;

    assign div_rem_shl    = {div_rem_r, div_shreg_r[ACCUM_W-1]};
    assign div_rem_sub    = div_rem_shl - {1'b0, div_den_r};
    assign div_ge         = ~div_rem_sub[ACCUM_W];
    assign div_rem_next   = div_ge ? div_rem_sub[ACCUM_W-1:0]
                                   : div_rem_shl[ACCUM_W-1:0];
    assign div_shreg_next = {div_shreg_r[ACCUM_W-2:0], div_ge};

    // The final quotient is used combinationally so the last iteration commits
    // in its own cycle instead of costing an extra one.
    //
    // sum/count fits DATA_W unless sum saturated upstream; that case already
    // raises STATUS_ERROR, so clamp rather than wrap (ISA_SPEC.md section 9).
    logic [DATA_W-1:0]     avg_next;

    assign avg_next = (|div_shreg_next[ACCUM_W-1:DATA_W])
                      ? {DATA_W{1'b1}}
                      : div_shreg_next[DATA_W-1:0];

    // ---------------------------------------------------------------------
    // isqrt step
    // ---------------------------------------------------------------------
    // Standard digit-by-digit integer sqrt. sq_root_r's set bits always stay
    // above sq_b_r (root shifts right by 1 per step, b by 2), so root + b can
    // be an OR instead of a 64-bit add.
    logic [ACCUM_W-1:0]    sq_try, sq_root_next;
    logic                  sq_ge;

    assign sq_try       = sq_root_r | sq_b_r;
    assign sq_ge        = (sq_rem_r >= sq_try);
    assign sq_root_next = sq_ge ? ((sq_root_r >> 1) | sq_b_r) : (sq_root_r >> 1);

    // ---------------------------------------------------------------------
    // Squarer step
    // ---------------------------------------------------------------------
    // MSB-first shift-add: acc <- 2*acc + (next avg bit ? avg : 0).
    logic [ACCUM_W-1:0]    avg_ext, avg_sq_next;

    assign avg_ext     = {{(ACCUM_W-DATA_W){1'b0}}, avg_r};
    assign avg_sq_next = (avg_sq_r << 1) + (mul_shreg_r[DATA_W-1] ? avg_ext : '0);

    // ---------------------------------------------------------------------
    // Sequencer
    // ---------------------------------------------------------------------
    // dp_abort overrides every transition; smacc_ctrl issues it when START
    // arrives mid-finalization (ISA_SPEC.md section 4.1).
    always_comb begin
        dstate_next = dstate_r;
        case (dstate_r)
            D_IDLE:  if (dp_start_final) dstate_next = D_DIV1;
            D_DIV1:  if (div_last_step)  dstate_next = D_DIV2;
            D_DIV2:  if (div_last_step)  dstate_next = D_VAR;
            D_VAR:                       dstate_next = D_SQRT;
            D_SQRT:  if (sqrt_last_step) dstate_next = D_IDLE;
            default:                     dstate_next = D_IDLE;  // unreachable encodings
        endcase
        if (dp_abort) begin
            dstate_next = D_IDLE;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            dstate_r      <= D_IDLE;
            step_r        <= '0;
            done_r        <= 1'b0;
            div_shreg_r   <= '0;
            div_rem_r     <= '0;
            div_den_r     <= '0;
            sum_sq_hold_r <= '0;
            mean_sq_r     <= '0;
            sq_rem_r      <= '0;
            sq_root_r     <= '0;
            sq_b_r        <= '0;
            avg_r         <= '0;
            stddev_r      <= '0;
            delta_r       <= '0;
        end else begin
            dstate_r <= dstate_next;
            done_r   <= (dstate_r == D_SQRT) & sqrt_last_step & ~dp_abort;

            // An abort only idles the sequencer. The working and result
            // registers are left as they are: smacc_top exposes results in
            // ST_DONE alone, which an aborted run never reaches.
            if (~dp_abort) begin
                case (dstate_r)
                    D_IDLE: begin
                        if (dp_start_final) begin
                            // smacc_ctrl finalizes only out of ST_ACCUMULATE,
                            // so count >= 1 and min <= max here; the clamp
                            // below is defensive.
                            delta_r       <= (max_out >= min_out) ? (max_out - min_out) : '0;
                            div_den_r     <= count_out;
                            div_shreg_r   <= sum_out;
                            div_rem_r     <= '0;
                            sum_sq_hold_r <= sum_of_sq_out;
                            step_r        <= '0;
                        end
                    end

                    // Both divides run the same step; only what happens on the
                    // final iteration differs.
                    D_DIV1, D_DIV2: begin
                        if (div_last_step) begin
                            step_r <= '0;
                            if (dstate_r == D_DIV1) begin
                                avg_r       <= avg_next;
                                div_shreg_r <= sum_sq_hold_r;
                                div_rem_r   <= '0;
                            end else begin
                                mean_sq_r   <= div_shreg_next;
                            end
                        end else begin
                            div_rem_r   <= div_rem_next;
                            div_shreg_r <= div_shreg_next;
                            step_r      <= step_r + STEP_W'(1);
                        end
                    end

                    D_VAR: begin
                        // mean_sq < avg^2 only after a sum_of_squares overflow
                        // upstream, which already raises STATUS_ERROR.
                        sq_rem_r  <= (mean_sq_r >= avg_sq_r) ? (mean_sq_r - avg_sq_r) : '0;
                        sq_root_r <= '0;
                        sq_b_r    <= SQRT_B_INIT;
                        step_r    <= '0;
                    end

                    D_SQRT: begin
                        if (sqrt_last_step) begin
                            stddev_r  <= sq_root_next[DATA_W-1:0];
                        end else begin
                            sq_rem_r  <= sq_ge ? (sq_rem_r - sq_try) : sq_rem_r;
                            sq_root_r <= sq_root_next;
                            sq_b_r    <= sq_b_r >> 2;
                            step_r    <= step_r + STEP_W'(1);
                        end
                    end

                    default: ;  // unreachable; dstate_next forces D_IDLE
                endcase
            end
        end
    end

    // ---------------------------------------------------------------------
    // avg^2 squarer
    // ---------------------------------------------------------------------
    // avg is known as soon as DIV1 finishes, so square it with a shift-add
    // loop while DIV2 runs. It takes MUL_ITERS (32) cycles, so it's done long
    // before D_VAR needs it.
    logic mul_start;

    assign mul_start = (dstate_r == D_DIV1) & div_last_step;

    always_ff @(posedge clk) begin
        if (rst) begin
            avg_sq_r    <= '0;
            mul_shreg_r <= '0;
            mul_cnt_r   <= '0;
            mul_busy_r  <= 1'b0;
        end else if (dp_abort) begin
            mul_busy_r  <= 1'b0;
        end else if (mul_start) begin
            avg_sq_r    <= '0;
            mul_shreg_r <= avg_next;  // the same value being latched into avg_r
            mul_cnt_r   <= '0;
            mul_busy_r  <= 1'b1;
        end else if (mul_busy_r) begin
            avg_sq_r    <= avg_sq_next;
            mul_shreg_r <= {mul_shreg_r[DATA_W-2:0], 1'b0};
            mul_cnt_r   <= mul_cnt_r + MUL_CNT_W'(1);
            if (mul_cnt_r == MUL_LAST) begin
                mul_busy_r <= 1'b0;
            end
        end
    end

    assign dp_avg    = avg_r;
    assign dp_stddev = stddev_r;
    assign dp_delta  = delta_r;
    assign dp_done   = done_r;

    // ---------------------------------------------------------------------
    // Assertions
    // ---------------------------------------------------------------------
`ifdef SMACC_ASSERT

    ast_dp_done_single_cycle: assert property (
        @(posedge clk) disable iff (rst)
        dp_done |=> !dp_done
    ) else $error("[smacc_datapath] dp_done held for more than one cycle");

    ast_dp_abort_flushes: assert property (
        @(posedge clk) disable iff (rst)
        dp_abort |=> (dstate_r == D_IDLE && !dp_done && !mul_busy_r)
    ) else $error("[smacc_datapath] engine not idled after dp_abort");

    ast_dp_start_nonzero_count: assert property (
        @(posedge clk) disable iff (rst)
        (dp_start_final && dstate_r == D_IDLE) |-> (count_out != '0)
    ) else $error("[smacc_datapath] finalization started with count == 0");

    ast_dp_rem_lt_den: assert property (
        @(posedge clk) disable iff (rst)
        (dstate_r == D_DIV1 || dstate_r == D_DIV2) |-> (div_rem_r < div_den_r)
    ) else $error("[smacc_datapath] divider invariant rem < den violated");

    // The OR in sq_try is only an exact add while these never overlap.
    ast_dp_sqrt_bits_disjoint: assert property (
        @(posedge clk) disable iff (rst)
        (dstate_r == D_SQRT) |-> ((sq_root_r & sq_b_r) == '0)
    ) else $error("[smacc_datapath] isqrt root and trial bit overlap");

    ast_dp_mul_settled: assert property (
        @(posedge clk) disable iff (rst)
        (dstate_r == D_VAR) |-> !mul_busy_r
    ) else $error("[smacc_datapath] avg^2 still in flight at D_VAR");

`endif // SMACC_ASSERT

endmodule: smacc_datapath
