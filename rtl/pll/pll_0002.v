`timescale 1ns/10ps
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1' (SDRAM_CLK source: same 48MHz, phase-shifted so the
	// external SDRAM chip's clock edges arrive well ahead of clk_sys's own
	// edges, maximizing read-data setup margin at the FPGA input register --
	// see sdram.sv for why this replaced the internal altddio_out 180 deg
	// shift, which had no SDC timing constraint and could route through
	// general fabric with unpredictable added delay)
	output wire outclk_1,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(2),
		.output_clock_frequency0("48.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("48.000000 MHz"),
		.phase_shift1("5208 ps"), // 90deg (2026-08-11): REVERTED -- 90deg is the optimal timing-closed configuration.
		                          // tried 45deg (2604 ps)
		                          // (Template.sdc, same session) and constraints correctly
		                          // referencing SDRAM_CLK instead of a fragile manual clk_sys
		                          // offset, TimeQuest could finally compute the REAL
		                          // clk_sys-to-SDRAM_CLK cross-domain relationship for the
		                          // first time -- and at 180deg it reported a genuine setup
		                          // violation on clk_sys itself (-3.991ns slack, -60.475ns
		                          // TNS, the MAIN system clock domain covering CPU/video/
		                          // everything), which did not exist at 90deg. Confirms
		                          // 180deg is too aggressive a shift for this design's real
		                          // timing budget; reverted rather than risk deploying a
		                          // build with a confirmed violation on the main clock.
		                          // Earlier trials at both 90deg and 180deg (see below) were
		                          // compiled without SDRAM_CLK being constrained at all, so
		                          // neither was a real test of the phase amount itself.
		                          // Confirmed via trial: altera_pll only accepts phase_shift in
		                          // [0, half-period] for this parameter (17833 ps, past
		                          // the half-period mark, was rejected outright), so
		                          // trying a smaller shift within that confirmed range.
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

