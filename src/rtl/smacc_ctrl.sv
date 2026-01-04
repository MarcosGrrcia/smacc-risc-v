// smacc_ctrl.sv: SMACC FSM, status flags, and error tracking.
//
// Holds no statistics of its own (those live in smacc_mem and
// smacc_datapath); it sequences the run and raises results_valid, which
// gates the derived stats so partial values are never read out.
// insn_valid is a single-cycle strobe (enforced by smacc_top).

`ifndef SMACC_CTRL_SV
`define SMACC_CTRL_SV

`include "smacc_isa_defs.sv"

module smacc_ctrl (
    input  logic       clk,
    input  logic       rst,            // synchronous, active-high

    // funct3[1:0]; see smacc_flavor_e in smacc_isa_defs.sv
    input  logic [1:0] flavor,
    input  logic       insn_valid,     // single-cycle strobe

    output logic       dp_start_final, // one-cycle pulse: start finalization engine
    output logic       dp_abort,       // one-cycle pulse: cancel in-flight finalization

    output logic       mem_clear,
    output logic       mem_we_data,

    input  logic       dp_done,        // one-cycle pulse from smacc_datapath
    input  logic       mem_overflow,   // sticky overflow flag from smacc_mem

    // Status byte (ISA_SPEC.md section 5): READY/BUSY/DONE from the FSM, ERROR OR'd in
    // independent of state. Combinational; READ returns it zero-extended.
    output logic [7:0] status_byte,
    output logic       results_valid   // high in ST_DONE; gates avg/stddev/delta
);

    smacc_state_e state_r, state_next;
    logic         err_sticky_r;  // STATUS_ERROR latch; cleared only by START

    logic is_start, is_data, is_stop;
    logic data_accepted;
    logic set_error;

    logic [7:0] status_flags;

    assign is_start = insn_valid & (flavor == FLV_START);
    assign is_data  = insn_valid & (flavor == FLV_DATA);
    assign is_stop  = insn_valid & (flavor == FLV_STOP);

    // ISA_SPEC.md section 4.2: DATA is dropped silently outside READY/ACCUMULATE.
    assign data_accepted = is_data & ((state_r == ST_READY) | (state_r == ST_ACCUMULATE));

    // ISA_SPEC.md section 9 errors: overflow, DATA with no active run, or
    // STOP with no active run.
    assign set_error = mem_overflow
                     | (is_data & ~data_accepted)
                     | (is_stop & (state_r != ST_ACCUMULATE));

    // START re-arms from any state (ISA_SPEC.md section 4.1); the rest are
    // state-specific.
    always_comb begin
        state_next = state_r;
        if (is_start) begin
            state_next = ST_READY;
        end else begin
            case (state_r)
                ST_READY:         if (is_data) state_next = ST_ACCUMULATE;
                ST_ACCUMULATE:    if (is_stop) state_next = ST_FINALIZING;
                ST_FINALIZING:    if (dp_done) state_next = ST_DONE;
                ST_IDLE, ST_DONE: ;  // hold; only START leaves these states
                default:          state_next = ST_IDLE;  // unreachable encodings
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_r      <= ST_IDLE;
            err_sticky_r <= 1'b0;
        end else begin
            state_r <= state_next;
            if (is_start) begin
                err_sticky_r <= 1'b0;  // ISA_SPEC.md section 4.1: START clears STATUS_ERROR
            end else if (set_error) begin
                err_sticky_r <= 1'b1;
            end
        end
    end

    assign dp_start_final = is_stop  & (state_r == ST_ACCUMULATE);
    assign dp_abort       = is_start & (state_r == ST_FINALIZING);
    assign mem_clear      = is_start;
    assign mem_we_data    = data_accepted;

    always_comb begin
        case (state_r)
            ST_READY, ST_ACCUMULATE: status_flags = STATUS_READY_MASK;
            ST_FINALIZING:           status_flags = STATUS_BUSY_MASK;
            ST_DONE:                 status_flags = STATUS_DONE_MASK;
            default:                 status_flags = 8'h00;
        endcase
    end

    // OR in set_error so an error shows the same cycle, before it latches.
    assign status_byte   = status_flags
                         | ((err_sticky_r | set_error) ? STATUS_ERROR_MASK : 8'h00);
    assign results_valid = (state_r == ST_DONE);

    // -------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------
`ifdef SMACC_ASSERT

    ast_start_to_ready: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_START) |=> (state_r == ST_READY)
    ) else $error("[smacc_ctrl] START must transition to ST_READY");

    ast_data_ready_to_accum: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_DATA && state_r == ST_READY) |=> (state_r == ST_ACCUMULATE)
    ) else $error("[smacc_ctrl] DATA in ST_READY must move to ST_ACCUMULATE");

    ast_data_stays_accum: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_DATA && state_r == ST_ACCUMULATE)
        |=> (state_r == ST_ACCUMULATE)
    ) else $error("[smacc_ctrl] DATA in ST_ACCUMULATE must remain in ST_ACCUMULATE");

    ast_stop_to_finalizing: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_STOP && state_r == ST_ACCUMULATE)
        |=> (state_r == ST_FINALIZING)
    ) else $error("[smacc_ctrl] STOP in ST_ACCUMULATE must move to ST_FINALIZING");

    ast_finalizing_to_done: assert property (
        @(posedge clk) disable iff (rst)
        (dp_done && state_r == ST_FINALIZING && !(insn_valid && flavor == FLV_START))
        |=> (state_r == ST_DONE)
    ) else $error("[smacc_ctrl] dp_done in ST_FINALIZING must move to ST_DONE");

    ast_finalizing_stable: assert property (
        @(posedge clk) disable iff (rst)
        (state_r == ST_FINALIZING && !dp_done && !(insn_valid && flavor == FLV_START))
        |=> (state_r == ST_FINALIZING)
    ) else $error("[smacc_ctrl] ST_FINALIZING must hold until dp_done or START");

