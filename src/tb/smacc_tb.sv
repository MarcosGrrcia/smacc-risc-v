// smacc_tb.sv - testbench for SMACC
// Drives the PCPI bus directly, no CPU. Prints pass/fail for each check.
//
// build:
//   $ verilator --binary --timing -Isrc/rtl --top-module smacc_tb src/tb/smacc_tb.sv

`timescale 1ns / 1ps

`include "smacc_top.sv"

module smacc_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg         rst;
    reg         pcpi_valid = 0;
    reg  [31:0] pcpi_insn  = 0;
    reg  [31:0] pcpi_rs1   = 0;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    smacc_top dut (
        .clk        (clk),
        .rst        (rst),
        .pcpi_valid (pcpi_valid),
        .pcpi_insn  (pcpi_insn),
        .pcpi_rs1   (pcpi_rs1),
        .pcpi_rs2   (32'b0),
        .pcpi_wr    (pcpi_wr),
        .pcpi_rd    (pcpi_rd),
        .pcpi_wait  (pcpi_wait),
        .pcpi_ready (pcpi_ready)
    );

    // encodings from ISA_SPEC.md
    localparam [31:0] I_START = 32'h0000_000B;
    localparam [31:0] I_DATA  = 32'h0000_100B;
    localparam [31:0] I_STOP  = 32'h0000_200B;

    function [31:0] i_read(input [2:0] sel);
        i_read = 32'h0000_300B | ({29'b0, sel} << 20);
    endfunction

    integer errors = 0;
    integer i;
    reg [31:0] rd;

    task send(input [31:0] insn, input [31:0] val);
        begin
            @(posedge clk); #1;
            pcpi_valid = 1;
            pcpi_insn  = insn;
            pcpi_rs1   = val;
            @(posedge clk);
            while (!pcpi_ready) @(posedge clk);   // STOP stalls here
            rd = pcpi_rd;
            #1;
            pcpi_valid = 0;
        end
    endtask

    task check(input string name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %0s: got %0d, expected %0d", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %0s = %0d", name, got);
            end
        end
    endtask

    task read_all(input string t,
                  input [31:0] e_min, e_max, e_avg, e_cnt, e_sd, e_dl);
        begin
            send(i_read(0), 0); check({t, " min"},    rd, e_min);
            send(i_read(1), 0); check({t, " max"},    rd, e_max);
            send(i_read(2), 0); check({t, " avg"},    rd, e_avg);
            send(i_read(3), 0); check({t, " count"},  rd, e_cnt);
            send(i_read(4), 0); check({t, " stddev"}, rd, e_sd);
            send(i_read(5), 0); check({t, " delta"},  rd, e_dl);
        end
    endtask

    task do_reset;
        begin
            rst = 1;
            repeat (2) @(posedge clk);
            #1 rst = 0;
        end
    endtask

    initial begin
        // T1: 5,10,...,50
        //   avg = 275/10 = 27, E[x^2] = 9625/10 = 962
        //   var = 962 - 729 = 233, stddev = 15, delta = 45
        //   avg should read 0 until STOP is done
        $display("--- T1: 10 samples ---");
        do_reset;
        send(I_START, 0);
        for (i = 1; i <= 10; i = i + 1) send(I_DATA, i * 5);
        send(i_read(0), 0); check("T1 run min", rd, 5);
        send(i_read(3), 0); check("T1 run count", rd, 10);
        send(i_read(2), 0); check("T1 avg gated", rd, 0);
        send(I_STOP, 0);
        read_all("T1", 5, 50, 27, 10, 15, 45);

        // T2: STOP right after START is illegal -> error bit (0x10)
        $display("--- T2: STOP with no data ---");
        do_reset;
        send(I_START, 0);
        send(I_STOP, 0);
        send(i_read(6), 0);
        check("T2 error", rd & 32'h10, 32'h10);

        // T3: DATA before START -> error, START clears it
        $display("--- T3: DATA before START ---");
        do_reset;
        send(I_DATA, 99);
        send(i_read(6), 0);
        check("T3 error", rd & 32'h10, 32'h10);
        send(I_START, 0);
        send(i_read(6), 0);
        check("T3 cleared", rd & 32'h10, 0);

        // T4: one sample. Read count/min before STOP too, they should
        // update right away
        $display("--- T4: single sample ---");
        do_reset;
        send(I_START, 0);
        send(I_DATA, 200);
        send(i_read(3), 0); check("T4 run count", rd, 1);
        send(i_read(0), 0); check("T4 run min", rd, 200);
        send(I_STOP, 0);
        read_all("T4", 200, 200, 200, 1, 0, 0);

        // T5: 50 x5 -> stddev 0
        $display("--- T5: identical samples ---");
        do_reset;
        send(I_START, 0);
        for (i = 0; i < 5; i = i + 1) send(I_DATA, 50);
        send(I_STOP, 0);
        read_all("T5", 50, 50, 50, 5, 0, 0);

        // T6: 0 and 254 -> avg 127, var = 32258 - 16129 = 16129, stddev 127
        $display("--- T6: two-point spread ---");
        do_reset;
        send(I_START, 0);
        send(I_DATA, 0);
        send(I_DATA, 254);
        send(I_STOP, 0);
        read_all("T6", 0, 254, 127, 2, 127, 254);

        // T7: second run shouldn't see anything from the first
        //   10,20,30: avg 20, E[x^2] = 1400/3 = 466, var 66, stddev 8
        $display("--- T7: restart ---");
        do_reset;
        send(I_START, 0);
        for (i = 1; i <= 3; i = i + 1) send(I_DATA, i);
        send(I_STOP, 0);
        send(I_START, 0);
        for (i = 1; i <= 3; i = i + 1) send(I_DATA, i * 10);
        send(I_STOP, 0);
        read_all("T7", 10, 30, 20, 3, 8, 20);

        // T8: values that don't fit in 8 bits
        //   100000, 300000: avg 200000, var = 5e10 - 4e10 = 1e10,
        //   stddev = 100000 exactly
        $display("--- T8: large samples ---");
        do_reset;
        send(I_START, 0);
        send(I_DATA, 100000);
        send(I_DATA, 300000);
        send(I_STOP, 0);
        read_all("T8", 100000, 300000, 200000, 2, 100000, 200000);

        repeat (4) @(posedge clk);
        if (errors == 0) $display("\nALL TESTS PASSED");
        else             $display("\n%0d TEST(S) FAILED", errors);
        $finish;
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("smacc_tb.vcd");
        $dumpvars(0, smacc_tb);
    end
`endif

    // in case something hangs
    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
