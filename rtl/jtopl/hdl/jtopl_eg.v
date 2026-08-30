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
    Date: 17-6-2020

    */

module jtopl_eg (
    input               rst,
    input               clk,
    input               cenop,
    input               zero,
    input               eg_stop,
    // envelope configuration
    input               en_sus_I, // enable sustain
    input       [3:0]   keycode_II,
    input       [3:0]   arate_I, // attack  rate
    input       [3:0]   drate_I, // decay   rate
    input       [3:0]   rrate_I, // release rate
    input       [3:0]   sl_I,   // sustain level
    input               ksr_II,     // key scale
    // envelope operation
    input               keyon_I,
    // envelope number
    input       [9:0]   fnum_I,
    input       [2:0]   block_I,
    input       [3:0]   lfo_mod,
    input               amsen_IV,
    input               ams_IV,
    input       [5:0]   tl_IV,
    input       [1:0]   ksl_IV,

    output  reg [9:0]   eg_V,
    output  reg         pg_rst_II,

    // 2026-08-19, task #8 round 43: diagnostic-only tap on the shared
    // global envelope timebase (eg_cnt is not per-slot -- it's one
    // counter shared by all 18 slots), added after round 40/41 confirmed
    // channel 0's carrier envelope is completely frozen on real hardware
    // and round 42 ruled out an incomplete post-boot reset as the cause.
    // jtopl_eg_step.v's rate-to-step logic (which reads eg_cnt) is pure
    // combinational logic with no state of its own, so it's very unlikely
    // to behave differently between simulation and real synthesized
    // hardware given correct inputs -- making eg_cnt itself, upstream of
    // every channel's envelope alike, the more foundational and far
    // simpler thing to verify directly (no per-slot delay-matching
    // needed at all, unlike round 40's eg_V tap).
    output      [14:0] dbg_eg_cnt,

    // 2026-08-19, task #8 round 44: round 43 confirmed the shared global
    // envelope timebase genuinely advances on real hardware, narrowing
    // the frozen-envelope mystery (rounds 40/41) to something specific to
    // channel 0's carrier's own per-slot machinery. This taps the actual
    // internal Key-On edge-detect pulse (keyon_now_I = !keyon_last_I &&
    // keyon_I) that triggers the ATTACK state transition in
    // jtopl_eg_ctrl.v -- if this never fires for this slot despite the
    // real bus-level Key-On write being independently confirmed received
    // (keyon_I itself), the per-slot keyon_last_I storage (an 18-stage
    // jtopl_sh_rst chain, u_konsh) would be the culprit. Both keyon_now_I
    // and keyon_I/keyon_last_I are "stage I" signals, matching the same
    // raw undelayed group/subslot as dbg_eg_cnt -- no delay-matching
    // needed, same as round 43.
    output              dbg_keyon_now_I,

    // 2026-08-19, task #8 round 48: retry of the sum_up_II question
    // (rounds 45/46 both caused a real, reproducible hardware regression
    // via a NEW REGISTER added inside jtopl.v -- see debugging_log.md).
    // This time, only a plain wire tap is added here (no new register in
    // ANY vendor file); the 1-cycle delay this needs is built entirely
    // in battlantis_sound.v instead, isolating whether "a new register
    // inside the vendor's jtopl.v specifically" was the actual cause.
    output              dbg_sum_up_II,

    // 2026-08-19, task #8 round 49: round 48 confirmed sum_up_II
    // genuinely fires for channel 0's carrier, isolating the fault to
    // the u_egsh persistent-storage write-back itself. This taps eg_in_I
    // directly -- the RAW persistent value (distinct from eg_V/eg_out_IV,
    // which has TL/KSL modulation applied on top) -- to confirm directly,
    // rather than infer, whether the actual storage ever updates. A
    // plain wire tap on an already-existing wire, zero new registers,
    // matching round 48's proven-safe pattern. eg_in_I is a "stage I"
    // signal (same timing as keyon_I), needing no delay at all.
    output      [9:0]   dbg_eg_in_I,

    // 2026-08-19, task #8 round 51: round 50's storage-replacement fix
    // had NO effect (eg_in_I still never changes even with a completely
    // different storage implementation) despite sum_up_II confirmed
    // firing (round 48) -- ruling out the storage write-back itself.
    // Realized jtopl_eg_pure.v's actual step MAGNITUDE (ar_sum/dr_sum)
    // depends on a SEPARATE signal, `step` (step_II here), not just
    // `sum_up` -- if step happens to be 0 every time sum_up fires, the
    // computed "update" is zero change every time, exactly matching the
    // symptom, with nothing wrong in the storage at all. step_II was
    // never directly checked. Same "stage II" timing as sum_up_II --
    // reuses the identical delay logic already built in
    // battlantis_sound.v for that check.
    output              dbg_step_II,

    // 2026-08-19, task #8 round 52: direct tap on state_in_I -- see the
    // u_egstate instantiation comment below for the full reasoning
    // (Gemini's theory: if this never persists as ATTACK, every cycle
    // falls through to RELEASE, explaining the frozen envelope
    // independent of sum_up_II/step_II both genuinely firing). A plain
    // wire tap, zero new registers. "Stage I" timing (same as keyon_I),
    // reuses the existing undelayed ym1_dbg_ch0car_valid_I directly.
    output      [2:0]   dbg_state_in_I,

    // 2026-08-19, task #8 round 53: round 52 found state_in_I DOES reach
    // ATTACK at least once (refuting Gemini's strongest theory), yet
    // eg_in_I still never changes. Realized the three separate "ever"
    // checks (state=ATTACK, sum_up_II, step_II) each only prove their
    // own condition happened AT SOME POINT -- never that all three
    // happened on the SAME cycle. attack_II is already registered at
    // the exact same "stage II" pipeline timing as sum_up_II/step_II
    // (attack_II <= state_next_I[0], same always block, same clock
    // edge) -- tapping it directly gives a decisive joint-condition
    // check with no new delay logic needed.
    output              dbg_attack_II,

    // 2026-08-19, task #8 round 55: real, registered version of round 53's
    // joint check -- see the always block below (joint_hit_II) for the
    // full reasoning. User explicitly authorized this real, functional
    // addition to vendor RTL after round 54's simulation positive control.
    output              dbg_joint_hit_II,

    // 2026-08-20, task #8 round 63: a more decisive version of the joint
    // check. Round 55's joint_hit_II mixes one real register (attack_II)
    // with two purely combinational wires (step_II/sum_out_II) computed in
    // the SAME cycle before being re-registered -- this instead taps
    // attack_III/step_III/sum_in_III, which are already fully registered
    // "stage III" signals (set in the same always block below) AND are the
    // exact, direct inputs jtopl_eg_pure.v's real arithmetic uses (see its
    // .attack/.step/.sum_up ports via jtopl_eg_comb's pure_attack/pure_step/
    // sum_up_in). A plain wire, zero new registers -- same safe pattern as
    // rounds 48/49/51/52/53. Valid at the same "stage III" timing as
    // dbg_joint_hit_II (both are simple functions of stage-III registers),
    // so the existing round-55 delayed valid gate can be reused unchanged.
    output              dbg_joint_hit_III,

    // 2026-08-20, task #8 round 68 follow-up: round 68's jtopl_eg_step.v
    // fix (forcing sum_up=1 during max_attack_case) did not change AR=15's
    // behavior on real hardware at all -- direct evidence the hand-derived
    // parameters (arate_I=15 -> rate[5:2]==4'hf) may not actually hold in
    // real hardware, or something else entirely is happening. Plain wire
    // taps on the two signals the whole derivation rests on, zero new
    // registers, so this can be checked directly instead of re-deriving by
    // hand again.
    output      [3:0]   dbg_arate_I,
    output      [5:0]   dbg_rate_II,

    // 2026-08-22, task #8 round 115: round 114 confirmed channel 4's
    // carrier SL/RR register genuinely holds RR=0, and a real-MAME
    // cross-check on the same title->stage transition proved that note
    // decays cleanly in ~1.2s on correct/reference hardware -- so the hang
    // is a genuine core defect, not authentic RR=0 behavior (jtopl_eg_ctrl.v's
    // base_rate={rrate,1'b1} means RR=0 still yields a finite base_rate=1,
    // not zero). These two extra raw stage-II taps, alongside the existing
    // dbg_state_in_I/dbg_rate_II, let a dedicated channel-4 gate (see
    // jtopl.v) determine whether this core's actually-computed rate/keycode
    // for channel 4 diverges from what a correct decay would need.
    output      [3:0]   dbg_keycode_II,
    output               dbg_ksr_II
);

