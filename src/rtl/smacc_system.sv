// smacc_system.sv: System wrapper: PicoRV32 CPU + SMACC co-processor
//
// Connects the PicoRV32 PCPI bus to smacc_top internally.
// Exposes the memory bus and IRQ interface for external integration.
//
// Reset: active-high rst is inverted to picorv32's active-low resetn.
// PCPI: wired internally; no external ports needed.

`ifndef SMACC_SYSTEM_SV
`define SMACC_SYSTEM_SV

`include "smacc_top.sv"

module smacc_system #(
    parameter [31:0] PROGADDR_RESET = 32'h0000_0000,
    parameter [31:0] PROGADDR_IRQ   = 32'h0000_0010,
    parameter [31:0] STACKADDR      = 32'hffff_ffff
) (
    input  logic        clk,
    input  logic        rst,          // active-high

    output logic        trap,         // CPU trapped (illegal instruction, etc.)

    // Memory bus; connect to your RAM/flash/arbiter
    output logic        mem_valid,    // CPU requesting a memory transaction
    output logic        mem_instr,    // high when fetching an instruction
    input  logic        mem_ready,    // memory accepted the transaction
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [ 3:0] mem_wstrb,   // byte write strobes; 0000 = read
    input  logic [31:0] mem_rdata,

    // IRQ interface
    input  logic [31:0] irq,
    output logic [31:0] eoi           // end-of-interrupt
);

    // PicoRV32 uses active-low reset
    logic resetn;
    assign resetn = ~rst;

    // PCPI wires, internal only
    logic        pcpi_valid;
    logic [31:0] pcpi_insn;
    logic [31:0] pcpi_rs1;
    logic [31:0] pcpi_rs2;
    logic        pcpi_wr;
    logic [31:0] pcpi_rd;
    logic        pcpi_wait;
    logic        pcpi_ready;

    picorv32 #(
        .ENABLE_PCPI    (1),
        .ENABLE_COUNTERS(1),
        .CATCH_MISALIGN (1),
        .CATCH_ILLINSN  (1),
        .PROGADDR_RESET (PROGADDR_RESET),
        .PROGADDR_IRQ   (PROGADDR_IRQ),
        .STACKADDR      (STACKADDR)
    ) u_cpu (
        .clk         (clk),
        .resetn      (resetn),
        .trap        (trap),

        .mem_valid   (mem_valid),
        .mem_instr   (mem_instr),
        .mem_ready   (mem_ready),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_wstrb   (mem_wstrb),
        .mem_rdata   (mem_rdata),

        // Look-ahead interface, not used
        .mem_la_read (),
        .mem_la_write(),
        .mem_la_addr (),
        .mem_la_wdata(),
        .mem_la_wstrb(),

        .pcpi_valid  (pcpi_valid),
        .pcpi_insn   (pcpi_insn),
        .pcpi_rs1    (pcpi_rs1),
        .pcpi_rs2    (pcpi_rs2),
        .pcpi_wr     (pcpi_wr),
        .pcpi_rd     (pcpi_rd),
        .pcpi_wait   (pcpi_wait),
        .pcpi_ready  (pcpi_ready),

        .irq         (irq),
        .eoi         (eoi),

        // Trace, not used
        .trace_valid (),
        .trace_data  ()
    );

    smacc_top u_smacc (
        .clk         (clk),
        .rst         (rst),
        .pcpi_valid  (pcpi_valid),
        .pcpi_insn   (pcpi_insn),
        .pcpi_rs1    (pcpi_rs1),
        .pcpi_rs2    (pcpi_rs2),
        .pcpi_wr     (pcpi_wr),
        .pcpi_rd     (pcpi_rd),
        .pcpi_wait   (pcpi_wait),
        .pcpi_ready  (pcpi_ready)
    );

endmodule: smacc_system

`endif // SMACC_SYSTEM_SV
