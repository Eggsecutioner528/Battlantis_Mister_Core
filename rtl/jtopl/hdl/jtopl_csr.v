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
    Date: 17-6-2020 

*/

module jtopl_csr #(
    parameter LEN=18, W=34, OPL_TYPE=1
) ( // Circular Shift Register + input mux
    input           rst,
    input           clk,
    input           cen,
    input   [ 7:0]  din,
    output [W-1:0]  shift_out,

    input           up_mult,
    input           up_ksl_tl,
    input           up_ar_dr,
    input           up_sl_rr,
    input           up_wav,
    input           update_op_I,
    input           update_op_II,
    input           update_op_IV
);
// 2026-08-21, task #8 round 89: REVERTED round 80's up_ar_dr_op_safe/
// din_ar_dr_safe write-race fix -- see jtopl_reg.v's matching revert
// comment for the full reasoning (confirmed via direct code review that
// the single global pending-write latch could silently drop a different
// channel's AR/DR write, and the fix was never proven to help the actual
// bug it was chasing). Back to the original up_ar_dr & update_op_I gating.


wire [W-1:0] regop_in;

// 2026-08-20, task #8 round 69: ATTEMPTED swapping this instance to
// jtopl_sh_rst_ram (matching the proven fix for jtopl_eg.v's u_egsh),
// motivated by a 7-boot correlation study showing dbg_arate_I==15
// perfectly predicted the AR=15 envelope-update result. REVERTED
// immediately after testing: it caused a real regression, breaking AR=8/
// 12/13 (previously 100% reliable GREEN since round 67's reset-sync fix)
// down to solid RED on all 7 reload-study boots.
//
// Round 70: tried narrowing the blast radius instead of abandoning the
// lead -- split this register into two, isolating JUST the AR/DR field
// onto its own jtopl_sh_rst_ram instance while every other field stayed
// on jtopl_sh_rst. This made things WORSE (all 5 tested rates went RED,
// not just AR=15), and comparing the two module implementations directly
// explains why mechanistically, not just empirically: jtopl_sh_rst.v's
// `drop` is a combinational read off the shift array (a bit written at
// time t reaches drop after stages-1 clock edges), while
// jtopl_sh_rst_ram.v's `drop` is a REGISTERED read of mem[ptr] (the same
// bit reaches drop after `stages` edges -- one cycle later). Splitting one
// field onto the RAM version while leaving its siblings on the plain
// version puts that field permanently one cycle out of phase with the
// rest of the SAME operator's own register word, corrupting the combined
// parameter set for every note using it. This isn't specific to AR/DR --
// any single-field carve-out of a multi-field CSR word would break the
// same way. It also means round 69's full-register swap avoided the
// cross-field skew (every field got the same extra cycle) but still
// broke AR=8/12/13, so the CSR's output apparently also needs to stay in
// its original stages-1-cycle relationship to jtopl_eg_step.v/
// jtopl_pg_comb.v's own already-tuned round-robin timing -- jtopl_sh_rst_
// ram is not a safe substitute for ANY jtopl_sh_rst instance that has to
// stay cycle-exact with the rest of this pipeline, unlike u_egsh's
// self-contained usage. Back to the original, confirmed-working
// jtopl_sh_rst; the register-storage-swap approach is a dead end here.
jtopl_sh_rst #(.width(W),.stages(LEN)) u_regch(
    .clk    ( clk          ),
    .cen    ( cen          ),
    .rst    ( rst          ),
    .din    ( regop_in     ),
    .drop   ( shift_out    )
);

wire up_ar_dr_op  = up_ar_dr  & update_op_I;
wire up_mult_I    = up_mult   & update_op_I;
wire up_mult_II   = up_mult   & update_op_II;
wire up_mult_IV   = up_mult   & update_op_IV;
wire up_ksl_tl_IV = up_ksl_tl & update_op_IV;
wire up_sl_rr_op  = up_sl_rr  & update_op_I;
wire up_wav_I     = up_wav    & update_op_I;

assign regop_in[31:0] = { // 4 bytes:
        up_mult_IV  ? din[7]      : shift_out[31], // AM enable
        up_mult_I   ? din[6:5]    : shift_out[30:29], // Vib enable, EG type, KSR
        up_mult_II  ? din[4:0]    : shift_out[28:24], // KSR + Mult

        up_ksl_tl_IV? din         : shift_out[23:16], // KSL + TL

        up_ar_dr_op   ? din         : shift_out[15: 8],

        up_sl_rr_op ? din         : shift_out[ 7: 0]
    };

generate if (OPL_TYPE == 2) begin
assign regop_in[33:32] = up_wav_I ? din[1:0] : shift_out[33:32];
end
endgenerate

endmodule