parameter SLOTS=18;

wire [14:0] eg_cnt;

jtopl_eg_cnt u_egcnt(
    .rst    ( rst   ),
    .clk    ( clk   ),
    .cen    ( cenop & ~eg_stop ),
    .zero   ( zero  ),
    .eg_cnt ( eg_cnt)
);

wire keyon_last_I;
wire keyon_now_I  = !keyon_last_I && keyon_I;
wire keyoff_now_I = keyon_last_I && !keyon_I;

wire cnt_in_II, cnt_lsb_II, step_II, pg_rst_I;

wire [2:0] state_in_I, state_next_I;

// 2026-08-20, task #8 round 64: `preserve` on these four registers only
// (attack_II/attack_III/step_III/sum_in_III -- the exact signals rounds 53/
// 55/63 proved never coincide in this synthesis despite being provably
// correct in ModelSim). Quartus's own compile log reports it creating
// register duplicates during synthesis ("Created 190 register duplicates");
// if any of these four were duplicated, different consumers (e.g. the
// joint-condition check vs. whatever else reads the same logical signal)
// could end up reading different physical copies that briefly disagree --
// a real, concrete mechanism for "provably coincident in RTL/sim, never
// observed to coincide in this exact synthesis." `preserve` is a pure
// synthesis-only attribute: it cannot change functional behavior or
// timing/latency, only prevent Quartus from merging/duplicating/optimizing
// away these specific registers -- zero risk of a new correctness
// regression, unlike a genuine pipeline-depth restructure (which would need
// resizing every shift-register stage count across all 18 time-multiplexed
// slots to stay aligned; not attempted this round given that risk).
(* preserve *) reg attack_II;
(* preserve *) reg attack_III;
wire [4:0] base_rate_I;
reg  [4:0] base_rate_II;
wire  [5:0] rate_out_II;
reg  [5:1] rate_in_III;
(* preserve *) reg step_III;
wire sum_out_II;
(* preserve *) reg sum_in_III;

