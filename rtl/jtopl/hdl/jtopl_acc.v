/* This file is part of JTOPL.

 
    JTOPL program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTOPL program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTOPL.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 20-6-2020 

*/

module jtopl_acc(
    input                rst,
    input                clk,
    input                cenop,
    input         [17:0] slot,
    input                rhy_en,
    input  signed [12:0] op_result,
    input                zero,
    input                op,  // 0 for modulator operators
    input                con, // 0 for modulated connection
    output signed [15:0] snd
);

wire               sum_en;
wire signed [13:0] op2x;
wire               rhy2x;

// all rhythm channels are amplified by two
// given the data path latency, slot 16(-1) data enters at slot 6(-1) and so on
// slots 13~18 (counting from 1 to 18) will enter when bits slot[7:2] are set
assign rhy2x  = rhy_en && |slot[5:0]; // rhythm ops at slots 0-5; [7:2] missed HH@slot1
assign sum_en = op | con;
assign op2x   = rhy2x ? {op_result, 1'b0} : {op_result[12],op_result};

// 2026-08-23, task #8 round 134: REMOVED a non-chip-accurate, hardcoded
// per-channel volume table that was present in this file since this
// repo's very first commit (2026-08-16), labeled in its own comment as a
// "GLOBAL test build" -- it applied an arbitrary, unexplained gain
// (0dB/-3dB/-2dB/-2dB) to channels 0-3 specifically (identified by which
// accumulator slot each channel's carrier lands on), leaving channels
// 4-8 and the rhythm/drum slots untouched. Real YM3812 hardware has no
// such per-channel scaling -- every channel plays at whatever level its
// own TL/envelope computes, nothing more. This silently biased both
// chips' channel balance for the entire session without ever being
// identified or explained, and is exactly the kind of hardcoded
// special-case this project's own standing practice says to avoid in
// favor of genuine, chip-accurate behavior. Restored to plain unity gain
// for every channel (feeding `op2x` straight into the accumulator, no
// scaling stage at all).

// Continuous output
jtopl_single_acc #(.INW(14),.OUTW(16))  u_acc(
    .clk        ( clk       ),
    .cenop      ( cenop     ),
    .op_result  ( op2x      ),
    .sum_en     ( sum_en    ),
    .zero       ( zero      ),
    .snd        ( snd       )
);

endmodule
