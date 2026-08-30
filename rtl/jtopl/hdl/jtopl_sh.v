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
	Date: 19-6-2020
	*/

// stages must be greater than 2
module jtopl_sh #(parameter width=5, stages=24 )
(
	input 				clk,
	input				cen,
	input	[width-1:0]	din,
   	output	[width-1:0]	drop
);

// 2026-08-20, task #8 round 75: same rationale as jtopl_sh_rst.v's
// identical change -- confirmed via compile log that Quartus auto-infers
// an altshift_taps megafunction from this exact per-bit array pattern too
// (e.g. u_cntsh, u_fnumsh, u_blocksh in jtopl_eg.v, and a jtopl_op.v
// instance explicitly tagged "shift_taps_egv" -- envelope generator value
// -- in the Fitter's own log). Forcing genuine discrete registers here as
// well, for consistency across every shift-register-shaped module in this
// design.
// 2026-08-20, task #8 round 75/76: TESTED AND REVERTED. See
// jtopl_sh_rst.v's identical change for the full reasoning -- verified on
// real hardware to make no difference to the frozen envelope.
reg [stages-1:0] bits[width-1:0];

genvar i;
generate
	for (i=0; i < width; i=i+1) begin: bit_shifter
		always @(posedge clk) if(cen) begin
			bits[i] <= {bits[i][stages-2:0], din[i]};
		end
		assign drop[i] = bits[i][stages-1];
	end
endgenerate

endmodule