wire [9:0] eg_in_I, pure_eg_out_III, eg_next_III, eg_out_IV;
reg  [9:0] eg_in_II, eg_in_III, eg_in_IV;
reg  [3:0] keycode_III, keycode_IV;
reg joint_hit_II; // 2026-08-19, task #8 round 55 -- see always block below

// 2026-08-19, task #8 rounds 40-53: diagnostic-only pass-throughs, moved
// here (below all referenced declarations) round 54 -- Quartus tolerated
// the original forward-reference ordering, but ModelSim's vlog does not
// (implicit-net vs. later `reg`/initialized-`wire` declaration conflicts).
// Pure reordering of already-added debug assigns, no functional change.
assign dbg_eg_cnt      = eg_cnt;
assign dbg_keyon_now_I = keyon_now_I;
assign dbg_sum_up_II   = sum_out_II;
assign dbg_eg_in_I     = eg_in_I;
assign dbg_step_II     = step_II;
assign dbg_state_in_I  = state_in_I;
assign dbg_attack_II   = attack_II;
assign dbg_joint_hit_II = joint_hit_II;
// 2026-08-20, task #8 round 63: see the port declaration comment above.
wire joint_hit_III = attack_III && step_III && sum_in_III;
assign dbg_joint_hit_III = joint_hit_III;
assign dbg_arate_I = arate_I;
assign dbg_rate_II = rate_out_II;
assign dbg_keycode_II = keycode_II;
assign dbg_ksr_II = ksr_II;
wire [3:0] fnum_IV;
wire [2:0] block_IV;


