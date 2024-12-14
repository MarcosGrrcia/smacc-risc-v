// smacc_top.sv - SMACC top level, PCPI interface to PicoRV32
//
// custom-0 opcode, funct3[1:0] = SMACC ID:
//   00 START   01 DATA   10 STOP   11 READ
// READ: imm[2:0] (insn[22:20]) picks a byte of the output register
//
// START/DATA/READ finish in 1 cycle. STOP holds pcpi_wait until the
// datapath is done (6 cycles).

`ifndef SMACC_TOP_SV
`define SMACC_TOP_SV

`include "smacc_isa_defs.sv"
`include "smacc_ctrl.sv"
`include "smacc_datapath.sv"
`include "smacc_mem.sv"

module smacc_top (
    input  wire        clk,
    input  wire        rst,

    input  wire        pcpi_valid,
    input  wire [31:0] pcpi_insn,
    input  wire [31:0] pcpi_rs1,
    input  wire [31:0] pcpi_rs2,
    output wire        pcpi_wr,
    output wire [31:0] pcpi_rd,
    output wire        pcpi_wait,
    output wire        pcpi_ready
);

    wire       is_custom0 = pcpi_valid && (pcpi_insn[6:0] == `SMACC_OPCODE);
    wire       is_read    = is_custom0 && (pcpi_insn[13:12] == `FLV_READ);
    wire [2:0] sel        = pcpi_insn[22:20];

    // pcpi_valid stays high until we ack, so only act on the first cycle
    reg insn_sent;
    always @(posedge clk or posedge rst) begin
        if (rst)
            insn_sent <= 0;
        else if (!pcpi_valid)
            insn_sent <= 0;
        else if (is_custom0)
            insn_sent <= 1;
    end

    wire insn_valid = is_custom0 && !insn_sent;

    wire       dp_start, dp_done;
    wire       mem_clear, mem_we_data, mem_overflow;
    wire [7:0] status_byte;

    wire [31:0] min_out, max_out;
    wire [63:0] count_out, sum_out, sum_of_sq_out;
    wire [31:0] dp_avg;
    wire [7:0]  dp_stddev, dp_delta;

    // high while a STOP is waiting on the datapath
    reg stop_wait;
    always @(posedge clk or posedge rst) begin
        if (rst)
            stop_wait <= 0;
        else if (dp_start)
            stop_wait <= 1;
        else if (dp_done)
            stop_wait <= 0;
    end

    smacc_ctrl u_ctrl (
        .clk          (clk),
        .rst          (rst),
        .flavor       (pcpi_insn[13:12]),
        .insn_valid   (insn_valid),
        .dp_done      (dp_done),
        .mem_overflow (mem_overflow),
        .dp_start     (dp_start),
        .mem_clear    (mem_clear),
        .mem_we_data  (mem_we_data),
        .status_byte  (status_byte)
    );

    smacc_mem u_mem (
        .clk           (clk),
        .rst           (rst),
        .clear         (mem_clear),
        .write_enable  (mem_we_data),
        .data_in       (pcpi_rs1),
        .min_out       (min_out),
        .max_out       (max_out),
        .count_out     (count_out),
        .sum_out       (sum_out),
        .sum_of_sq_out (sum_of_sq_out),
        .overflow      (mem_overflow)
    );

    smacc_datapath u_dp (
        .clk           (clk),
        .rst           (rst),
        .dp_start      (dp_start),
        .dp_clear      (mem_clear),
        .min_out       (min_out),
        .max_out       (max_out),
        .count_out     (count_out),
        .sum_out       (sum_out),
        .sum_of_sq_out (sum_of_sq_out),
        .dp_avg        (dp_avg),
        .dp_stddev     (dp_stddev),
        .dp_delta      (dp_delta),
        .dp_done       (dp_done)
    );

    // output register, one byte per field:
    //   min | max | avg | count | stddev | delta | status | reserved
    // min/max/count are just the low byte. avg is clamped at 255.
    wire [7:0] avg_field = (dp_avg > 32'd255) ? 8'hFF : dp_avg[7:0];

    reg [63:0] out_reg;
    always @(posedge clk or posedge rst) begin
        if (rst)
            out_reg <= 0;
        else
            out_reg <= {min_out[7:0], max_out[7:0], avg_field, count_out[7:0],
                        dp_stddev, dp_delta, status_byte, 8'h00};
    end

    assign pcpi_wait  = dp_start || stop_wait;
    assign pcpi_ready = (insn_valid && !dp_start) || (stop_wait && dp_done);
    assign pcpi_wr    = is_read && insn_valid;
    assign pcpi_rd    = {24'b0, out_reg[(7 - sel) * 8 +: 8]};

endmodule

`endif
