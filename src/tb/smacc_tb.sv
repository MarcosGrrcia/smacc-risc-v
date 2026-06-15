// smacc_tb.sv: Self-checking testbench for the SMACC accelerator.
//
// Drives the PCPI bus directly (no CPU model) and compares every statistic
// against hand-computed expected values. All tests run back-to-back; the
// bench prints one PASS/FAIL line per check and a final summary.
//
//   T1  Full run (10 samples): running stats mid-run, all six results
//   T2  STOP with no data            -> STATUS_ERROR
//   T3  DATA before START            -> STATUS_ERROR, cleared by START
//   T4  Single sample                -> stddev = delta = 0
//   T5  Identical samples            -> stddev = delta = 0
//   T6  Two-point spread (0, 254)    -> exact stddev
//   T7  Restart after DONE           -> no state leaks between runs
//   T8  Large samples (100k, 300k)   -> full 32-bit results
//   T9  START aborts an in-flight finalization -> clean recovery
//   T10 All-zero samples             -> every statistic reads 0
//   T11 Single max sample (2^32-1)   -> exact math at the top of the range
//   T12 Sum-of-squares overflow      -> saturates, sticky STATUS_ERROR
//   T13 64 random samples            -> checked against a reference model
//
// Run from the project root:
//   $ bash scripts/run_tests.sh            # lint + simulate (assertions on)
//   $ bash scripts/run_tests.sh --wave     # also dump smacc_tb.vcd