jtopl_eg_comb u_comb(
    ///////////////////////////////////
    // I
    .keyon_now      ( keyon_now_I   ),
    .keyoff_now     ( keyoff_now_I  ),
    .state_in       ( state_in_I    ),
    .eg_in          ( eg_in_I       ),
    // envelope configuration
    .en_sus         ( en_sus_I      ),
    .arate          ( arate_I       ), // attack  rate
    .drate          ( drate_I       ), // decay   rate
    .rrate          ( rrate_I       ),
    .sl             ( sl_I          ),   // sustain level

    .base_rate      ( base_rate_I   ),
    .state_next     ( state_next_I  ),
    .pg_rst         ( pg_rst_I      ),
    ///////////////////////////////////
    // II
    .step_attack    ( attack_II     ),
    .step_rate_in   ( base_rate_II  ),
    .keycode        ( keycode_II    ),
    .eg_cnt         ( eg_cnt        ),
    .cnt_in         ( cnt_in_II     ),
    .ksr            ( ksr_II        ),
    .cnt_lsb        ( cnt_lsb_II    ),
    .step           ( step_II       ),
    .step_rate_out  ( rate_out_II   ),
    .sum_up_out     ( sum_out_II    ),
    ///////////////////////////////////
    // III
    .pure_attack    ( attack_III        ),
    .pure_step      ( step_III          ),
    .pure_rate      ( rate_in_III[5:1]  ),
    .pure_eg_in     ( eg_in_III         ),
    .pure_eg_out    ( pure_eg_out_III   ),
    .sum_up_in      ( sum_in_III        ),
    ///////////////////////////////////
    // IV
    .fnum           ( fnum_IV       ),
    .block          ( block_IV      ),
    .lfo_mod        ( lfo_mod       ),
    .amsen          ( amsen_IV      ),
    .ams            ( ams_IV        ),
    .ksl            ( ksl_IV        ),
    .tl             ( tl_IV         ),
    .final_keycode  ( keycode_IV    ),
    .final_eg_in    ( eg_in_IV      ),
    .final_eg_out   ( eg_out_IV     )
);

always @(posedge clk) if(cenop) begin
    eg_in_II    <= eg_in_I;
    attack_II   <= state_next_I[0];
    base_rate_II<= base_rate_I;
    pg_rst_II   <= pg_rst_I;

    // 2026-08-19, task #8 round 55: user-authorized, explicit-sign-off
    // functional addition to this vendor file (per this project's
    // established practice, e.g. the T80.vhd accumulator fix) -- rounds
    // 53/54 established that attack_II && step_II && sum_out_II (all true
    // on the same cycle, for ch0's carrier) is the correct condition for a
    // genuine ATTACK-phase decrement, reads GREEN 64x in ModelSim with the
    // identical source, but RED on real hardware when the 3 raw wires are
    // routed out through jtopl.v/jtopl2.v/battlantis_sound.v and ANDed
    // there. Registering the AND right here, at the exact same stage-II
    // pipeline point these signals are already used at, eliminates that
    // 3-wire/4-module-boundary routing as a possible source of error --
    // this is now the single most decisive real-hardware check this
    // investigation can construct.
    joint_hit_II <= attack_II && step_II && sum_out_II;

    eg_in_III   <= eg_in_II;
    attack_III  <= attack_II;
    rate_in_III <= rate_out_II[5:1];
    step_III    <= step_II;
    sum_in_III  <= sum_out_II;

    eg_in_IV    <= pure_eg_out_III;
    eg_V        <= eg_out_IV;

    keycode_III <= keycode_II;
    keycode_IV  <= keycode_III;
end

