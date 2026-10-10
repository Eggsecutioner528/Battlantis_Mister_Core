`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Wrapper to adapt Jotego's jtkcpu (HD6309) to the standard mc6809 template interface.
//
// Key insight: jtkcpu samples cen2 on negedge clk. We must ensure cen2 is
// stable before that edge. We achieve this by generating cen2 from a register
// updated on posedge clk, so it's rock-stable by the next negedge.
//////////////////////////////////////////////////////////////////////////////////
module mc6809is(
    input   [7:0] D,
    output  [7:0] DOut,
    output  [15:0] ADDR,
    output  RnW,
    output  E,
    output  Q,
    output  BS,
    output  BA,
    input   nIRQ,
    input   nFIRQ,
    input   nNMI,
    input   CLK_SYS,
    input   CEN_12M,
    input   nHALT,	 
    input   nRESET,
    input   MRDY,
    input   nDMABREQ
    , output  [111:0] RegData
    );



// ------------------------------------------------------------------
// Phase counter: ticks 0-1-2-3 at EXTAL rate (12 MHz), giving a
// 3 MHz bus cycle.  Updated on posedge so that all derived signals
// are stable well before negedge where jtkcpu samples them.
// ------------------------------------------------------------------
reg [1:0] clk_phase = 2'b00;

always @(posedge CLK_SYS) begin
    if (CEN_12M) begin
        if (MRDY)
            clk_phase <= clk_phase + 2'b01;
    end
end

// ------------------------------------------------------------------
// E / Q generation  (active on negedge, classic 6809 timing)
// ------------------------------------------------------------------
reg rE = 0;
reg rQ = 0;
assign E = rE;
assign Q = rQ;

always @(posedge CLK_SYS) begin
    if (CEN_12M) begin
        case (clk_phase)
            2'b00: begin rE <= 0; rQ <= 0; end
            2'b01: begin rE <= 0; rQ <= 1; end
            2'b10: begin rE <= 1; rQ <= 1; end
            2'b11: begin rE <= 1; rQ <= 0; end
        endcase
    end
end

// Synchronize reset release to clk_phase == 1 to guarantee jtkcpu's internal phase
// aligns with our E/Q generation. jtkcpu needs the first cen2 pulse to occur at clk_phase == 2.
reg jtkcpu_rst = 1'b1;
always @(posedge CLK_SYS) begin
    if (~nRESET) begin
        jtkcpu_rst <= 1'b1;
    end else if (CEN_12M && clk_phase == 2'b01) begin
        jtkcpu_rst <= 1'b0;
    end
end

// Instantiate Jotego's jtkcpu (HD6309)
jtkcpu cpu_core (
    .clk(CLK_SYS),
    .rst(jtkcpu_rst),
    .cen2(CEN_12M && (clk_phase[0] == 1'b0) && MRDY),
    .halt(~nHALT),
    .nmi_n(nNMI),
    .irq_n(nIRQ),
    .firq_n(nFIRQ),
    .dtack(MRDY),
    .din(D),
    .dout(DOut),
    .addr(cpu_addr_24), // jtkcpu has a 24-bit address bus
    .we(cpu_we),
    .pcbad(),
    .buserror(),
    .is_int(cpu_is_int)
);

wire [23:0] cpu_addr_24;
assign ADDR = cpu_addr_24[15:0];

wire cpu_we;
assign RnW = ~cpu_we;

// jtkcpu has no real BS/BA bus-status outputs (unlike mc6809i.v), so this
// core has no way to natively signal "sync/halt state" (BS=0,BA=1) or
// "high-Z/halt-granted" (BS=1,BA=1) the way mc6809i.v's own CPUSTATE_SYNC/
// CPUSTATE_HALTED do. The only thing Battlantis.sv's own logic actually
// depends on functionally is k007342_irq_ack = cpu_bs & ~cpu_ba, which
// needs to be true only during a genuine interrupt-vector fetch (real
// 6809/6309 "ACK Interrupt" bus state, BS=1/BA=0 per mc6809i.v's own
// CPUSTATE_IRQACK-style branches around line 3866+, confirmed against
// the actual code, not its stale header comment table which has the
// rows swapped). jtkcpu's own genuinely-equivalent internal signal for
// that specific cycle is is_int (jtkcpu_memctrl.v), asserted only while
// actually fetching the IRQ/FIRQ/NMI/RST vector, so BS=is_int/BA=0
// reproduces the exact functional behavior Battlantis.sv needs without
// needing to fake a SYNC- or HALT-specific bus state that nothing here
// currently reads.
wire cpu_is_int;
assign BS = cpu_is_int;
assign BA = 1'b0;


endmodule
