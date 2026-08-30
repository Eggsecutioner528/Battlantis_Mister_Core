// Z80 CPU wrapper for T80s VHDL core

module cpu_z80(
	input nRESET,
	input clk,
	input clken,
	input [7:0] Z80_DIN,
	output [7:0] Z80_DOUT,
	output [15:0] Z80_ADDR,
	output wire nIORQ,
	output wire nMREQ,
	output wire nRFSH,
	output wire nRD,
	output wire nWR,
	input nINT,
	input nNMI,
	input nWAIT,
	output wire nHALT,
	output wire nM1,
	// 2026-08-17, task #8 investigation: internal-register readback, since
	// a bus probe can't see A or the flags directly. Bit positions
	// verified against T80.vhd's REGS concatenation order and
	// T80_ALU.vhd's Flag_Z=6 constant, not just taken on Gemini's word.
	output wire [7:0] z80_a,
	output wire       z80_f_z
);

	wire MREQ_n;
	assign nMREQ = MREQ_n | ~nRFSH;

	wire [211:0] regs;
	assign z80_a   = regs[7:0];
	assign z80_f_z = regs[14];

	T80s cpu(
		.RESET_n(nRESET),
		.CLK(clk),
		.CEN(clken),
		.WAIT_n(nWAIT),
		.INT_n(nINT),
		.NMI_n(nNMI),
		.MREQ_n(MREQ_n),
		.IORQ_n(nIORQ),
		.RD_n(nRD),
		.WR_n(nWR),
		.RFSH_n(nRFSH),
		.A(Z80_ADDR),
		.DI(Z80_DIN),
		.DOUT(Z80_DOUT),
		.HALT_n(nHALT),
		.M1_n(nM1),
		.REGS(regs)
	);

endmodule
