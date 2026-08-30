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
    Date: 10-6-2020

    */

module jtopl(
    input                  rst,        // rst should be at least 6 clk&cen cycles long
    input                  clk,        // CPU clock
    input                  cen,        // optional clock enable, it not needed leave as 1'b1
    input           [ 7:0] din,
    input                  addr,
    input                  cs_n,
    input                  wr_n,
    output          [ 7:0] dout,
    output                 irq_n,
    // combined output
    output  signed  [15:0] snd,
    output                 sample,

    // 2026-08-19, task #8 round 40: diagnostic-only taps into the internal
    // envelope generator, added to investigate a confirmed real-hardware-vs-
    // simulation magnitude gap (isolated simulation of this exact core, with
    // the exact real, exhaustively register-level-verified-correct
    // Battlantis channel-0 note, reaches a genuine ~3954/32767 peak; real
    // hardware never exceeds 256 across 40+ real seconds with the identical
    // configuration). dbg_eg_V is the envelope generator's raw current
    // output (0=loudest/no attenuation, higher=more attenuated, matching
    // eg_V's own existing internal convention -- see jtopl_eg.v).
    // dbg_ch0car_valid pulses for exactly one cenop cycle whenever dbg_eg_V
    // is valid for channel 0's carrier operator specifically (internal
    // group==0, subslot==3 -- independently confirmed via jtopl_mmr.v's own
    // real register-decode logic for register 0x43, channel 0's carrier
    // Total Level register: selreg[4:3]=group=0, selreg[2:0]=subslot=3).
    // The 3-stage delay below exists because eg_V is registered through
    // jtopl_eg.v's own internal 4-stage I->II->III->IV pipeline before
    // becoming valid, so the {group,subslot} that identified the ORIGINAL
    // request must be delayed by the same 3 cycles to correctly identify
    // eg_V's owner once it emerges -- confirmed by cross-referencing
    // against jtopl_op.v's own identical pattern (its u_delay, also 3
    // stages, produces group_d/op_d specifically so they land on the same
    // cycle as eg_atten_II, i.e. this same eg_V signal, when the two are
    // combined at "REGISTER/CYCLE 2" in that file).
    output          [ 9:0] dbg_eg_V,
    output                  dbg_ch0car_valid,

    // 2026-08-19, task #8 round 43: diagnostic-only pass-through -- see
    // jtopl_eg.v's port declaration comment for the full reasoning.
    output          [14:0] dbg_eg_cnt,

    // 2026-08-19, task #8 round 44: diagnostic-only pass-through, plus a
    // NEW undelayed channel-0-carrier-valid signal (distinct from
    // dbg_ch0car_valid above, which is deliberately delayed 3 cycles to
    // match eg_V/eg_atten_II's later validity) -- keyon_now_I is a
    // "stage I" signal, valid on the SAME cycle as the raw group/subslot,
    // so no delay is needed here. See jtopl_eg.v's port comment.
    output                  dbg_keyon_now_I,
    output                  dbg_ch0car_valid_I,

    // 2026-08-19, task #8 round 48: plain wire pass-throughs only, no new
    // registers in this file this time. See jtopl_eg.v's port comment.
    output                  dbg_sum_up_II,
    output                  dbg_cenop,

    // 2026-08-19, task #8 round 49: plain pass-through. See jtopl_eg.v's
    // port comment.
    output      [9:0]       dbg_eg_in_I,

    // 2026-08-19, task #8 round 51: plain pass-through. See jtopl_eg.v's
    // port comment.
    output                  dbg_step_II,

    // 2026-08-19, task #8 round 52: plain pass-through. See jtopl_eg.v's
    // port comment.
    output      [2:0]       dbg_state_in_I,

    // 2026-08-19, task #8 round 53: plain pass-through. See jtopl_eg.v's
    // port comment.
    output                  dbg_attack_II,

    // 2026-08-19, task #8 round 55: plain pass-through. See jtopl_eg.v's
    // port comment.
    output                  dbg_joint_hit_II,

    // 2026-08-20, task #8 round 63: plain pass-through. See jtopl_eg.v's
    // port comment.
    output                  dbg_joint_hit_III,

    // 2026-08-20, task #8 round 68 follow-up: plain pass-through. See
    // jtopl_eg.v's port comment.
    output      [3:0]       dbg_arate_I,
    output      [5:0]       dbg_rate_II,

    // 2026-08-20, task #8 round 79: see jtopl_reg.v's identical port
    // comment for the full reasoning.
    output                  dbg_ar_dr_applied_ch0car,
    output                  dbg_up_ar_dr_raw,
    output                  dbg_ar_dr_clobbered,
    output                  dbg_pending_was_ch0car,

    // 2026-08-22, task #8 round 115: channel 4's own carrier valid gate,
    // mirroring dbg_ch0car_valid_I above exactly but for channel 4
    // (group=1, subslot=4 -- channel 4: group=ch/3=1, sub=ch%3=1, carrier
    // offset=sub+3=4, matching this file's own {group,subslot} addressing
    // convention). Round 114 confirmed channel 4's SL/RR register genuinely
    // holds RR=0, and a real-MAME cross-check proved this exact note
    // decays cleanly on correct hardware -- so this taps channel 4's own
    // internal state/keycode/ksr (alongside the already-exposed
    // dbg_state_in_I/dbg_rate_II, shared "stage I"/"stage II" signals valid
    // for whichever slot this gate identifies) to find where this core's
    // computation diverges from correct behavior.
    output                  dbg_ch4car_valid_I,
    output      [3:0]       dbg_keycode_II,
    output                  dbg_ksr_II,

    // 2026-08-22, task #8 round 121: general-purpose carrier-operator
    // identification, generalizing dbg_ch0car_valid/dbg_ch4car_valid_I to
    // ALL 9 real channels at once instead of one hardcoded channel each.
    // Round 120's ROM patch was hardware-verified (via the existing
    // stuck_channel_sl_rr_snapshot readback) to genuinely reach channel 4's
    // carrier RR register (confirmed reading 0x0F, max release rate) and to
    // genuinely drive channel 4's own live rate/state (dbg_rate_II=63,
    // dbg_state_in_I=RELEASE) -- yet the real hardware hang got LONGER
    // (10.5s+, directly measured via a live-updating duration counter), not
    // shorter. A note releasing at the fastest possible OPL2 rate cannot
    // legitimately still be audible 10+ seconds later, so channel 4 is
    // very unlikely to be the actual source; round 113's "last channel to
    // go key-off" snapshot heuristic can easily misattribute the real
    // culprit to whichever channel simply happened to go silent around the
    // same moment. dbg_car_ch_valid/dbg_car_ch_num let the integrating file
    // read EVERY channel's own carrier attenuation (dbg_eg_V) directly and
    // independently, using the exact same dbg_loc_d 3-stage-delayed
    // {group,subslot} this file already computes for dbg_ch0car_valid
    // (see u_dbg_locdelay below) -- subslot>=3 identifies a carrier
    // (subslots 0-2 are the group's 3 modulators, 3-5 its 3 carriers, per
    // this file's own existing group=ch/3, sub=ch%3(+3 for carrier)
    // addressing convention, already independently confirmed via
    // jtopl_mmr.v's real register-decode logic), and
    // group*3+(subslot-3) recovers the real channel number 0-8.
    output                  dbg_car_ch_valid,
    output      [3:0]       dbg_car_ch_num,

    // 2026-08-24, task #8 round 144: channels 7/8's own carrier valid
    // gates, mirroring dbg_ch0car_valid_I/dbg_ch4car_valid_I above
    // exactly (group=ch/3, subslot=ch%3+3). Round 143's own live raw
    // eg_V readout found both channels repeatedly parking at a specific,
    // recurring mid-scale attenuation (96 for ch7, ~504 for ch8) instead
    // of decaying to full silence -- these gates let the integrating
    // file tap each channel's own internal envelope state/rate/keycode
    // (the same "stage I"/"stage II" signals dbg_ch0car_valid_I/
    // dbg_ch4car_valid_I already expose) to find the exact rate/keycode
    // bucket responsible, the same methodology that found round 68's
    // original AR=15 fix. NOT using the general-purpose, 3-stage-delayed
    // dbg_car_ch_valid/dbg_car_ch_num above for this -- that pair is
    // deliberately delayed to align with dbg_eg_V's own pipeline latency,
    // while dbg_state_in_I is an undelayed "stage I" signal; gating it on
    // the delayed valid would read state from the wrong cycle. A fresh,
    // undelayed per-channel gate (exactly like ch0/ch4's) is the correct,
    // safe way to stay aligned with dbg_state_in_I.
    output                  dbg_ch7car_valid_I,
    output                  dbg_ch8car_valid_I
);