jtopl_sh #( .width(1), .stages(SLOTS) ) u_cntsh(
    .clk    ( clk       ),
    .cen    ( cenop     ),
    .din    ( cnt_lsb_II),
    .drop   ( cnt_in_II )
);

jtopl_sh #( .width(4), .stages(3) ) u_fnumsh(
    .clk    ( clk         ),
    .cen    ( cenop       ),
    .din    ( fnum_I[9:6] ),
    .drop   ( fnum_IV     )
);

jtopl_sh #( .width(3), .stages(3) ) u_blocksh(
    .clk    ( clk         ),
    .cen    ( cenop       ),
    .din    ( block_I     ),
    .drop   ( block_IV    )
);

// 2026-08-19, task #8: real-hardware bisection (rounds 30-49) isolated a
// genuine synthesis-specific defect in jtopl_sh_rst.v's per-bit
// shift-register-array implementation at THIS instance's parameters
// (width=10, stages=15) -- the only 10-bit-wide jtopl_sh_rst instance in
// this file; the narrower u_egstate/u_konsh instances below are both
// confirmed working. Swapped to jtopl_sh_rst_ram.v, a RAM-inferred
// reimplementation of the identical functional behavior (same port list,
// same reset timing), to route around the defect. See
// rtl/jtopl/hdl/jtopl_sh_rst_ram.v's own header comment for the full
// derivation.
//
// 2026-08-24, task #8 round 147: real off-by-one found, independently
// verified against the actual RTL (not just taken on a Gemini consult's
// word -- see project_history/TASKS.md round 146/147). jtopl_sh_rst.v's
// `drop` is a combinational read (`stages` cycles total); jtopl_sh_rst_ram.v's
// `drop` is a REGISTERED read (`stages + 1` cycles) -- confirmed directly
// in both files. This instance's own feedback loop (eg_in_I -> eg_in_II ->
// eg_in_III -> [jtopl_eg_pure] -> eg_in_IV -> back into this module's own
// `din`) has exactly 3 additional `cenop`-gated register stages, confirmed
// by direct inspection of the `always @(posedge clk) if(cenop)` block
// below in this same file -- so the delay line itself must contribute
// exactly 15 cycles for the total loop to equal SLOTS=18 (matching the
// original combinational jtopl_sh_rst.v's real, correct pre-round-50
// behavior at stages=15). Since round 50's swap kept `stages=SLOTS-3=15`
// unchanged while switching to a module with one MORE cycle of latency per
// `stages` count, this instance has actually been running a 19-cycle loop
// (16 delay + 3 pipeline) instead of 18 ever since -- a real, confirmed,
// previously-undiscovered parameterization bug, independent of and
// compounding on top of round 52/140's separate speculative swaps below.
// Fixed by reducing `stages` by 1 to compensate for the module's own extra
// latency, restoring the exact original (upstream jtopl2 / Haunted Castle)
// total loop length while keeping the genuinely-needed RAM-based defect
// workaround.
jtopl_sh_rst_ram #( .width(10), .stages(SLOTS-4), .rstval(1'b1) ) u_egsh(
    .clk    ( clk       ),
    .cen    ( cenop     ),
    .rst    ( rst       ),
    .din    ( eg_in_IV  ),
    .drop   ( eg_in_I   )
);

