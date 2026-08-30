/* This file is part of JTOPL

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
    Date: 13-6-2020 

*/

module jtopl_reg(
    input            rst,
    input            clk,
    input            cen,
    input      [7:0] din,
    input            write,
    // Pipeline order
    output           zero,
    output     [1:0] group,
    output           op,          // 0 for modulator operators
    output    [17:0] slot,        // hot one encoding of active slot
    output     [2:0] subslot,     // 2026-08-19, task #8 round 40: exposed for
                                   // external channel/operator identification
                                   // (diagnostic use only, not used internally
                                   // outside this file's own pre-existing logic)

    input      [3:0] sel_ch,      // channel to update
    input      [1:0] sel_group,   // group to update
    input      [2:0] sel_sub,     // subslot to update

    input            rhy_en,      // rhythm enable
    input      [4:0] rhy_kon,     // key-on for each rhythm instrument

    //input           csm,
    //input           flag_A,
    //input           overflow_A,

    input            up_fbcon,
    input            up_fnumlo,
    input            up_fnumhi,
    input            up_mult,
    input            up_ksl_tl,
    input            up_ar_dr,
    input            up_sl_rr,
    input            up_wav,
    
    // PG
    output     [9:0] fnum_I,
    output     [2:0] block_I,
    // channel configuration
    output     [2:0] fb_I,
    
    output     [3:0] mul_II,  // frequency multiplier
    output     [1:0] ksl_IV,  // key shift level
    output           amen_IV,
    output           viben_I,
    // OP
    output     [1:0] wavsel_I,
    input            wave_mode,
    // EG
    output           keyon_I,
    output     [5:0] tl_IV,
    output           en_sus_I, // enable sustain
    output     [3:0] arate_I,  // attack  rate
    output     [3:0] drate_I,  // decay   rate
    output     [3:0] rrate_I,  // release rate
    output     [3:0] sl_I,     // sustain level
    output           ks_II,    // key scale
    output           con_I,

    // 2026-08-20, task #8 round 79: direct test of a real race condition
    // found by reading this file plus jtopl_mmr.v/jtopl_div.v: up_ar_dr
    // (and its up_mult/up_ksl_tl/up_sl_rr/up_wav siblings) are one-shot
    // strobes that jtopl_mmr.v clears unconditionally on EVERY subsequent
    // data-phase write, regardless of what that next write targets -- but
    // update_op_I only fires once the free-running round-robin naturally
    // reaches the write's target (sel_group,sel_sub), which can take up
    // to a full 18-slot period. jtopl_div.v divides cenop down to once
    // every 4 cen pulses, making that full period ~24us at this project's
    // confirmed real ce_ym3812 rate (3.0MHz) -- LONGER than the ~10us gap
    // this project already confirmed between consecutive real register
    // writes (from the sound ROM disassembly). Channel 0's Total Level
    // (0x43) and Attack/Decay (0x63) registers both target the same slot
    // (group=0, sub=3, independently confirmed via jtopl_mmr.v's decode of
    // register 0x43 in jtopl.v's own dbg_ch0car_valid comment) and are
    // written back-to-back in the real sequence -- if AR/DR's own write
    // doesn't happen to land within its ~10us window before the NEXT
    // write (FBCON) clears up_ar_dr, the update is silently dropped
    // regardless of anything downstream in jtopl_eg.v. This taps whether
    // up_ar_dr and update_op_I are EVER simultaneously true specifically
    // when the round-robin is at channel 0's carrier's own slot.
    output           dbg_ar_dr_applied_ch0car,

    // 2026-08-21, task #8 round 82: round 80/81's fix (up_ar_dr_op_safe)
    // still never fires, contradicting the theory that up_ar_dr genuinely
    // pulses but gets clobbered before its target slot arrives. Checking
    // the more fundamental question directly: does up_ar_dr (as received
    // by this module, an existing input port) pulse AT ALL, regardless of
    // group/subslot matching.
    output           dbg_up_ar_dr_raw,
    output           dbg_ar_dr_clobbered,
    output           dbg_pending_was_ch0car
);

parameter OPL_TYPE=1;

localparam CH=9;

wire       update_op_I  = !write && sel_group == group && sel_sub == subslot;