parameter OPL_TYPE=1;

wire          cenop;
wire          write;
wire  [ 1:0]  group;
wire  [17:0]  slot;
wire  [ 3:0]  trem;
wire  [ 2:0]  subslot; // 2026-08-19, task #8 round 40: diagnostic use only

// Timers
wire          flag_A, flag_B, flagen_A, flagen_B;
wire  [ 7:0]  value_A;
wire  [ 7:0]  value_B;
wire          load_A, load_B;
wire          clr_flag_A, clr_flag_B;
wire          overflow_A;
wire          zero; // Single-clock pulse at the begginig of s1_enters

// Phase
wire  [ 9:0]  fnum_I;
wire  [ 2:0]  block_I;
wire  [ 3:0]  mul_II;
wire  [ 9:0]  phase_IV;
wire          pg_rst_II;
wire          viben_I;
wire  [ 2:0]  vib_cnt;
// envelope configuration
wire          en_sus_I; // enable sustain
wire  [ 3:0]  keycode_II;
wire  [ 3:0]  arate_I; // attack  rate
wire  [ 3:0]  drate_I; // decay   rate
wire  [ 3:0]  rrate_I; // release rate
wire  [ 3:0]  sl_I;   // sustain level
wire          ksr_II;    // key scale rate - affects rates
wire  [ 1:0]  ksl_IV;   // key scale level - affects amplitude
// envelope operation
wire          keyon_I;
wire          eg_stop;
// envelope number
wire          amen_IV;
wire  [ 5:0]  tl_IV;
wire  [ 9:0]  eg_V;
// Global values
wire          am_dep, vib_dep, rhy_en;
// Operator
wire  [ 2:0]  fb_I;
wire  [ 1:0]  wavsel_I;
wire          op, con_I, op_out, con_out;

