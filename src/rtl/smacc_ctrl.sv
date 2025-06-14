// smacc_ctrl.sv: SMACC FSM, status flags, and error tracking.
//
// Sequences START/DATA/STOP and drives the status byte. Statistics live in
// smacc_mem and smacc_datapath. insn_valid is a single-cycle strobe
// (enforced by smacc_top).

`ifndef SMACC_CTRL_SV
`define SMACC_CTRL_SV

`include "smacc_isa_defs.sv"

module smacc_ctrl (
    input  logic       clk,
    input  logic       rst,            // synchronous, active-high

    // funct3[1:0]; see smacc_flavor_e in smacc_isa_defs.sv
    input  logic [1:0] flavor,
    input  logic       insn_valid,     // single-cycle strobe

    output logic       dp_start,       // one-cycle pulse: launch the datapath pipeline
    output logic       mem_clear,
    output logic       mem_we_data,

    input  logic       dp_done,        // one-cycle pulse from smacc_datapath
    input  logic       mem_overflow,   // sticky overflow flag from smacc_mem

    output logic [7:0] status_byte
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

    assign data_accepted = is_data & ((state_r == ST_READY) | (state_r == ST_ACCUMULATE));

    // Accumulator overflow, DATA with no active run, or STOP with nothing
    // to compute.
    assign set_error = mem_overflow
                     | (is_data & ~data_accepted)
                     | (is_stop & (state_r != ST_ACCUMULATE));

    always_comb begin
        state_next = state_r;
        if (is_start) begin
            state_next = ST_READY;
        end else begin
            case (state_r)
                ST_READY:         if (is_data) state_next = ST_ACCUMULATE;
                ST_ACCUMULATE:    if (is_stop) state_next = ST_COMPUTE;
                ST_COMPUTE:       if (dp_done) state_next = ST_DONE;
                ST_IDLE, ST_DONE: ;  // hold; only START leaves these states
                default:          state_next = ST_IDLE;
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
                err_sticky_r <= 1'b0;
            end else if (set_error) begin
                err_sticky_r <= 1'b1;
            end
        end
    end

    assign dp_start    = is_stop & (state_r == ST_ACCUMULATE);
    assign mem_clear   = is_start;
    assign mem_we_data = data_accepted;

    always_comb begin
        case (state_r)
            ST_READY, ST_ACCUMULATE: status_flags = STATUS_READY_MASK;
            ST_COMPUTE:              status_flags = STATUS_BUSY_MASK;
            ST_DONE:                 status_flags = STATUS_DONE_MASK;
            default:                 status_flags = 8'h00;
        endcase
    end

    // Low bits carry the FSM state for debug.
    assign status_byte = status_flags
                       | ((err_sticky_r | set_error) ? STATUS_ERROR_MASK : 8'h00)
                       | {5'b0, state_r};

endmodule: smacc_ctrl

`endif // SMACC_CTRL_SV
