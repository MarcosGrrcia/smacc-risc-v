// smacc_ctrl.sv - SMACC control FSM and status/error flags

`ifndef SMACC_CTRL_SV
`define SMACC_CTRL_SV

`include "smacc_isa_defs.sv"

module smacc_ctrl (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] flavor,        // funct3[1:0]
    input  wire       insn_valid,    // one cycle per instruction (from top)
    input  wire       dp_done,
    input  wire       mem_overflow,
    output wire       dp_start,
    output wire       mem_clear,
    output wire       mem_we_data,
    output wire [7:0] status_byte
);

    reg [2:0] state;
    reg       err;

    wire is_start = insn_valid && (flavor == `FLV_START);
    wire is_data  = insn_valid && (flavor == `FLV_DATA);
    wire is_stop  = insn_valid && (flavor == `FLV_STOP);

    wire data_ok  = is_data && (state == `ST_READY || state == `ST_ACCUMULATE);
    wire stop_ok  = is_stop && (state == `ST_ACCUMULATE);

    wire set_err  = mem_overflow || (is_data && !data_ok) || (is_stop && !stop_ok);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= `ST_IDLE;
            err   <= 1'b0;
        end else if (is_start) begin
            state <= `ST_READY;
            err   <= 1'b0;
        end else begin
            case (state)
                `ST_READY:      if (is_data) state <= `ST_ACCUMULATE;
                `ST_ACCUMULATE: if (is_stop) state <= `ST_COMPUTE;
                `ST_COMPUTE:    if (dp_done) state <= `ST_DONE;
                default: ;
            endcase
            if (set_err) err <= 1'b1;
        end
    end

    assign dp_start    = stop_ok;
    assign mem_clear   = is_start;
    assign mem_we_data = data_ok;

    reg [7:0] flags;
    always @(*) begin
        case (state)
            `ST_READY, `ST_ACCUMULATE: flags = `STATUS_READY;
            `ST_COMPUTE:               flags = `STATUS_BUSY;
            `ST_DONE:                  flags = `STATUS_DONE;
            default:                   flags = 8'h00;
        endcase
    end

    // low 3 bits = FSM state, handy for debugging
    assign status_byte = flags
                       | ((err || set_err) ? `STATUS_ERROR : 8'h00)
                       | {5'b0, state};

endmodule

`endif