// 2026-08-20, task #8 round 80: REAL, HARDWARE-CONFIRMED ROOT CAUSE. Traced
// and directly proven via dbg_ar_dr_applied_ch0car (round 79): jtopl_mmr.v
// unconditionally clears up_ar_dr (and up_mult/up_ksl_tl/up_sl_rr/up_wav)
// on EVERY subsequent data-phase write, regardless of what that next write
// targets -- but update_op_I only fires once the free-running round-robin
// naturally reaches the write's target slot, which can take up to a full
// 18-slot period (~24us at this project's confirmed 3.0MHz ce_ym3812 rate,
// since jtopl_div.v's cenop fires only once every 4 cen pulses). That's
// LONGER than the ~10us gap this project already confirmed between
// consecutive real register writes (sound ROM disassembly) -- and channel
// 0's Total Level (0x43) and Attack/Decay (0x63) registers target the
// identical slot (group=0, sub=3) back-to-back in the real note-setup
// sequence, so AR/DR's write is silently clobbered by the very next write
// (FBCON) before the round-robin ever reaches it. Confirmed on real
// hardware: dbg_ar_dr_applied_ch0car (up_ar_dr && update_op_I gated on
// group==0/subslot==3) NEVER fires, even once, while the raw bus-level
// write clearly lands (ym1_ch0_ar_dr_latch reads a real, non-default
// value) -- the write reaches the chip but never reaches storage.
//
// 2026-08-21, task #8 round 89: REVERTED. Rounds 85-86 confirmed (via
// last_ym1_addr_was_63_ever and the real internal arate_I snapshot, both
// independent of this whole mechanism) that AR/DR's register was never
// written by the Z80 driver in the first place -- this write-application
// race was real but was never the cause of the bug being chased, so it
// was left in place untested against a scenario that actually exercises
// it. A dedicated Gemini safety review (independently verified against
// this file before acting on it) found a genuine, confirmed flaw: the
// pending_ar_dr/pending_ar_dr_group/pending_ar_dr_sub/pending_ar_dr_data
// registers below were a SINGLE global latch (not per-channel), so a
// second AR/DR write to a DIFFERENT channel arriving before the first
// one's target slot was reached would silently overwrite and drop the
// first one -- a real, verifiable regression risk for the other 8
// channels, for no proven benefit. Reverted to the original, simpler
// up_ar_dr & update_op_I gating (matching jtopl_csr.v's revert).
assign dbg_ar_dr_clobbered = 1'b0; // retired along with pending_ar_dr; kept as a port so no downstream plumbing needs to change
assign dbg_pending_was_ch0car = up_ar_dr && (sel_group==2'd0) && (sel_sub==3'd3);
assign dbg_ar_dr_applied_ch0car = up_ar_dr && update_op_I && (group==2'd0) && (subslot==3'd3);
assign dbg_up_ar_dr_raw = up_ar_dr;
reg        update_op_II, update_op_III, update_op_IV;

jtopl_slot_cnt u_slot_cnt(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),

    // Pipeline order
    .zero       ( zero      ),
    .group      ( group     ),
    .op         ( op        ),   // 0 for modulator operators
    .subslot    ( subslot   ),
    .slot       ( slot      )    // hot one encoding of active slot
);

always @(posedge clk) begin
    if(write) begin
        update_op_II   <= 0;
        update_op_III  <= 0;
        update_op_IV   <= 0;
    end else if( cen ) begin
        update_op_II   <= update_op_I;
        update_op_III  <= update_op_II;
        update_op_IV   <= update_op_III;
    end
end

localparam OPCFGW = 4*8 + (OPL_TYPE!=1 ? 2 : 0);

wire [OPCFGW-1:0] shift_out;
wire              en_sus, rhy_oen;

// Sustained is disabled in rhythm mode for channels in group 2 (i.e. 6,7,8)
assign            en_sus_I = rhy_oen ? 1'b0 : en_sus;

jtopl_csr #(.LEN(CH*2),.W(OPCFGW), .OPL_TYPE(OPL_TYPE)) u_csr(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .cen            ( cen           ),
    .din            ( din           ),
    .shift_out      ( shift_out     ),
    .up_mult        ( up_mult       ),
    .up_ksl_tl      ( up_ksl_tl     ),
    .up_ar_dr       ( up_ar_dr      ),
    .up_sl_rr       ( up_sl_rr      ),
    .up_wav         ( up_wav        ),
    .update_op_I    ( update_op_I   ),
    .update_op_II   ( update_op_II  ),
    .update_op_IV   ( update_op_IV  )
);

assign { amen_IV, viben_I, en_sus, ks_II, mul_II,
         ksl_IV, tl_IV,
         arate_I, drate_I, 
         sl_I, rrate_I  } = shift_out[4*8-1:0];

generate
    if( OPL_TYPE==1 )
        assign wavsel_I = 0;
    else
        assign wavsel_I = shift_out[OPCFGW-1:OPCFGW-2] & {2{wave_mode}};
endgenerate

// Memory for CH registers
wire              pre_keyon, pre_con, rhyon_csr;
wire              disable_con;

assign disable_con = rhy_oen && !slot[12] && !slot[15]; // exclude BOTH bd ops (12=mod,15=car keeps FM); force HH(13) to sum
assign con_I       = !rhy_en || !disable_con ? pre_con : 1'b1;
assign keyon_I = rhy_oen ? rhyon_csr : pre_keyon;

jtopl_reg_ch u_reg_ch(
    .rst         ( rst          ),
    .clk         ( clk          ),
    .cen         ( cen          ),
    .zero        ( zero         ),
    .rhy_en      ( rhy_en       ),
    .rhy_kon     ( rhy_kon      ),
    .slot        ( slot         ),

    .din         ( din          ),
    .up_ch       ( sel_ch       ),
    .up_fnumhi   ( up_fnumhi    ),
    .up_fnumlo   ( up_fnumlo    ),
    .up_fbcon    ( up_fbcon     ),

    .group       ( group        ),
    .sub         ( subslot      ),
    .fnum        ( fnum_I       ),
    .block       ( block_I      ),
    .con         ( pre_con      ),
    .fb          ( fb_I         ),
    .keyon       ( pre_keyon    ),
    .rhy_oen     ( rhy_oen      ),
    .rhyon_csr   ( rhyon_csr    )
);

endmodule