wire signed [12:0] op_result;

assign          write   = !cs_n && !wr_n;
assign          dout    = { ~irq_n, flag_A, flag_B, 5'd6 };
assign          eg_stop = 0;
assign          sample  = zero;

jtopl_mmr #(.OPL_TYPE(OPL_TYPE)) u_mmr(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( cen           ),  // external clock enable
    .cenop      ( cenop         ),  // internal clock enable
    .din        ( din           ),
    .write      ( write         ),
    .addr       ( addr          ),
    .zero       ( zero          ),
    .group      ( group         ),
    .op         ( op            ),
    .slot       ( slot          ),
    .subslot    ( subslot       ),
    .rhy_en     ( rhy_en        ),
    // Timers
    .value_A    ( value_A       ),
    .value_B    ( value_B       ),
    .load_A     ( load_A        ),
    .load_B     ( load_B        ),
    .flagen_A   ( flagen_A      ),
    .flagen_B   ( flagen_B      ),
    .clr_flag_A ( clr_flag_A    ),
    .clr_flag_B ( clr_flag_B    ),
    .flag_A     ( flag_A        ),
    .overflow_A ( overflow_A    ),
    // Phase Generator
    .fnum_I     ( fnum_I        ),
    .block_I    ( block_I       ),
    .mul_II     ( mul_II        ),
    // Operator
    .wavsel_I   ( wavsel_I      ),
    // Envelope Generator
    .keyon_I    ( keyon_I       ),
    .en_sus_I   ( en_sus_I      ),
    .arate_I    ( arate_I       ),
    .drate_I    ( drate_I       ),
    .rrate_I    ( rrate_I       ),
    .sl_I       ( sl_I          ),
    .ks_II      ( ksr_II        ),
    .tl_IV      ( tl_IV         ),
    .ksl_IV     ( ksl_IV        ),
    .amen_IV    ( amen_IV       ),
    .viben_I    ( viben_I       ),
    // Global Values
    .am_dep     ( am_dep        ),
    .vib_dep    ( vib_dep       ),
    // Timbre
    .fb_I       ( fb_I          ),
    .con_I      ( con_I         ),
    .dbg_ar_dr_applied_ch0car ( dbg_ar_dr_applied_ch0car ),
    .dbg_up_ar_dr_raw ( dbg_up_ar_dr_raw ),
    .dbg_ar_dr_clobbered ( dbg_ar_dr_clobbered ),
    .dbg_pending_was_ch0car ( dbg_pending_was_ch0car )
);

