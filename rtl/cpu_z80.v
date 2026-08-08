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
	input nWAIT
);

	wire MREQ_n;
	assign nMREQ = MREQ_n | ~nRFSH;

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
		.DOUT(Z80_DOUT)
	);

endmodule
