/*  This file is part of JTOPL.

    JTOPL is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTOPL is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTOPL.  If not, see <http://www.gnu.org/licenses/>.

	Author: Jose Tejada Gomez. Twitter: @topapate
	Version: 1.0
	Date: 13-6-2020
	*/

// stages must be greater than 2
module jtopl_sh_rst #(parameter width=5, stages=18, rstval=1'b0 )
(
	input					rst,	
	input 					clk,
	input					cen,
	input		[width-1:0]	din,
   	output		[width-1:0]	drop
);

// 2026-08-20, task #8 round 75: real compile-log evidence (not
// speculation) shows Quartus auto-inferring an altshift_taps megafunction
// (a dedicated MLAB-based shift-register IP block) from this per-bit
// array, for every jtopl_sh_rst instance in the design (confirmed
// directly: "Inferred altshift_taps megafunction from the following
// design logic: ...jtopl_sh_rst:u_konsh|bits_rtl_0", round 74's compile
// log) -- despite the RTL describing plain discrete flip-flops. This
// means the actual synthesized hardware is running Quartus's own IP
// block, not literally what this file describes, which is exactly the
// class of "provably correct in every simulator, never correct on this
// one real synthesis" gap this whole investigation keeps finding (every
// simulator just executes the RTL as written; only real synthesis
// substitutes this IP). shreg_extract="no" forces genuine discrete
// registers instead, for the first time actually testing whether the
// automatic shift-register-IP substitution itself (rather than which
// RTL-level storage module is chosen) is the real, hardware-specific
// culprit.
// 2026-08-20, task #8 round 75/76: TESTED AND REVERTED. Compile-log
// evidence showed Quartus auto-inferring an altshift_taps megafunction
// (MLAB-based shift-register IP) from this per-bit array for every
// jtopl_sh_rst instance, despite the RTL describing discrete flip-flops --
// a real, confirmed-via-log gap between source and synthesized hardware.
// Forced genuine discrete registers via the Quartus-specific
// altera_attribute pragma (round 75's first attempt used Xilinx-style
// shreg_extract, which Quartus silently ignored -- confirmed ineffective
// via compile log; round 76 used the correct pragma and confirmed via
// compile log that altshift_taps inference genuinely stopped for every
// jtopl_sh/jtopl_sh_rst instance). Verified on real, currently-reproducing
// Battlantis hardware: no change -- ch0_car_eg_changed/ch0car_eg_in_I_
// changed still RED, audio_gt256/gt4096 still RED. Reverted; the automatic
// shift-register-IP substitution, while real, isn't (solely) the cause.
reg [stages-1:0] bits[width-1:0];
wire [width-1:0] din_mx = rst ? {width{rstval[0]}} : din;

genvar i;
generate
	for (i=0; i < width; i=i+1) begin: bit_shifter
		always @(posedge clk) if(cen) begin
			bits[i] <= {bits[i][stages-2:0], din_mx[i]};
		end
		assign drop[i] = bits[i][stages-1];
	end
endgenerate

endmodule