jtopl_timers u_timers(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cenop      ( cenop         ),
    .zero       ( zero          ),
    .value_A    ( value_A       ),
    .value_B    ( value_B       ),
    .load_A     ( load_A        ),
    .load_B     ( load_B        ),
    .flagen_A   ( flagen_A      ),
    .flagen_B   ( flagen_B      ),
    .clr_flag_A ( clr_flag_A    ),
    .clr_flag_B ( clr_flag_B    ),
    .flag_A     ( flag_A        ),
    .flag_B     ( flag_B        ),
    .overflow_A ( overflow_A    ),
    .irq_n      ( irq_n         )
);

jtopl_lfo u_lfo(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cenop      ( cenop         ),
    .slot       ( slot          ),
    .vib_cnt    ( vib_cnt       ),
    .trem       ( trem          )
);

jtopl_pg u_pg(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cenop      ( cenop         ),
    .slot       ( slot          ),
    .rhy_en     ( rhy_en        ),
    // Channel frequency
    .fnum_I     ( fnum_I        ),
    .block_I    ( block_I       ),
    // Operator multiplying
    .mul_II     ( mul_II        ),
    // phase modulation from LFO (vibrato at 6.4Hz)
    .vib_cnt    ( vib_cnt       ),
    .vib_dep    ( vib_dep       ),
    .viben_I    ( viben_I       ),
    // phase operation
    .pg_rst_II  ( pg_rst_II     ),
    
    .keycode_II ( keycode_II    ),
    .phase_IV   ( phase_IV      )
);