// 2026-08-19, task #8 round 52: round 50's u_egsh swap made no difference
// (eg_in_I still never changed), and round 51 confirmed both sum_up_II
// and step_II genuinely fire -- ruling out the update-decision logic.
// Per Gemini's round-51 theory (independently reasoned as architecturally
// sound: if state_in_I never persists as ATTACK, jtopl_eg_ctrl.v's casez
// falls through to its default case every cycle, forcing RELEASE, which
// recomputes eg_in right back to its own reset value -- a self-consistent
// explanation for "frozen at exactly 10'h3FF despite sum_up/step firing"),
// applying the same already-proven jtopl_sh_rst_ram swap here too, since
// u_egstate was only ever exonerated "by association" with the separately-
// instantiated, narrower u_konsh, never independently tested itself.
//
// 2026-08-24, task #8 round 147: same off-by-one as u_egsh above, for a
// second (independent) reason: jtopl_eg_ctrl.v (which computes
// state_next_I from state_in_I) is confirmed PURELY COMBINATIONAL --
// zero `posedge clk` statements anywhere in that file -- so this
// instance's own loop has ZERO additional pipeline stages, meaning the
// delay line alone must equal exactly SLOTS=18 cycles. jtopl_sh_rst_ram
// at stages=SLOTS=18 actually gives 19 cycles (one too many), for the
// same reason as u_egsh. Fixed identically: reduce `stages` by 1.
jtopl_sh_rst_ram #( .width(3), .stages(SLOTS-1), .rstval(1'b1) ) u_egstate(
    .clk    ( clk           ),
    .cen    ( cenop         ),
    .rst    ( rst           ),
    .din    ( state_next_I  ),
    .drop   ( state_in_I    )
);

// 2026-08-20, task #8 round 74: TESTED AND REVERTED (at the time). Gemini
// review found a real, concrete latency mismatch: jtopl_sh_rst.v's `drop`
// is a combinational read off the shift array (a bit written at cycle c
// reaches drop after `stages-1` clock edges); jtopl_sh_rst_ram.v's `drop`
// is a REGISTERED read of mem[ptr] (the same bit reaches drop after
// `stages` edges -- one cycle later). u_egstate (above) has used
// jtopl_sh_rst_ram at stages=SLOTS since round 52, but u_konsh was never
// brought along -- despite sharing the identical `stages=SLOTS` parameter,
// the two have been genuinely out of phase by one cycle. Round 74 tested
// this exact swap and found no change against THAT round's diagnostics
// (ch0_car_eg_changed/ch0car_eg_in_I_changed, audio_gt256/gt4096) --
// but those predate every ROM-data fix this session has made since
// (rounds 120/130/136) and were never sensitive to channel 0's specific
// symptom.
//
// 2026-08-23, task #8 round 140: RE-TESTING. Math (independently derived
// and cross-checked against jtopl_eg_step.v/jtopl_eg_pure.v's own literal
// rate/step logic) says channel 0's real, live RR=7 carrier register
// should decay to silence in ~0.44s after Key-off; round 139's per-channel
// diagnostic instead shows it staying "audible" continuously for 5+
// seconds (and the rest of a 100s capture) after every Key-off -- a 10x+
// gap that isn't explained by any rate/data value, since the ROM byte
// itself (0x17, SL=1/RR=7) is confirmed identical to real hardware's own
// copy. A real MAME comparison (same stock ROM) confirms real hardware
// reaches complete silence here; ours doesn't -- so this is a genuine
// core defect, not authentic content. This exact keyon_now_I/state_in_I
// phase mismatch is the most concrete, already-documented "something not
// latched in sync with something else" candidate that could explain a
// state machine that never correctly registers a Key-off transition for
// a given slot. Re-testing now that far more precise per-channel
// diagnostics (round 139) exist than round 74 had available.
//
// 2026-08-24, task #8 round 147: same off-by-one as u_egsh/u_egstate
// above. keyon_I is an external, per-cycle live input (this slot's own
// real bus-level Key-On state on THIS visit) with no feedback pipeline of
// its own -- keyon_last_I must simply equal keyon_I from exactly SLOTS=18
// cycles ago. jtopl_sh_rst_ram at stages=SLOTS=18 gives 19 cycles instead,
// meaning keyon_last_I has actually been reading a neighboring slot's
// key-on history, not this slot's own -- directly corrupting
// keyon_now_I's edge-detect for this exact slot. Fixed identically:
// reduce `stages` by 1.
jtopl_sh_rst_ram #( .width(1), .stages(SLOTS-1), .rstval(1'b0) ) u_konsh(
    .clk    ( clk           ),
    .cen    ( cenop         ),
    .rst    ( rst           ),
    .din    ( keyon_I       ),
    .drop   ( keyon_last_I  )
);


endmodule // jtopl_eg