`timescale 1ns / 1ps

`include "smacc_isa_defs.sv"
`include "smacc_top.sv"

module smacc_tb;

    // ----------------------------------------------------------------
    // Instruction encodings (ISA_SPEC.md section 3): custom-0 opcode, operation
    // in funct3, READ's statistic selector in imm[2:0].
    // ----------------------------------------------------------------
    localparam logic [31:0] INSN_START = {17'b0, 3'b000, 5'b0, RISCV_OPCODE_CUSTOM0};
    localparam logic [31:0] INSN_DATA  = {17'b0, 3'b001, 5'b0, RISCV_OPCODE_CUSTOM0};
    localparam logic [31:0] INSN_STOP  = {17'b0, 3'b010, 5'b0, RISCV_OPCODE_CUSTOM0};

    function automatic logic [31:0] insn_read(input smacc_stat_sel_e sel);
        return {9'b0, 3'(sel), 5'b0, 3'b011, 5'b0, RISCV_OPCODE_CUSTOM0};
    endfunction

    // ----------------------------------------------------------------
    // Clock (100 MHz), DUT, PCPI wires
    // ----------------------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic        rst;
    logic        pcpi_valid = 1'b0;
    logic [31:0] pcpi_insn  = '0;
    logic [31:0] pcpi_rs1   = '0;
    logic        pcpi_wr;
    logic [31:0] pcpi_rd;
    logic        pcpi_wait;
    logic        pcpi_ready;

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

    int unsigned cycles = 0;
    always @(posedge clk) cycles++;

    int unsigned fails = 0;

    // Status flags as READ returns them: one byte, zero-extended to 32 bits.
    localparam logic [31:0] F_READY = {24'b0, STATUS_READY_MASK};
    localparam logic [31:0] F_BUSY  = {24'b0, STATUS_BUSY_MASK};
    localparam logic [31:0] F_DONE  = {24'b0, STATUS_DONE_MASK};
    localparam logic [31:0] F_ERROR = {24'b0, STATUS_ERROR_MASK};

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    // Drive one instruction and sample pcpi_rd on the acknowledge edge.
    // Every SMACC op (including STOP) acks the cycle it is presented, so
    // one task covers all four instructions.
    task automatic issue(
        input  logic [31:0] insn,
        input  logic [31:0] rs1,
        output logic [31:0] rd
    );
        @(posedge clk); #1;
        pcpi_valid = 1'b1;
        pcpi_insn  = insn;
        pcpi_rs1   = rs1;
        @(posedge clk);
        if (!pcpi_ready)
            $fatal(1, "pcpi_ready not asserted (cycle %0d)", cycles);
        rd = pcpi_rd;
        #1;
        pcpi_valid = 1'b0;
    endtask

    // STOP returns immediately; software polls STATUS_DONE (ISA_SPEC.md
    // section 7.3). Finalization is fixed at 162 cycles, so 200 polls is ample.
    task automatic poll_done;
        logic [31:0] st;
        repeat (200) begin
            issue(insn_read(STAT_STATUS), '0, st);
            if ((st & F_DONE) != 0) return;
        end
        $fatal(1, "STATUS_DONE never set (cycle %0d)", cycles);
    endtask

    task automatic check(
        input string       tag,
        input logic [31:0] got,
        input logic [31:0] exp
    );
        if (got !== exp) begin
            $error("[FAIL] %-13s got=%0d exp=%0d", tag, got, exp);
            fails++;
        end else
            $display("[PASS] %-13s = %0d", tag, got);
    endtask

    task automatic reset_dut;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        #1; rst = 1'b0;
    endtask

    // Finalize the current run and check all six statistics.
    task automatic expect_stats(
        input string tag,
        input logic [31:0] e_min, e_max, e_count, e_avg, e_stddev, e_delta
    );
        logic [31:0] rd;
        issue(INSN_STOP, '0, rd);
        poll_done();
        issue(insn_read(STAT_MIN),    '0, rd);  check({tag, " min"},    rd, e_min);
        issue(insn_read(STAT_MAX),    '0, rd);  check({tag, " max"},    rd, e_max);
        issue(insn_read(STAT_COUNT),  '0, rd);  check({tag, " count"},  rd, e_count);
        issue(insn_read(STAT_AVG),    '0, rd);  check({tag, " avg"},    rd, e_avg);
        issue(insn_read(STAT_STDDEV), '0, rd);  check({tag, " stddev"}, rd, e_stddev);
        issue(insn_read(STAT_DELTA),  '0, rd);  check({tag, " delta"},  rd, e_delta);
    endtask

    // Drive n random samples and check against a software reference model
    // using the same ISA math (truncating divide, floored variance, integer
    // sqrt). Samples are 24-bit to keep the accumulators clear of overflow.
    task automatic run_random_test(input int n, input int unsigned seed);
        logic [31:0]     rd, sample, mn, mx;
        longint unsigned n64, s64, sum, sum_sq, avg, mean_sq, variance, root, b;
        void'($urandom(seed));
        mn  = 32'hFFFF_FFFF;
        mx  = '0;
        sum = 0;
        sum_sq = 0;
        issue(INSN_START, '0, rd);
        repeat (n) begin
            sample = $urandom_range(32'h00FF_FFFF);
            if (sample < mn) mn = sample;
            if (sample > mx) mx = sample;
            s64     = {32'b0, sample};
            sum    += s64;
            sum_sq += s64 * s64;
            issue(INSN_DATA, sample, rd);
        end
        n64      = longint'(n);
        avg      = sum / n64;
        mean_sq  = sum_sq / n64;
        variance = (mean_sq >= avg * avg) ? (mean_sq - avg * avg) : 0;
        root = 0;
        for (b = 64'd1 << 24; b > 0; b >>= 1)
            if ((root + b) * (root + b) <= variance) root += b;
        expect_stats("T13", mn, mx, n, avg[31:0], root[31:0], mx - mn);
    endtask

    // ----------------------------------------------------------------
    // Tests
    // ----------------------------------------------------------------
    initial begin : main
        logic [31:0] rd;

        // T1 -- Samples 5..50: sum=275, avg=27, variance=962-27^2=233,
        //       stddev=isqrt(233)=15. Also checks running stats mid-run and
        //       that avg reads 0 until finalization completes.
        $display("\n-- T1: full run, 10 samples --");
        reset_dut();
        issue(INSN_START, '0, rd);
        for (int i = 1; i <= 10; i++) issue(INSN_DATA, i * 5, rd);
        issue(insn_read(STAT_MIN),   '0, rd);  check("T1 run min",   rd, 5);
        issue(insn_read(STAT_COUNT), '0, rd);  check("T1 run count", rd, 10);
        issue(insn_read(STAT_AVG),   '0, rd);  check("T1 avg gated", rd, 0);
        expect_stats("T1", 5, 50, 10, 27, 15, 45);

        // T2 -- STOP outside ACCUMULATE sets the sticky error flag
        //       (ISA_SPEC.md section 9); READY remains set alongside it.
        $display("\n-- T2: illegal STOP --");
        reset_dut();
        issue(INSN_START, '0, rd);
        issue(INSN_STOP,  '0, rd);
        issue(insn_read(STAT_STATUS), '0, rd);
        check("T2 error", rd & F_ERROR, F_ERROR);

        // T3 -- DATA with no active run: sample discarded, error set,
        //       then cleared by START.
        $display("\n-- T3: DATA before START --");
        reset_dut();
        issue(INSN_DATA, 32'd99, rd);
        issue(insn_read(STAT_STATUS), '0, rd);
        check("T3 error set", rd & F_ERROR, F_ERROR);
        issue(INSN_START, '0, rd);
        issue(insn_read(STAT_STATUS), '0, rd);
        check("T3 error clr", rd & F_ERROR, 0);

        // T4 -- One sample: avg is the sample, stddev/delta 0. Mid-run reads
        //       guard a past bug where the first sample lagged a cycle.
        $display("\n-- T4: single sample --");
        reset_dut();
        issue(INSN_START, '0, rd);
        issue(INSN_DATA, 32'd200, rd);
        issue(insn_read(STAT_COUNT), '0, rd);  check("T4 run count", rd, 1);
        issue(insn_read(STAT_MIN),   '0, rd);  check("T4 run min",   rd, 200);
        expect_stats("T4", 200, 200, 1, 200, 0, 0);

        // T5 -- Identical samples: variance is exactly 0.
        $display("\n-- T5: identical samples (5x50) --");
        reset_dut();
        issue(INSN_START, '0, rd);
        repeat (5) issue(INSN_DATA, 32'd50, rd);
        expect_stats("T5", 50, 50, 5, 50, 0, 0);

        // T6 -- Samples 0 and 254: variance = 127^2, so stddev is exact (127).
        $display("\n-- T6: two-point spread (0, 254) --");
        reset_dut();
        issue(INSN_START, '0, rd);
        issue(INSN_DATA, 32'd0,   rd);
        issue(INSN_DATA, 32'd254, rd);
        expect_stats("T6", 0, 254, 2, 127, 127, 254);

        // T7 -- Second run must not inherit state from the first.
        //       Run 2: variance=66, stddev=isqrt(66)=8.
        $display("\n-- T7: restart after DONE --");
        reset_dut();
        issue(INSN_START, '0, rd);
        for (int i = 1; i <= 3; i++) issue(INSN_DATA, i, rd);
        issue(INSN_STOP, '0, rd);
        poll_done();
        issue(INSN_START, '0, rd);
        for (int i = 1; i <= 3; i++) issue(INSN_DATA, i * 10, rd);
        expect_stats("T7", 10, 30, 3, 20, 8, 20);

        // T8 -- Values far beyond 8 bits exercise the full 32-bit result
        //       path: variance = 1e10, stddev = exactly 100000.
        $display("\n-- T8: large samples (100000, 300000) --");
        reset_dut();
        issue(INSN_START, '0, rd);
        issue(INSN_DATA, 32'd100000, rd);
        issue(INSN_DATA, 32'd300000, rd);
        expect_stats("T8", 100000, 300000, 2, 200000, 100000, 200000);

        // T9 -- START while the engine is mid-flight must abort it (BUSY
        //       clears, stats stay gated) and leave the next run consistent.
        $display("\n-- T9: START aborts finalization --");
        reset_dut();
        issue(INSN_START, '0, rd);
        issue(INSN_DATA, 32'd5, rd);
        issue(INSN_DATA, 32'd9, rd);
        issue(INSN_STOP, '0, rd);                       // engine starts
        issue(insn_read(STAT_STATUS), '0, rd);
        check("T9 busy",   rd & F_BUSY, F_BUSY);
        issue(insn_read(STAT_STDDEV), '0, rd);
        check("T9 gated",  rd, 0);
        issue(INSN_START, '0, rd);                      // abort mid-flight
        issue(insn_read(STAT_STATUS), '0, rd);
        check("T9 status", rd, F_READY);
        issue(INSN_DATA, 32'd7, rd);
        issue(INSN_DATA, 32'd7, rd);
        expect_stats("T9", 7, 7, 2, 7, 0, 0);

        // T10 -- All zeros: every statistic reads 0; count proves the
        //        samples were accepted.
        $display("\n-- T10: all-zero samples --");
        reset_dut();
        issue(INSN_START, '0, rd);
        repeat (4) issue(INSN_DATA, 32'd0, rd);
        expect_stats("T10", 0, 0, 4, 0, 0, 0);

        // T11 -- Largest legal sample: its square just fits the 64-bit
        //        accumulator, so avg is exact and variance is 0.
        $display("\n-- T11: single max sample (2^32-1) --");
        reset_dut();
        issue(INSN_START, '0, rd);
        issue(INSN_DATA, 32'hFFFF_FFFF, rd);
        expect_stats("T11", 32'hFFFF_FFFF, 32'hFFFF_FFFF, 1,
                     32'hFFFF_FFFF, 0, 0);

        // T12 -- Two max samples overflow sum_of_squares: it saturates and
        //        ERROR latches. Finalization still completes (avg exact,
        //        variance floors to 0); derived stats are invalid once ERROR
        //        is set (ISA_SPEC.md section 9).
        $display("\n-- T12: sum-of-squares overflow --");
        reset_dut();
        issue(INSN_START, '0, rd);
        issue(INSN_DATA, 32'hFFFF_FFFF, rd);
        issue(INSN_DATA, 32'hFFFF_FFFF, rd);
        issue(insn_read(STAT_STATUS), '0, rd);
        check("T12 error", rd & F_ERROR, F_ERROR);
        expect_stats("T12", 32'hFFFF_FFFF, 32'hFFFF_FFFF, 2,
                     32'hFFFF_FFFF, 0, 0);

        // T13 -- Random regression with a fixed seed for reproducibility.
        $display("\n-- T13: 64 random samples vs reference model --");
        reset_dut();
        run_random_test(64, 32'h00C0FFEE);

        // ------------------------------------------------------------
        repeat (4) @(posedge clk);
        if (fails == 0)
            $display("\n*** ALL TESTS PASSED *** (%0d cycles)", cycles);
        else
            $error("\n*** %0d CHECK(S) FAILED ***", fails);
        $finish;
    end : main

    // Waveform dump for GTKWave: compile with --trace +define+DUMP_VCD
    // (scripts/run_tests.sh --wave does this).
`ifdef DUMP_VCD
    initial begin
        $dumpfile("smacc_tb.vcd");
        $dumpvars(0, smacc_tb);
    end
`endif

    // Watchdog: 13 tests x at most ~600 cycles each, with margin.
    initial begin
        #80_000;
        $fatal(1, "Watchdog timeout at %0t ns", $time);
    end

endmodule: smacc_tb