jtopl_eg u_eg(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cenop      ( cenop         ),
    .zero       ( zero          ),
    .eg_stop    ( eg_stop       ),
    // envelope configuration
    .en_sus_I   ( en_sus_I      ), // enable sustain
    .keycode_II ( keycode_II    ),
    .arate_I    ( arate_I       ), // attack  rate
    .drate_I    ( drate_I       ), // decay   rate
    .rrate_I    ( rrate_I       ), // release rate
    .sl_I       ( sl_I          ), // sustain level
    .ksr_II     ( ksr_II        ), // key scale
    // envelope operation
    .keyon_I    ( keyon_I       ),
    // envelope number
    .fnum_I     ( fnum_I        ),
    .block_I    ( block_I       ),
    .lfo_mod    ( trem          ),
    .amsen_IV   ( amen_IV       ),
    .ams_IV     ( am_dep        ),
    .tl_IV      ( tl_IV         ),
    .ksl_IV     ( ksl_IV        ),
    .eg_V       ( eg_V          ),
    .pg_rst_II  ( pg_rst_II     ),
    .dbg_eg_cnt ( dbg_eg_cnt    ),
    .dbg_keyon_now_I ( dbg_keyon_now_I ),
    .dbg_sum_up_II   ( dbg_sum_up_II   ),
    .dbg_eg_in_I     ( dbg_eg_in_I     ),
    .dbg_step_II     ( dbg_step_II     ),
    .dbg_state_in_I  ( dbg_state_in_I  ),
    .dbg_attack_II   ( dbg_attack_II   ),
    .dbg_joint_hit_II( dbg_joint_hit_II),
    .dbg_joint_hit_III( dbg_joint_hit_III),
    .dbg_arate_I     ( dbg_arate_I     ),
    .dbg_rate_II     ( dbg_rate_II     ),
    .dbg_keycode_II  ( dbg_keycode_II  ),
    .dbg_ksr_II      ( dbg_ksr_II      )
);
assign dbg_ch0car_valid_I = (group == 2'd0) && (subslot == 3'd3);
assign dbg_ch4car_valid_I = (group == 2'd1) && (subslot == 3'd4);
assign dbg_ch7car_valid_I = (group == 2'd2) && (subslot == 3'd4);
assign dbg_ch8car_valid_I = (group == 2'd2) && (subslot == 3'd5);
assign dbg_cenop = cenop;

jtopl_op #(.OPL_TYPE(OPL_TYPE)) u_op(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cenop      ( cenop         ),

    // location of current operator
    .group      ( group         ),
    .op         ( op            ),
    .zero       ( zero          ),

    .pg_phase_I ( phase_IV      ),
    .eg_atten_II( eg_V          ), // output from envelope generator
    .fb_I       ( fb_I          ), // voice feedback
    .wavsel_I   ( wavsel_I      ), // sine mask (OPL2)
    
    .con_I      ( con_I         ),
    .op_result  ( op_result     ),
    .op_out     ( op_out        ),
    .con_out    ( con_out       )
);

// 2026-08-19, task #8 round 40: 3-stage delay matching jtopl_op.v's own
// u_delay (identical stages=3, same cenop), applied to {group,subslot}
// captured at the SAME time as this cycle's eg_V request, so that once
// eg_V (=eg_atten_II) emerges 3 cycles later, dbg_group_d/dbg_subslot_d
// correctly identify which operator it belongs to. See the port
// declaration comment above for the full reasoning.
wire [4:0] dbg_loc_d;
jtopl_sh #( .width(5), .stages(3)) u_dbg_locdelay(
    .clk    ( clk                       ),
    .cen    ( cenop                     ),
    .din    ( { group, subslot }       ),
    .drop   ( dbg_loc_d                 )
);
assign dbg_eg_V          = eg_V;
assign dbg_ch0car_valid  = (dbg_loc_d[4:3] == 2'd0) && (dbg_loc_d[2:0] == 3'd3);
// 2026-08-22, task #8 round 121: see port declaration comment above.
assign dbg_car_ch_valid  = (dbg_loc_d[2:0] >= 3'd3);
assign dbg_car_ch_num    = ({2'b0, dbg_loc_d[4:3]} * 4'd3) + ({1'b0, dbg_loc_d[2:0]} - 4'd3);

jtopl_acc u_acc(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .slot       ( slot          ),
    .rhy_en     ( rhy_en        ),
    .cenop      ( cenop         ),
    .zero       ( zero          ),
    .op_result  ( op_result     ),
    .op         ( op_out        ),
    .con        ( con_out       ),
    .snd        ( snd           )
);

`ifdef SIMULATION
integer fsnd;
initial begin
    fsnd=$fopen("jtopl.raw","wb");
end

always @(posedge zero) begin
    $fwrite(fsnd,"%u", {snd, snd});
end
`endif

endmodule
    