`ifndef VERILATOR  // Verilator (as of 5.0) lacks ##N / ##[M:N] sequence support
    ast_idle_after_rst: assert property (
        @(posedge clk)
        $rose(rst) |-> ##1 (state_r == ST_IDLE)
    ) else $error("[smacc_ctrl] State must be ST_IDLE the cycle after rst rises");
`endif

    ast_data_invalid_sets_error: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_DATA &&
            (state_r == ST_IDLE || state_r == ST_FINALIZING || state_r == ST_DONE))
        |=> ((status_byte & STATUS_ERROR_MASK) != 8'h00)
    ) else $error("[smacc_ctrl] Illegal DATA must set STATUS_ERROR");

    ast_stop_invalid_sets_error: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_STOP && state_r != ST_ACCUMULATE)
        |=> ((status_byte & STATUS_ERROR_MASK) != 8'h00)
    ) else $error("[smacc_ctrl] Illegal STOP must set STATUS_ERROR");

    ast_error_sticky: assert property (
        @(posedge clk) disable iff (rst)
        (((status_byte & STATUS_ERROR_MASK) != 8'h00) && !(insn_valid && flavor == FLV_START))
        |=> ((status_byte & STATUS_ERROR_MASK) != 8'h00)
    ) else $error("[smacc_ctrl] STATUS_ERROR must remain set until START");

    ast_start_clears_error: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_START)
        |=> ((status_byte & STATUS_ERROR_MASK) == 8'h00)
    ) else $error("[smacc_ctrl] START must clear STATUS_ERROR");

    // Exclude the dp_done cycle: a polling READ can coincide with the
    // FINALIZING -> DONE transition, which READ itself didn't cause.
    ast_read_preserves_state: assert property (
        @(posedge clk) disable iff (rst)
        (insn_valid && flavor == FLV_READ && !dp_done)
        |=> (state_r == $past(state_r))
    ) else $error("[smacc_ctrl] READ must not change FSM state");

    ast_results_valid_only_done: assert property (
        @(posedge clk) disable iff (rst)
        results_valid |-> (state_r == ST_DONE)
    ) else $error("[smacc_ctrl] results_valid asserted outside ST_DONE");

    ast_no_idle_return: assert property (
        @(posedge clk) disable iff (rst)
        (state_r != ST_IDLE) |=> (state_r != ST_IDLE)
    ) else $error("[smacc_ctrl] FSM must not return to ST_IDLE without rst");

`ifndef VERILATOR  // cover sequences below also need full ## support
    cov_full_sequence: cover property (
        @(posedge clk) disable iff (rst)
        (state_r == ST_IDLE)       ##[1:$]
        (state_r == ST_READY)      ##[1:$]
        (state_r == ST_ACCUMULATE) ##[1:$]
        (state_r == ST_FINALIZING) ##[1:$]
        (state_r == ST_DONE)
    );

    cov_error_then_recovery: cover property (
        @(posedge clk) disable iff (rst)
        ((status_byte & STATUS_ERROR_MASK) != 8'h00)
        ##[1:$] ((status_byte & STATUS_ERROR_MASK) == 8'h00)
    );

    cov_restart_after_done: cover property (
        @(posedge clk) disable iff (rst)
        (state_r == ST_DONE) ##[1:$] (state_r == ST_READY) ##[1:$] (state_r == ST_ACCUMULATE)
    );

    // Reachable because STOP is non-stalling: the CPU can START mid-finalize
    // (smacc_tb T9).
    cov_start_aborts_finalizing: cover property (
        @(posedge clk) disable iff (rst)
        (state_r == ST_FINALIZING) ##1 (insn_valid && flavor == FLV_START)
        ##1 (state_r == ST_READY)
    );
`endif // VERILATOR

`endif // SMACC_ASSERT

endmodule: smacc_ctrl

`endif // SMACC_CTRL_SV
