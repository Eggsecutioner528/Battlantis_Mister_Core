//============================================================================
//  Battlantis Audio Subsystem
//  Z80 CPU @ 3.579 MHz + 2x YM3812 (OPL2) FM Synthesisers
//============================================================================

module battlantis_sound (
	input         clk,          // System Clock (e.g. 24 MHz or 48 MHz)
	input         rst,          // System Reset
	input         ce_z80,       // Z80 Clock Enable (4.0 MHz, matches MAME's 24_MHz_XTAL/6)
	input         ce_ym3812,    // YM3812 Clock Enable (3.0 MHz, matches MAME's 24_MHz_XTAL/8 -- independent of ce_z80)

	// Communication with Main 6809 CPU
	input   [7:0] snd_latch,    // Sound command latch byte (from 0x2E14 write)
	input         snd_irq,      // Sound IRQ trigger pulse (from 0x2E18 write)
	
	// Sound ROM loading interface (IOCTL: 0x18000 - 0x1FFFF)
	input  [14:0] ioctl_sound_addr,
	input   [7:0] ioctl_sound_data,
	input         ioctl_sound_we,
	
	// Audio Output
	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	// Debug observability (2026-08-16, task #8 sound-chain isolation) -- raw
	// combinational pulses, latched into sticky diagnostics on the top level
	output        z80_fetching,  // Z80 is reading an opcode/operand from memory
	output        irq_ack,       // Z80 acknowledged the sound-command interrupt
	output        ym_written,    // Z80 wrote a register to either YM3812
	output        z80_halted,    // Z80 executed HALT (idling, typically waiting for an interrupt)

	// PC-reached checks (2026-08-17), from hand-disassembling the real sound
	// ROM (extra/battlnts/777_c01.10a): 0x0364 is the `EI` instruction on
	// the ROM-checksum-passed success path; 0x02BE is the entry point of
	// the handler taken if the self-checksum (summed 0x0000-0x7FFF,
	// expected 0xFB9B, confirmed the actual ROM file matches exactly)
	// fails. Neither is ever reached (both read false on real hardware) --
	// narrowing further with three loop-EXIT checkpoints (not loop entries,
	// which would trigger even on normal linear progression and couldn't
	// distinguish "passed through" from "stuck looping here"): the
	// instruction right after each of the three loops the startup code
	// runs in sequence -- a short delay loop, a RAM test loop (0x8000-
	// 0x83FF), and the ROM-checksum accumulation loop.
	output        pc_hit_ei_364,
	output        pc_hit_csumfail_2be,
	// 2026-08-19, task #8 round 47: re-adds pc_hit_0038 (originally added
	// round 1-2 to test the disproven "garbage-execution loop" theory,
	// retired round 17 as "long confirmed RED/expected"). Revisiting with
	// fresh reasoning at the user's prompt: MAME's real battlnts_mame.cpp
	// driver shows the main CPU's sh_irqtrigger_w explicitly triggers the
	// sound Z80's regular maskable interrupt (set_input_line(0,...), "Z80
	// IM1") -- confirmed the real ROM's first instruction genuinely is
	// `ED 56` (IM 1), and T80.vhd's own interrupt-acceptance logic (IStatus
	// = "01") forces IR<=8'hFF (RST 38h) on every accepted interrupt, the
	// correct real Z80 IM1 response. Given irq_ack_ever is independently
	// confirmed GREEN (interrupts genuinely get accepted), PC should
	// therefore genuinely visit 0x0038 every time -- round 17's RED
	// reading was never rigorously reconciled with this, just noted as
	// "no longer meaningful" without being re-tested after later fixes.
	output        pc_hit_0038,
	output        pc_past_delay_loop,    // 0x02F9, right after the short delay loop
	output        pc_past_ramtest_loop,  // 0x0311, right after the RAM test loop
	output        pc_past_checksum_loop, // 0x0322, right after the checksum accumulation loop

	// 2026-08-17, Gemini consult: none of the 5 checks above firing while
	// ym_written_ever/z80_fetching_ever DO fire is a real contradiction --
	// every code path in this ROM that reaches a YM3812 write is gated
	// behind pc_past_checksum_loop (0x0322) firing first, so ym_written_ever
	// = GREEN with pc_past_checksum_loop = RED shouldn't be possible if the
	// CPU is executing this ROM's real, correct instruction stream. Leading
	// hypothesis (reset-timing race independently ruled out -- Battlantis.sv
	// line ~692 `reset = sys_reset | ioctl_download` already holds the Z80
	// in reset for the whole download, so it can't start on a still-loading
	// ROM): the CPU is executing garbage bytes near the reset vector for
	// some other reason, trapped in a RST 38h (0xFF) loop at 0x0038, with
	// the stack pointer sweeping downward through 0xA000-0xA001/0xC000-0xC001
	// on each PUSH -- which would trip ym1_cs/ym2_cs && !n_wr without any
	// real intended YM3812 write. These two checks empirically test that
	// (both since retired -- see round 17/18 notes near the port list's
	// tail -- after both came back GREEN/refuted, per the project's
	// diagnostic-overlay-retirement discipline).

	// 2026-08-17, real-hardware readback: both checks above came back GREEN
	// (never hit) -- refutes the RST-38h/garbage-execution theory. The CPU's
	// opcode fetches stay entirely within valid ROM bounds and never touch
	// the interrupt vector, yet still never reach any of the 5 real boot
	// checkpoints, and ym_written_ever still reads GREEN. Next question:
	// does execution even START at the real reset vector? T80.vhd confirms
	// PC synchronously resets to 0x0000 on RESET_n='0' (no core-level bug
	// found there), but that's unconfirmed on real silicon. These two
	// checks disambiguate "never fetches address 0x0000 at all" from
	// "fetches address 0x0000 but the ROM byte there is wrong" (Gemini's
	// proposal) -- the real first byte at 0x0000 is confirmed 0xED (the
	// first byte of the `IM 1` instruction) via the z80dis disassembly.
	output        pc_hit_0000,            // unconditional: 0x0000 is being opcode-fetched right now
	output        pc_hit_0000_wrong_data, // fetched 0x0000 but z80_din wasn't the real ROM byte (0xED)

	// 2026-08-17, round 2 result: pc_hit_0000=GREEN and wrong_data=GREEN --
	// the CPU genuinely boots correctly with correct ROM data at 0x0000.
	// The span 0x0000-0x02F9 (IM1/LD SP/clear 2048 bytes of work RAM in a
	// loop at 0x000A-0x000F/JP 0x02F0/a fixed 4-iteration ALU delay loop)
	// has no data dependency except the two loops' own exit conditions,
	// both deterministic given correct CPU execution -- yet 0x02F9 still
	// never fires. Gemini's "runaway data pointer" theory: if the
	// RAM-clear loop's exit condition (CP 0x88 / JR NZ) never becomes
	// true, HL sweeps unboundedly through the full 64K address space via
	// LD (HL),B / INC HL, eventually writing through 0xA000/0xC000 (the
	// YM3812 ranges) while the PC itself never leaves the loop's own
	// 0x000A-0x000F footprint -- this would explain ym_written_ever=GREEN
	// alongside every PC checkpoint reading RED, all at once. This checks
	// the loop's unconditional exit jump directly.
	// (pc_hit_0011 retired 2026-08-18, round 20 -- long confirmed GREEN
	// since the T80 fix, and subsumed by boot_chain_corrupted's broader
	// byte-range check, also since retired -- see round 20's note near
	// ch0_ar_zero_at_keyon's port declaration for the freed slot.)

	// 2026-08-17, round 3 result: pc_hit_0011 = RED. CONFIRMED: the CPU is
	// permanently trapped in the RAM-clear loop (0x000A-0x000F) and never
	// exits. Root cause of task #8's silence at a high level: the sound
	// Z80 never leaves this boot-time loop. Now isolating WHY the loop's
	// `CP 0x88`/`JR NZ` exit condition (0x000D-0x0010) never becomes true.
	// Gemini's reasoning: since the loop is stable (PC only ever seen at
	// 0x000A-0x000F, never elsewhere, never out-of-bounds, never at the
	// interrupt vector), the CP opcode byte itself is almost certainly
	// being decoded correctly as a 2-byte instruction -- a corrupted
	// opcode byte would very likely decode as something else entirely and
	// derail the loop, which isn't observed. The more likely culprit is
	// the operand byte at 0x000E (the immediate value 0x88 being compared
	// against) being read wrong specifically for this non-M1 operand
	// fetch. Matches the same disambiguation pattern already used at
	// 0x0000 (separate "was this address ever read at all" from "was the
	// data wrong when it was"), broadened from z80_opcode_fetch to a
	// general memory-read condition since operand bytes aren't M1 cycles.
	// (pc_hit_000e retired 2026-08-18, round 22 -- long confirmed GREEN,
	// boot chain fully exonerated since the T80 fix -- see round 22's
	// note near ch0_eg_type_at_keyon's port declaration for the freed
	// slot.)
	output        pc_hit_000e_wrong_data, // read 0x000E but got something other than the real ROM byte (0x88)

	// 2026-08-17, round 4 result: pc_hit_000e_wrong_data = GREEN (never
	// wrong). The 0x000E operand is confirmed correct every time. Loop
	// still never exits. Read T80_ALU.vhd's CP/Z-flag logic directly
	// (lines 161-220) -- completely standard (Q_t = A-n, Flag_Z <=
	// (Q_t==0)), nothing obviously wrong. Independent reasoning from
	// ym_written_ever=GREEN: HL's real bus value must cross 8-bit page
	// boundaries correctly to ever reach 0xA000/0xC000 (proving INC HL's
	// L-to-H carry works), meaning H almost certainly does sit at 0x88
	// for a full 256-iteration stretch en route -- yet the comparison
	// never reacts, not once. Gemini consult round 5: rather than keep
	// testing one byte per ~20min compile, this single "omnibus" wire
	// checks every remaining unverified byte in the causally-relevant
	// span at once (LD HL,0x8000's own opcode+operands, all 5 loop-body
	// instruction bytes including the JR NZ branch offset) -- every value
	// independently confirmed against the real ROM file before use.
	// (boot_chain_corrupted retired 2026-08-18, round 19 -- long
	// confirmed GREEN/exonerated -- see round 19's note near
	// ch0_con_additive_at_keyon's port declaration for the freed slot.)

	// 2026-08-17, round 6: boot_chain_corrupted=GREEN -- the data path is
	// fully exonerated end-to-end. The bug is genuinely inside T80's own
	// execution. Rather than expose H directly (its bit offset within
	// T80's internal REGS bus requires tracing a non-trivial register-file
	// indexing scheme, a real risk of a wrong offset wasting a compile),
	// these three reuse the fact that HL's true value is ALREADY directly
	// bus-visible during the loop's own write cycle, and only need T80's
	// internal A/F registers (independently verified bit positions:
	// A=REGS[7:0], Flag_Z=REGS[14] per T80.vhd's REGS concatenation and
	// T80_ALU.vhd's Flag_Z=6 constant) to isolate the remaining two
	// candidates:
	output        hl_reached_8800,      // bus-level: HL's real value hit exactly 0x8800 during a write (H genuinely became 0x88 at least once)
	output        a_hit_88_at_jrnz,     // at the JR NZ decision point (0x000F), was the internal A register ever seen holding 0x88 (tests whether LD A,H actually works)
	output        z_wrong_when_a_88,    // at that same point, whenever A really was 0x88, was the Zero flag NOT set (tests CP's flag logic specifically for this case)

	// 2026-08-17, round 6 result: a_hit_88_at_jrnz=RED, hl_reached_8800=
	// GREEN -- LD A,H isn't delivering H's real value into A. My own
	// stuck-XY_State theory was checked and refuted (T80.vhd clears it
	// every non-prefix M1 fetch). Gemini's theory: T80.vhd's `Alternate`
	// bit (line 946: RegAddrA_r <= Alternate & Set_BusA_To(2 downto 1))
	// feeds the SAME 8-bit register-bank-selection logic as XY_State,
	// not just AF -- if Alternate is somehow '1', EVERY 8-bit register
	// read (including this LD A,H) would redirect to the shadow bank
	// (H' instead of H), fully explaining the symptom. Verified `Alternate
	// <= '0'` IS in T80's reset block (line 517, alongside PC/XY_State/
	// etc.), so it can only become '1' via a real EX AF,AF' (opcode 0x08)
	// executing somewhere in the instruction stream.
	output        executed_ex_af,      // unconditional: was opcode 0x08 (EX AF,AF') ever opcode-fetched anywhere

	// 2026-08-17, task #8 correction: the T80 accumulator fix is confirmed
	// (every boot-sequence diagnostic passes, CPU reaches EI and services
	// real interrupts), but the user reports sound is STILL completely
	// silent during real gameplay -- sound_output_ever_nonzero=GREEN was
	// wrongly generalized from a single 15s post-boot screenshot; that
	// sticky OR-accumulator can't distinguish a single transient sample
	// (plausible during the boot code's own silence-safe OPL2 init
	// sequence, e.g. 0xBD=0x00 disabling rhythm, 0xB0-0xB9=0 clearing
	// operators, none of which should be audible) from real sustained
	// music. Gemini consult: check for a genuine OPL2 "Key On" event
	// instead (a data write to register 0xB0-0xB8 with bit 5 set -- the
	// actual note-trigger, per standard, well-documented Yamaha OPL2
	// register semantics) to distinguish "the chip was only initialized
	// to silence" from "a real note was actually triggered."
	output        key_on_triggered,

	// 2026-08-18, task #8 round 13: was YM1 channel 0's F-Number low byte
	// (register 0xA0) ever set to a nonzero value -- distinguishes "the
	// note that triggers has real frequency data" from "Key-On fires but
	// the frequency setup itself is zero/garbage."
	output        ch0_fnum_nonzero,

	// 2026-08-18, task #8 round 14: was channel 0's carrier operator ever
	// set to something other than maximum attenuation (register 0x43,
	// Total Level) -- tests whether the note is being told to play at an
	// audible volume, as opposed to correct frequency + key-on but muted.
	output        ch0_op2_tl_not_max,

	// 2026-08-18, task #8 round 15: jtopl2's raw combined output (ym1_snd),
	// checked directly before this project's own mixing step.
	output        ym1_snd_ever_nonzero,

	// 2026-08-18, task #8 round 16: ym1_snd_ever_nonzero came back GREEN --
	// jtopl2 itself is genuinely synthesizing. sound_output_ever_nonzero
	// (the final audio_l/audio_r reaching AUDIO_L/AUDIO_R) was ALSO
	// confirmed GREEN earlier this session. Both endpoints of this
	// project's own audio chain pass the bare "ever nonzero" bar, yet the
	// game is still silent -- so the open question is magnitude: is this a
	// sustained, audible-amplitude waveform, or a single-sample power-on/
	// reset transient that happens to satisfy "!= 0" once and then sits at
	// true zero for the rest of the session? These two thresholds
	// distinguish a trivial glitch (would fail both) from real music-level
	// output (real FM synthesis swings should clear 4096 routinely).
	output        audio_mag_gt256_ever,
	output        audio_mag_gt4096_ever,

	// 2026-08-18, task #8 round 17: round 16 confirmed the final mixed
	// audio genuinely never gets loud, not just "technically nonzero".
	// ch0_op2_tl_not_max (round 14) only ever checked "!= 0x3F" (not
	// fully muted) -- a quiet-but-not-max value like 0x3E would pass
	// that check while still being nearly silent by design of the byte
	// itself. This is a sharper companion check: was channel 0's carrier
	// Total Level (register 0x43) ever written with a LOW attenuation
	// value (<=8 out of a possible 0-0x3F range, i.e. genuinely close to
	// full volume), as opposed to merely "not the single maximum value".
	// Retires pc_hit_0038 (long confirmed RED/expected, per the
	// project's diagnostic-overlay-retirement discipline -- row4 was
	// already full) to free its row4 slot.
	output        ch0_op2_tl_ever_loud,

	// 2026-08-18, task #8 round 18: ch0_op2_tl_ever_loud (round 17) and
	// key_on_triggered (round 12) are both independent sticky "ever"
	// flags -- each proves its condition was true at SOME point across
	// the whole capture window, not that they were true at the SAME
	// instant. The loud TL write and a real Key-On could belong to
	// different moments in the ROM's execution (e.g. a loud value during
	// init, later overwritten to something quiet before the note that
	// actually gets keyed on in gameplay). This is the real correlated
	// test: captures channel 0's carrier TL value specifically at the
	// moment channel 0's OWN Key-On fires (register 0xB0 specifically --
	// not the whole 0xB0-0xB8 range key_on_triggered watches, so this is
	// unambiguously channel 0's own note-on event, not some other
	// channel's). Retires pc_out_of_bounds (long confirmed RED/expected,
	// same disproven garbage-execution theory as the already-retired
	// pc_hit_0038) to free its row4 slot -- row4 was full again.
	output        ch0_tl_loud_at_keyon,

	// 2026-08-18, task #8 round 19: round 18 confirmed every register
	// input jtopl2 receives for this note is correct at the precise
	// moment that matters (real trigger, real frequency, real loud
	// volume), yet the final output stays quiet -- ruling out every
	// "wrong register value" explanation tested so far. One control
	// register hasn't been checked: channel 0's Feedback/Connection
	// (0xC0, bit0 = CON). CON=0 (FM/serial mode, the standard OPL2
	// default) means only the carrier's (op2, register 0x43, already
	// confirmed loud at keyon) TL determines output level -- the
	// assumption this whole investigation has been built on. CON=1
	// (additive mode) would mean operator 1's own TL (register 0x40,
	// never checked) also contributes directly and could independently
	// be muted, silently explaining quiet output despite a loud
	// carrier. This checks whether CON was ever 1 at the same moment
	// channel 0's own Key-On fires, same snapshot-at-event pattern as
	// ch0_tl_loud_at_keyon. Retires boot_chain_corrupted (long confirmed
	// GREEN/exonerated, from the disproven RAM-clear-loop theory many
	// rounds ago) to free its row4 slot.
	output        ch0_con_additive_at_keyon,

	// 2026-08-18, task #8 round 20: round 19 confirmed standard FM
	// connection mode (CON=0) -- the carrier-only TL assumption holds,
	// and every register this investigation has checked (trigger,
	// frequency, volume, connection mode) is confirmed correct at the
	// precise moment of Key-On. One real, well-documented Yamaha OPL2
	// behavior hasn't been checked yet: Attack Rate. Confirmed directly
	// in rtl/jtopl/hdl/jtopl_eg_step.v (~line 82: `case(rate[1:0])
	// 2'd0: step_idx = 8'b00000000`, i.e. the envelope generator's step
	// size is genuinely zero when the rate is zero) that jtopl correctly
	// implements real OPL2 semantics here: Attack Rate 0 means the
	// attack phase's step size is zero, so the envelope never leaves its
	// post-Key-On starting point (maximum attenuation) -- a real,
	// hardware-accurate way for a note to stay permanently silent
	// despite a real Key-On and a real, loud Total Level, since TL and
	// the envelope generator's own attenuation state are separate,
	// additively-combined attenuation sources. Channel 0's carrier
	// Attack/Decay Rate register is 0x63 (0x60 base + 3, same operator-
	// offset pattern as TL's 0x43), upper nibble = Attack Rate. Same
	// snapshot-at-keyon pattern as TL/FBCON. Retires pc_hit_0011 (long
	// confirmed GREEN since the T80 fix, subsumed by the already-retired
	// boot_chain_corrupted) to free its row3 slot -- row4 was already
	// full and this is the first round to reuse row3 instead.
	output        ch0_ar_zero_at_keyon,

	// 2026-08-18, task #8 round 22: round 20's Attack Rate check (RED --
	// AR is genuinely nonzero) ruled out "the envelope never leaves max
	// attenuation" as an explanation. A related but distinct real Yamaha
	// OPL2 behavior hasn't been checked: EG-TYP (Sustain enable, bit5 of
	// register 0x23 -- confirmed directly in rtl/jtopl/hdl/jtopl_reg.v's
	// `{amen_IV, viben_I, en_sus, ks_II, mul_II, ...} = shift_out[...]`
	// concatenation that en_sus (sustain enable) is genuinely the third
	// bit from the top of this register, i.e. bit5, matching the
	// standard documented OPL2 layout). If EG-TYP=0 (percussive/
	// non-sustained mode), the envelope continues decaying past the
	// Sustain Level all the way to full attenuation even while the key
	// stays held -- a real, hardware-accurate way for a note with a
	// perfectly correct trigger, frequency, and initial volume to still
	// end up silent shortly after triggering. Retires pc_hit_000e (long
	// confirmed GREEN, boot chain fully exonerated since the T80 fix) to
	// free its row3 slot.
	output        ch0_eg_type_at_keyon,

	// 2026-08-18, task #8 round 23: EG-TYP=0 (round 22) explains why the
	// note wouldn't sustain, not why it never registers loud even
	// briefly during attack -- rounds 17/18/20 already confirmed real,
	// nonzero Attack Rate and a real, loud Total Level target at the
	// exact keyon instant, so a genuinely well-formed attack should
	// still produce a real amplitude peak that round 16's sticky "ever"
	// magnitude check (across a full 40s) should have caught. KSL (Key
	// Scale Level, bits 7:6 of the SAME register 0x43 already confirmed
	// loud in its low 6 bits/TL) has never been isolated on its own --
	// it applies its own frequency-dependent attenuation on top of TL,
	// which could be maximal for this note's specific frequency/block
	// and effectively cancel out an otherwise-loud TL setting. Cheap
	// reuse of the existing ym1_ch0_op2_tl_latch (already the full byte,
	// not just the low 6 bits) -- just a new 2-bit snapshot at the same
	// keyon instant, no new register-write monitoring needed. Placed in
	// row2's h_cnt 80-96 slot, confirmed genuinely free (never used),
	// so nothing needs to be retired this round.
	output        ch0_ksl_nonzero_at_keyon,

	// 2026-08-18, task #8 round 24: round 23's KSL check ruled out extra
	// frequency-dependent Total Level attenuation. The remaining
	// register-level candidate: Key Scale Rate (KSR, register 0x23
	// bit4 -- the bit immediately adjacent to round 22's already-checked
	// EG-TYP at bit5, same register, confirmed directly in
	// rtl/jtopl/hdl/jtopl_reg.v's `{amen_IV, viben_I, en_sus, ks_II,
	// mul_II, ...} = shift_out[...]` concatenation that ks_II (key
	// scale) is genuinely the fourth bit from the top, i.e. bit4).
	// Confirmed directly in rtl/jtopl/hdl/jtopl_eg_step.v (`shby = ksr ?
	// 2'd1 : 2'd3`) that KSR=1 scales the envelope's effective rate
	// calculation, making rates advance faster for higher notes -- KSR=0
	// is the "no scaling" default. If the ROM sets KSR=1 for a
	// low-numbered note, this could scale the confirmed-nonzero Attack
	// Rate down to something effectively very slow for this specific
	// note's frequency/block, such that attack never completes within
	// any real observation window despite the raw AR register value
	// being genuinely nonzero. Cheap reuse of the existing
	// ym1_ch0_egtyp_latch (already the full byte from register 0x23,
	// populated by round 22) -- just a new 1-bit snapshot at the same
	// keyon instant. Retires the display of sound_output_ever_nonzero
	// (diag_box_audio_out in Battlantis.sv, row2 h_cnt 200-216) --
	// fully superseded by the much more precise round 15/16 checks
	// (ym1_snd_ever_nonzero, audio_mag_gt256/4096) which test the exact
	// same underlying question with far better precision. The
	// underlying sound_output_ever_nonzero computation in Battlantis.sv
	// is left in place (harmless, just no longer displayed) since
	// nothing else depends on removing it.
	output        ch0_ksr_at_keyon,

	// 2026-08-18, task #8 round 26: the register-level investigation is
	// otherwise exhaustively complete (rounds 12-25: trigger, frequency,
	// TL x3, connection, AR, EG-TYP, KSL, KSR, Test register all
	// confirmed correct or ruled out). Decay Rate (register 0x63 lower
	// nibble -- the same register whose upper nibble/Attack Rate was
	// already confirmed nonzero in round 20) has never been isolated on
	// its own. Reasoning is weaker than the earlier checks (Attack Rate
	// nonzero + KSR not engaged already guarantees the envelope must
	// complete a real, bounded attack climb through progressively
	// louder states before Decay can even begin, per OPL2's own
	// Attack->Decay state transition only firing once Attack reaches
	// max volume -- so DR governs what happens *after* a real peak, not
	// whether one exists), but it's cheap to check (reuses the
	// already-populated ym1_ch0_ar_dr_latch from round 20, no new
	// register-write monitoring needed) and closes out the register
	// space completely rather than leaving one stone unturned. Retires
	// the display of z80_fetching_ever (diag_box_z80_fetch -- the
	// earliest, coarsest sound-chain check from before round 12, long
	// superseded by ~20 more specific downstream checks since; the
	// underlying z80_fetching signal itself stays, still used
	// internally) to free its row2 h_cnt 140-156 slot.
	output        ch0_dr_zero_at_keyon,

	// 2026-08-18, task #8 round 27: Sustain Level / Release Rate
	// (register 0x83 -- 0x80 base + 3, same operator-offset pattern as
	// TL's 0x43 and AR/DR's 0x63), upper nibble = Sustain Level, lower
	// nibble = Release Rate. Never isolated on its own. Same weaker
	// reasoning as round 26's Decay Rate applies (these govern the
	// envelope's post-peak behavior, not whether a real peak exists at
	// all, given the already-confirmed real Attack Rate and unscaled
	// KSR), but closes out the full envelope register set. New latch
	// needed (register 0x83 not previously monitored). Retires the
	// display of z80_irq_ack_ever (diag_box_irq_ack -- same
	// pre-round-12 vintage as z80_fetching, long superseded; irq_ack
	// itself stays, still used internally to clear the interrupt
	// flip-flop) to free its row2 h_cnt 160-176 slot.
	output        ch0_sl_rr_zero_at_keyon,
	output        ch0_test_reg_nonzero_at_keyon,

	// 2026-08-18, task #8 round 28: the OPL2 register-level investigation
	// is now completely exhausted (rounds 12-27) -- every register
	// confirms a fully well-formed, should-be-audible note. Round 16's
	// magnitude check (audio_mag_gt256_ever/audio_mag_gt4096_ever) was
	// applied to the FINAL MIXED output (ym1_snd + ym2_snd, post-sum) --
	// never to ym1_snd alone, before mixing. ym2 is a second, genuinely
	// separate YM3812 at its own address range (0xC000-0xC001, confirmed
	// distinct from ym1's 0xA000-0xA001) -- the real game almost
	// certainly drives real channels on it too (not just an idle/unused
	// chip), and it has never been instrumented at all this session. If
	// ym2's raw output happened to be sustained and large-magnitude with
	// an opposite sign to ym1's, the two could destructively cancel when
	// summed, which would fully explain "each side might be fine, but
	// the combined result never gets loud" -- something round 16 could
	// never have detected, since it only ever looked at the sum. This
	// isolates ym1_snd's own peak magnitude directly, before the sum,
	// using the same threshold logic as round 16. Retires the display
	// of ym_written_ever (diag_box_ym_write -- same pre-round-12 vintage
	// as the two other early coarse checks already retired in rounds
	// 26/27, long superseded; the underlying signal stays) to free its
	// row2 slot.
	output        ym1_snd_mag_gt256_ever,

	// 2026-08-19, task #8 round 30: the OPL2 register-level investigation
	// is exhaustively complete (rounds 12-28) and jtopl2 is separately
	// exonerated in isolation -- a from-scratch testbench, once a real
	// testbench-side write-pacing bug was found and fixed, drove jtopl2
	// with this project's exact real, confirmed-correct register
	// sequence and got a genuine, moderate-magnitude (peak 3954/32767)
	// FM synthesis waveform, climbing through a real attack over
	// roughly 150ms before peaking (see debugging_log.md entry 31).
	// This directly contradicts real hardware's own <256 ceiling across
	// a full 40 real seconds with the same sequence -- the remaining
	// gap must be something about how the real deployed core differs
	// from the clean, isolated testbench, not the note's own
	// configuration. Leading hypothesis: the real Key-On for this note
	// doesn't stay held/uninterrupted long enough for its slow attack to
	// ever climb far, because the real Z80 driver retriggers it (or
	// writes a Key-Off) faster than that. This checks how long channel
	// 0's Key-On register (0xB0) goes untouched after a real Key-On
	// write, before the Z80 writes to that same register again for any
	// reason -- a genuinely new kind of check (elapsed time between two
	// bus events, not a single register snapshot).
	output        ym1_ch0_keyon_held_100ms,

	// 2026-08-19, task #8 round 31: round 30 found Key-On for channel 0
	// IS held 100ms+ at least once without interruption -- yet the
	// isolated simulation (round 29) needed only ~150ms with near-max
	// test values (TL=0/loudest, AR=15/fastest) to reach a real,
	// audible peak. Round 20 only confirmed Attack Rate is nonzero, not
	// its exact value -- if the real AR is low (e.g. 1-2, barely above
	// the "stuck" AR=0 case already ruled out) rather than the
	// simulation's max-speed AR=15, the real attack could take vastly
	// longer than 150ms (OPL2's rate table is roughly exponential, not
	// linear) to reach a comparable peak, fully reconciling "100ms held
	// at least once" with "still no audible peak" -- reusing the
	// already-populated ym1_ch0_ar_dr_latch from round 20, checking
	// whether AR is in the fast half (>=8) or slow half (<8) of its
	// 0-15 range. Retires diag_box_pc_csumfail (long confirmed GREEN,
	// boot execution extensively re-verified many rounds since) to free
	// its row3 slot.
	output        ym1_ch0_ar_fast_at_keyon,

	// 2026-08-19, task #8 round 37: F-Number's low byte (round 13) was
	// only ever checked for "!= 0"; its high 2 bits and the 3-bit
	// Block/octave both live in register 0xB0 -- the SAME register
	// Key-On itself uses -- and were never read at all. Combines them
	// into the real 10-bit frequency word, shifts by Block (matching the
	// standard OPL2 formula's Fnum*2^Block term), and checks whether the
	// result is small enough to correspond to a genuinely infrasonic
	// pitch (below ~19Hz using this project's own confirmed real YM3812
	// clock, 24MHz XTAL/8 = 3.0MHz, in Hz = Fnum*2^Block*clock/(2^19*72)).
	// If the real note's pitch is this low, "climbs slowly and stays
	// under magnitude 256 across a 40s window" is exactly what an
	// infrasonic oscillator looks like -- not a broken chip -- and would
	// reconcile the round 29 simulation (which used an arbitrary
	// mid-range test frequency, never the real Fnum/Block) with real
	// hardware's stubbornly-quiet signal.
	output        ch0_freq_infrasonic_at_keyon,

	// 2026-08-19, task #8 round 39: register 0xC0's CON bit (bit 0) was
	// checked back in round 19 (confirmed FM/non-additive mode), but its
	// Feedback amount (FB, bits 3:1, a 3-bit 0-7 self-modulation depth
	// for the channel's modulator operator) was never read at all -- the
	// one remaining genuinely untested register field for channel 0's
	// note. Lower confidence than prior checks (FB controls
	// self-modulation/phase-feedback depth, not gain/attenuation in the
	// usual sense, so it's not an obvious silence mechanism on real
	// OPL2 hardware), but cheap to check by reusing the already-latched
	// ym1_ch0_fbcon_latch (round 19), so worth ruling in or out before
	// considering a bigger move like exposing jtopl2's internal
	// envelope-generator state directly.
	output        ch0_fb_nonzero_at_keyon,

	// 2026-08-19, task #8 round 40: with every register-level, timing,
	// clocking, addressing, and synthesis-inference explanation exhausted
	// (rounds 30-39) and Gemini's two proposed theories both ruled out
	// (round 38), this taps jtopl2's internal envelope generator directly
	// for the first time this investigation -- everything checked before
	// this was either an input register value or the final ym1_snd
	// output; nothing in between had been directly observed on real
	// silicon. New debug ports were added to jtopl.v/jtopl2.v/jtopl_mmr.v/
	// jtopl_reg.v (diagnostic-only, no functional change) exposing the
	// envelope generator's raw current output (dbg_eg_V, 0=loudest) and a
	// one-cycle-wide valid pulse identifying exactly when that value
	// belongs to channel 0's carrier operator specifically (not channels
	// 1/2, which share the same internal "group" -- see jtopl.v's port
	// comment for the full derivation and pipeline-timing justification).
	// These two threshold checks answer the direct question: does the
	// envelope generator itself, internally, ever reach a genuinely loud
	// (low-attenuation) value for this exact note on real hardware, or
	// does it never get anywhere close regardless of what final ym1_snd
	// shows downstream.
	output        ch0_car_eg_lt256_ever,
	output        ch0_car_eg_lt64_ever,

	// 2026-08-19, task #8 round 41: round 40 found the internal envelope
	// for channel 0's carrier never gets meaningfully loud on real
	// hardware. This distinguishes two very different explanations before
	// guessing which internal module to investigate next: does the
	// envelope value ever change AT ALL (even a little), or is it
	// completely frozen at its post-Key-On starting value the whole time?
	// RED would point at the envelope generator's rate/state-advancement
	// logic not running at all on real hardware; GREEN would mean it
	// moves, just far too slowly or not far enough within the real
	// observation window, pointing instead at a rate-magnitude problem.
	output        ch0_car_eg_ever_changed,

	// 2026-08-19, task #8 round 43: `jtopl_eg_step.v`'s rate-to-step
	// logic (the module that decides whether a given cycle should
	// advance the envelope) is pure combinational logic with no state of
	// its own, so it's unlikely to behave differently between simulation
	// and real synthesized hardware given correct inputs -- making the
	// shared global envelope timebase (eg_cnt, one 15-bit counter shared
	// by all 18 slots, incrementing once per full round-robin cycle) the
	// more foundational thing to check directly: does it even advance at
	// all on real hardware. If eg_cnt itself is frozen, every channel's
	// envelope would be frozen identically (consistent with total
	// silence, not just channel 0), pointing at jtopl_eg_cnt.v/the
	// shared `zero`/`cenop` timebase rather than anything channel- or
	// operator-specific.
	output        eg_cnt_ever_changed,

	// 2026-08-19, task #8 round 44: round 43 ruled out the shared
	// envelope timebase, narrowing the mystery to channel 0 carrier's own
	// per-slot machinery. This checks the actual internal Key-On
	// edge-detect pulse (keyon_now_I in jtopl_eg.v) that triggers the
	// ATTACK state transition -- if it never fires for this slot despite
	// the real bus-level Key-On write being independently confirmed
	// received, the per-slot keyon_last_I storage would be the culprit.
	output        ch0car_keyon_now_ever,

	// 2026-08-19, task #8 round 48: retry of rounds 45/46's sum_up_II
	// check, this time with the required 1-cycle delay built entirely in
	// this project-owned file (using the newly-exposed dbg_cenop wire)
	// instead of as a new register inside jtopl.v -- isolating whether
	// that specific choice was the cause of the round 45/46 regression.
	output        ch0car_sum_up_ever,

	// 2026-08-19, task #8 round 49: does the RAW persistent envelope
	// value (eg_in_I, distinct from the TL/KSL-modulated eg_V) ever
	// change for channel 0's carrier -- the most direct possible
	// confirmation of whether u_egsh's storage genuinely updates.
	output        ch0car_eg_in_I_ever_changed,

	// 2026-08-19, task #8 round 51: does step_II ever fire for channel
	// 0's carrier -- the separate signal that gates the actual MAGNITUDE
	// of jtopl_eg_pure.v's computed update (ar_sum/dr_sum), independent
	// of sum_up. If sum_up fires but step never does at the same time,
	// the computed update is zero-change every time, exactly matching
	// the observed symptom without any storage-mechanism bug at all.
	output        ch0car_step_ever,

	// 2026-08-19, task #8 round 52: was state_in_I ever seen genuinely
	// holding ATTACK (3'b001) for channel 0's carrier. Per Gemini's
	// theory: if this never persists (falling back to its 3'b111 reset
	// value every cycle instead), jtopl_eg_ctrl.v's casez falls through
	// to its default case every time, forcing RELEASE and recomputing
	// eg_in right back to its own reset value -- explaining the frozen
	// envelope even with sum_up_II/step_II both genuinely firing.
	output        ch0car_state_attack_ever,

	// 2026-08-19, task #8 round 53: the decisive joint check. Round 52
	// proved state=ATTACK happens at least once, and sum_up_II/step_II
	// (round 51/48) each independently proved true at least once -- but
	// never proved all three true on the SAME cycle. attack_II is
	// already registered at the same "stage II" pipeline timing as
	// sum_up_II/step_II, so this reuses the existing round-48 delayed
	// valid signal directly. If this reads RED despite all three
	// individual checks reading GREEN, it proves the three conditions
	// never actually coincide for this exact channel/operator -- a real,
	// specific timing/alignment defect, not a single broken signal.
	output        ch0car_attack_step_sumup_ever,

	// 2026-08-19, task #8 round 55: real, registered version of round 53's
	// joint check (see rtl/jtopl/hdl/jtopl_eg.v's dbg_joint_hit_II port
	// comment and this file's ch0car_joint_hit_reg_ever assign for the
	// full reasoning).
	output        ch0car_joint_hit_reg_ever_out,

	// 2026-08-20, task #8 round 63: a more decisive version of the joint
	// check, testing the exact registered values that feed
	// jtopl_eg_pure.v's real arithmetic directly (attack_III/step_III/
	// sum_in_III) rather than round 55's stage-II mix of one register and
	// two combinational wires. See rtl/jtopl/hdl/jtopl_eg.v's
	// dbg_joint_hit_III port comment for the full reasoning.
	output        ch0car_joint_hit_III_ever_out,

	// 2026-08-20, task #8 round 71: a live Battlantis re-test (with round
	// 68's jtopl_eg_step.v sum_up fix already deployed) reconfirmed
	// ch0car_eg_in_I_ever_changed is STILL red -- the fix did not unstick
	// the real hardware defect. Gemini review of jtopl_eg_pure.v surfaced
	// an unconditional bypass, original vendor code, not part of this
	// investigation: `eg_pure = (attack&rate[5:1]==5'h1F) ? 10'd0 :
	// eg_pre_fastar;` -- whenever attack is high and rate is 62/63, the
	// envelope should snap straight to 0 (loudest) regardless of sum_up.
	// If that's genuinely engaging, round 68's fix would be moot for this
	// exact note and eg_in_I should already be updating -- since it isn't,
	// either `rate` never actually reaches 63 despite arate_I reading 15,
	// or the bypass's 10'd0 write is getting lost before reaching storage.
	// These two sticky latches test the first half directly on the real,
	// confirmed-reproducing hardware (not just the isolated test harness):
	// does channel 0's carrier ever get arate_I==15 / rate==63 at all.
	// arate_I is a "stage I" signal (same timing as eg_in_I/keyon_I);
	// rate_II is "stage II" (same timing as sum_up_II/step_II) -- reuses
	// the existing round-48 delayed valid signal, no new delay needed.
	output        ch0car_arate_was_15_ever,
	output        ch0car_rate_was_63_ever,

	// 2026-08-21, task #8 round 103: post-fix, the user reports real audio
	// (huge progress) but a constant high-pitched whine present the whole
	// time, plus quiet sound effects and one recognizable-but-wrong song.
	// The constant whine strongly suggests one specific OPL2 channel is
	// stuck key-on with no corresponding key-off ever landing. Live,
	// per-channel (chip 1, channels 0-8) Key-On state, reflecting each
	// channel's own most recent register 0xB0-0xB8 write -- not sticky,
	// so this shows CURRENT state, letting us see which channel(s) are
	// active right now.
	output  [8:0] ym1_ch_key_on_state,

	// 2026-08-22, task #8 round 121: live, per-channel (chip 1) "is this
	// channel's OWN carrier envelope currently below the same eg_V<256
	// audible threshold this file already uses (see
	// ch0_car_eg_lt256_ever's round-40 convention)" -- independent of
	// what any OTHER channel is doing, unlike round 113's single
	// "last channel to go key-off" snapshot (a reasonable proxy that
	// round 120's hardware test showed can misattribute the real stuck
	// channel). Meant to be read side-by-side with ym1_ch_key_on_state
	// above: any channel index reading Key-On=0 here but Audible=1 is a
	// real candidate for the actual stuck channel.
	output  [8:0] ym1_ch_audible_live,

	// 2026-08-22, task #8 round 121b: see the ch_audible_gen generate
	// block's comment -- the real, duration-gated "channel N has been
	// Key-Off AND audible continuously for 5.0s+" sticky per-channel
	// signal (mirrors stuck_envelope_confirmed_ever's own convention, but
	// per-channel instead of gated on ALL channels being Key-Off at once).
	output  [8:0] ym1_ch_stuck_confirmed,

	// 2026-08-23, task #8 round 139: round 138's global stuck-envelope
	// check fired again (t=18s, matching the whine's known onset) even
	// though the "last touched channel" snapshot now reads RR=15 (fastest
	// possible release) -- proof round 136's 0x02ad fix is genuinely live,
	// but also proof that heuristic ("whichever channel most recently had
	// a real Key-On write") is no longer pointing at the actual offender,
	// now that the obvious one is fixed. Round 121 already built this
	// exact per-channel breakdown for ym1 (ym1_ch_stuck_confirmed above)
	// but it was NEVER wired to a display. Mirrors it to ym2, since round
	// 137's own evidence points at ym2 channels 7/8 specifically -- ym2
	// never had this per-channel breakdown at all before now (only the
	// global stuck_envelope_ym2_confirmed_ever existed).
	output  [8:0] ym2_ch_stuck_confirmed,

	// 2026-08-22, task #8 round 121c: see the ch_audible_gen generate
	// block's stuck_sl_rr_snapshot comment -- each channel's own carrier
	// SL/RR register value at the exact instant THAT channel's own
	// ym1_ch_stuck_confirmed[N] first sets. 8 bits per channel, packed
	// low-to-high (channel 0 = bits [7:0]), same convention as round
	// 113's ym1_ch_car_sl_rr_latch.
	output [71:0] ym1_ch_stuck_sl_rr_snapshot,

	// 2026-08-21, task #8 round 106: round 105 confirmed real audio
	// output persists while every channel reads Key-Off, pointing at a
	// stuck envelope (likely the Release phase never decaying). Register
	// 0x63 (channel 0 carrier AR/DR) is now confirmed written correctly
	// post-fix (round 102) -- this checks the sibling register 0x83
	// (channel 0 carrier Sustain-Level/Release-Rate) using the exact same
	// proven "was it ever written" technique as round 85's last_ym1_addr
	// check, since RR=0 (never decaying) would directly explain a stuck,
	// audible tone independent of Key-On state, and this field was
	// flagged by an earlier Gemini latch audit as vulnerable to the same
	// "reset value looks like real data" trap that caused the original
	// AR/DR confusion, but was never independently re-verified.
	output        last_ym1_addr_was_83_ever,

	// 2026-08-21, task #8 round 107: round 106 confirmed register 0x83 IS
	// written (ruling out "never written, stuck at reset default"), but
	// that doesn't rule out the register genuinely holding SL/RR=0 (real
	// data, not a bug) for whichever note is causing the stuck tone.
	// Snapshots channel 0's own SL/RR latch (register 0x83's live value,
	// already tracked below) at the exact moment audio is first found
	// non-zero while every channel reads Key-Off, so we can see the
	// actual RR value active during the stuck condition specifically
	// (lower nibble = RR, upper nibble = SL, standard OPL2 layout).
	// Reset to 8'hE5, a value distinct from any real SL/RR combination
	// interpretation ambiguity, per this project's diagnostic-latch
	// discipline.
	output  [7:0] ch0_sl_rr_at_stuck_audio_snapshot,

	// 2026-08-21, task #8 round 104: round 103's live per-channel Key-On
	// snapshot showed channels 0-6 toggling normally over a few seconds
	// (not one obviously permanently-stuck channel), but coarse manual
	// polling can't reliably distinguish normal fast note on/off from a
	// genuinely stuck channel. Generalizes the existing, already-proven
	// ym1_ch0_keyon_held_100ms pattern to all 9 channels: sticky, fires
	// if ANY channel is ever held continuously key-on for 100ms+ without
	// a single Key-On register rewrite -- real music notes are much
	// shorter than that, so this would catch a channel that never
	// receives its key-off, a plausible cause of a constant tone/whine.
	output  [8:0] ym1_ch_keyon_held_100ms,

	// 2026-08-21, task #8 round 105: the user precisely identified the
	// exact frame the whine begins, and every channel's Key-On reads OFF
	// at that moment and for several frames around it -- ruling out a
	// stuck Key-On bit as the direct mechanism. New hypothesis: OPL2's
	// Release-phase envelope decay (after Key-Off) could be stuck (same
	// class of bug as the AR=0 issue just fixed, but for the decay-to-
	// silence phase), leaving real non-zero audio output even though
	// every channel's Key-On correctly reads 0. Sticky: fires if the raw
	// jtopl2 output (chip 1) is ever significantly non-zero WHILE every
	// channel's Key-On is simultaneously off.
	output        audio_nonzero_while_all_keyoff_ever,

	// very first one (0x02F9, right after a trivial 4-iteration pure-ALU
	// loop with zero external dependencies -- should complete in
	// microseconds if the CPU is genuinely running). Since z80_fetching_ever
	// and ym_written_ever both read true anyway, that combination is only
	// possible if the CPU ran for a *little while* then genuinely froze
	// (ce_z80 stopped pulsing, or something else halted real progress) --
	// a one-shot combinational read/write at the moment of freezing would
	// otherwise get latched as "ever true" even with no ongoing execution.
	// This saturating counter distinguishes "froze after a handful of
	// cycles" from "genuinely executing continuously but never reaching
	// the checked addresses for some other reason": increments on every
	// real opcode fetch, saturates at 15, sticky-latched once it reaches 8+.
	output        z80_fetch_count_reached_8,

	// 2026-08-21, task #8 round 109: real MAME debugger tracing of the
	// actual HD6309E confirmed the "stop" command (0x80) does NOT issue a
	// direct Key-Off -- ROM 0x00F3 only arms a software fade (RAM 0x8116=1,
	// 0x8115=0). Disassembly of the main loop (ROM 0x0390-0x03AA) and the
	// per-channel updater (ROM 0x0620-0x063E) confirms the intended
	// mechanism: every ~57 main-loop passes, RAM 0x8115 increments by 2 and
	// gets added to each channel's per-note TL bias, progressively
	// attenuating volume; once 0x8115 reaches 0x1B (27), ROM 0x021A issues
	// a real hard Key-Off to all 18 channel slots on both chips and resets
	// 0x8115/0x8116 back to 0. Live snoop of these two RAM bytes lets a
	// screenshot taken during a whine episode distinguish three distinct
	// failure modes: fade never starts (0x8116 stuck 0), fade starts but
	// never completes (0x8115 climbs but never resets, 0x8116 stuck 1), or
	// fade completes correctly on the Z80/RAM side (0x8115/0x8116 both
	// cycle back to 0) -- in which case the bug is downstream, in how our
	// OPL2 core applies the resulting TL/Key-Off writes, not in the Z80
	// sound program itself.
	output  [7:0] ram_8115_fade_level_live,
	output        ram_8116_fade_active_live,

	// 2026-08-21, task #8 round 110: the user pinpointed the whine's onset
	// precisely -- it starts right after the title screen hangs a note,
	// during the transition into the "stage #" announcement screen. Round
	// 109's fade diagnostic showed 0x8115/0x8116 never move during this
	// exact transition (no fade is ever armed -- the music just winds down
	// on its own), and round 103's existing live per-channel Key-On row
	// showed every channel legitimately reading Key-Off by the time the
	// whine starts. That combination points squarely at round 105's
	// already-proven "audio_nonzero_while_all_keyoff" condition (a stuck
	// OPL2 envelope not truly decaying to silence after Key-Off) -- but
	// only the STICKY "ever happened this session" version of that check
	// was ever exposed to the overlay, so it couldn't be correlated to
	// this specific transition. This exposes the LIVE (non-sticky) wire
	// that already existed internally for round 107's edge-detector,
	// letting a screenshot burst catch the exact frame it fires and line
	// it up directly against the per-channel Key-On row to see which
	// channel is the stuck one.
	output        audio_nonzero_while_all_keyoff_live_out,

	// 2026-08-22, task #8 round 111: round 110's LIVE flag was sampled once
	// per second across a full attract-mode demo pass and flickered GREEN
	// throughout the ENTIRE capture, not just at the reported title->stage#
	// transition -- a single instantaneous "is audio nonzero right now"
	// check can't tell a genuinely stuck-forever envelope apart from a real
	// OPL2's ordinary Release-phase decay tail, which is not instantaneous
	// after Key-Off. Consulted Gemini on real YM3812 envelope timing: a slow
	// Release Rate is a legitimate, commonly-used music-patch choice and can
	// take several seconds (worst realistic case, tens of seconds for the
	// very slowest RR values) to decay below any fixed audible threshold --
	// so this needs a generous duration margin, not a sub-second one.
	// stuck_audio_duration_100ms counts, in 100ms ticks (@ this module's
	// 48MHz clk -- 4,800,000 cycles/tick, same convention as
	// KEYON_HOLD_THRESHOLD_ALL above), how long ALL 9 channels have stayed
	// continuously Key-Off (NOT how long the amplitude check itself has
	// read true -- that check is a raw AC-waveform threshold that crosses
	// zero at the note's own audio-rate frequency regardless of envelope
	// state, so gating the counter on it directly never accumulates past a
	// few cycles; see the round 111b comment at the implementation for the
	// hardware-confirmed failure this replaced). stuck_envelope_confirmed_ever
	// is a sticky latch that fires only once that Key-Off duration reaches
	// 50 ticks (5.0s) AND the amplitude check is true at that same instant
	// -- i.e. this specific silence period is still audibly ringing 5
	// seconds after the last note ended, comfortably beyond ordinary
	// release tails -- so this is the reliable single-screenshot
	// verdict, while the raw duration counter is just supporting detail.
	output  [7:0] stuck_audio_duration_100ms,
	output        stuck_envelope_confirmed_ever,

	// 2026-08-22, task #8 round 112: chip 2 (ym2) mirror of the round
	// 103/105/111 mechanism -- see the round 112 comment at the
	// ym2_ch_key_on_state_reg implementation. Rounds 103-111 only ever
	// instrumented chip 1; this closes that gap so the whine can be ruled
	// in or out on chip 2 the same rigorous way round 111 just ruled it
	// out on chip 1.
	output  [8:0] ym2_ch_key_on_state,
	output        audio_nonzero_while_ym2_all_keyoff_live_out,
	output  [7:0] stuck_audio_ym2_duration_100ms,
	output        stuck_envelope_ym2_confirmed_ever,

	// 2026-08-22, task #8 round 113: see ym1_ch_car_sl_rr_latch's comment at
	// the implementation. Generalizes round 27/106's channel-0-only SL/RR
	// snapshot to whichever channel was actually last active before a
	// confirmed stuck-audio event -- round 112 implicated channel 4, not
	// channel 0.
	output  [3:0] stuck_channel_index_snapshot,
	output  [7:0] stuck_channel_sl_rr_snapshot,

	// 2026-08-22, task #8 round 114: see ym1_ch_car_sl_rr_written_ever's
	// comment at the implementation. RED = the implicated channel's carrier
	// SL/RR register was NEVER written this session -- the round 113
	// snapshot's 0x00 reading is an unwritten-register artifact, not real
	// data. GREEN = it genuinely was written, so the captured SL/RR value
	// (including a real 0x00) can be trusted.
	output        stuck_channel_sl_rr_was_written,

	// 2026-08-23, task #8 round 137: live (continuously-refreshed)
	// frequency readout for ym2 channels 7 and 8 specifically -- round
	// 136's hardware capture showed these two are the ones reading
	// "audible" at the moment the user hears the whine, and the user's own
	// listening test after round 136's envelope-only fix reported the tone
	// itself changing pitch over time, which no existing diagnostic could
	// check (everything built through round 136 only looks at amplitude/
	// envelope state, never at F-Number/Block). {block[2:0], fnum[9:0]},
	// snooped directly off real register writes to 0xA7/0xB7 (ch7) and
	// 0xA8/0xB8 (ch8), same technique as ym1_ch_car_sl_rr_latch.
	output [12:0] ym2_ch7_freq_live,
	output [12:0] ym2_ch8_freq_live,

	// 2026-08-23, task #8 round 138: round 137's live frequency capture
	// showed ym2 ch7/ch8 constantly changing notes (not frozen on one
	// pitch), which ruled out a literal single stuck note but suggested a
	// different, more specific mechanism instead: envelope decay (volume)
	// and the phase generator (pitch) both read the SAME channel's current
	// register content, so if a channel gets a fresh Key-On for a NEW note
	// before its PREVIOUS note's envelope has actually finished releasing,
	// the old note's leftover volume would keep sounding but immediately
	// take on the NEW note's pitch -- exactly a "held tone that changes
	// pitch" as the channel keeps getting reused through a song. Sticky
	// latch: GREEN if channel 7/8 ever received a real Key-On write while
	// that same channel's own envelope was still reading "audible"
	// (eg_V<700, round 135's threshold) from whatever played immediately
	// before it -- i.e., direct proof of "reused before it finished
	// decaying," independent of which specific instrument is involved.
	output ym2_retrig_while_audible_ch7,
	output ym2_retrig_while_audible_ch8,

	// 2026-08-23, task #8 round 141: a 1-per-second screenshot capture
	// showed all 9 ym1_ch_audible_live bits reading IDENTICAL at every
	// single sampled instant across a 100-second capture, on every
	// channel, not just the two under investigation -- either a real
	// wiring bug (every per-channel register updating off the same shared
	// value instead of its own channel's) or purely a sampling-rate
	// limitation (the real round-robin updates each channel thousands of
	// times per second; if the music genuinely has multiple channels
	// crossing the audible threshold together at a coarse, once-per-
	// second granularity, they could look identical in a 1Hz capture with
	// no bug at all). This settles it without needing higher-resolution
	// screenshots: a sticky latch that catches ANY clock cycle, at full
	// hardware speed, where the 9 channels' audible states actually
	// disagree. GREEN proves they genuinely differ moment-to-moment (the
	// correlation was a sampling artifact); staying RED through a real
	// play session is strong evidence of a genuine wiring bug.
	output ym1_ch_audible_ever_differed,

	// 2026-08-22, task #8 round 115: see ym1_dbg_ch4car_valid_I's comment
	// at the implementation. Live (continuously-refreshed, not edge-gated)
	// readout of channel 4's own internal envelope generator state, so a
	// screenshot taken any time during the confirmed multi-second hang can
	// show exactly what this core's own computation currently is.
	output  [2:0] ch4_state_live,
	output  [5:0] ch4_rate_live,
	output  [3:0] ch4_keycode_live,
	output        ch4_ksr_live,

	// 2026-08-22, task #8 round 121d: see ym1_ch0_state_live_reg's comment
	// -- channel 0's own version of the round-115 ch4 taps above.
	output  [2:0] ch0_state_live,
	output  [5:0] ch0_rate_live,
	output  [3:0] ch0_keycode_live,
	output        ch0_ksr_live,

	// 2026-08-22, task #8 round 122: see ym1_ch0_car_tl_latch's comment --
	// channel 0's own carrier Total Level register, live (not just a
	// single-instant snapshot), plus whether it's ever been written at
	// all (to distinguish a genuine "TL was written to X" reading from an
	// unwritten register's reset default).
	output  [7:0] ch0_car_tl_live,
	output        ch0_car_tl_written_ever,

	// 2026-08-23, task #8 round 128: see ch0_car_sl_rr_live's assign
	// comment -- the LIVE (not frozen-at-first-confirm) value of channel
	// 0's own carrier SL/RR register.
	output  [7:0] ch0_car_sl_rr_live,

	// 2026-08-24, task #8 round 142: round 140 found channel 0's own
	// audible-live bit flickering on and off, unpredictably, for tens of
	// seconds AFTER its one real note already correctly decayed and
	// while it stays genuinely Key-off the whole time (no new Key-on
	// write) -- matching the user's own "sound effects fading in and
	// out" description. Two live, physically-motivated candidate causes,
	// both cheap to expose since they only need already-existing
	// continuously-updated register latches (ym1_ch0_fbcon_latch, round
	// 19; ym1_ch0_egtyp_latch, round 22) wired to new outputs, no new
	// capture logic: (1) CON (register 0xC0 bit0) -- if this channel's
	// currently-loaded instrument is CON=1 (additive), the MODULATOR
	// operator is also routed straight to the output (exactly round
	// 130's own key insight, but never checked for channel 0's specific
	// instrument); (2) AM (register 0x23 bit7, tremolo/amplitude-
	// modulation enable) -- real OPL2 tremolo periodically re-modulates
	// an operator's own attenuation on top of whatever the envelope
	// generator itself is doing, which could plausibly look exactly like
	// a legitimate "fading in and out" even on a channel that has
	// otherwise correctly released, IF this specific instrument enables
	// it. EGT (bit5, already latched by round 22 as ym1_ch0_egtyp_latch)
	// exposed live too (the existing ch0_eg_type_at_keyon only snapshots
	// at each Key-On, not continuously) since a wrong EGT reading here
	// would call round 128's own "percussive, no HOLD self-exit" analysis
	// into question for this exact note.
	output        ch0_con_live,
	output        ch0_am_live,
	output        ch0_egtyp_live,

	// 2026-08-24, task #8 round 142: the user's own instinct ("something
	// most likely isnt latched properly") plus round 74/140's already-
	// documented one-cycle latency mismatch between u_konsh and
	// u_egstate (jtopl_eg.v) motivate a direct test for a genuine
	// internal envelope-generator glitch, rather than continuing to
	// reason indirectly from timing correlations. jtopl_eg_ctrl.v's own
	// state machine only ever (re-)enters ATTACK or DECAY as a direct
	// consequence of a real Key-On pulse (`keyon_now_I`) -- RELEASE has
	// no self-exit and HOLD only exits back to itself or on Key-off/on.
	// So if channel 0's own live envelope state (ch0_state_live, round
	// 121d) is EVER observed in ATTACK(3'b001) or DECAY(3'b010) at a
	// moment this module's OWN independent external Key-On tracking
	// (ym1_ch_key_on_state_reg[0], driven purely by watching the real
	// Z80 bus write to register 0xB0/bit5) says the channel is Key-OFF,
	// that is direct, decisive proof of a spurious internal re-trigger --
	// the envelope generator entering an ATTACK/DECAY cycle with no real
	// external cause, which would explain periodic loud excursions with
	// zero corresponding Key-On write, exactly matching the flicker
	// symptom. A sticky latch (not just a live snapshot) since the
	// mismatch could be many cycles wide even at full clock speed, per
	// round 141's own "screenshots are two orders of magnitude too slow
	// to catch this directly" lesson.
	output        ch0_internal_retrig_no_keyon,

	// 2026-08-24, task #8 round 143: user's real listening test found a
	// specific SFX intermittently produces no audible sound at all
	// ("triggers, then a second of silence, then it's back"). Round 142's
	// existing ym1_ch_audible_live[7]/[8] boolean threshold check (round
	// 121a, `eg_V < 700`) confirmed real Key-On windows where the
	// channel never reads "audible" at all -- but a boolean can't
	// distinguish a genuine envelope-generator bug (the note fails to
	// ever reach a normal loud attenuation) from a legitimately quiet,
	// low-Total-Level sound effect that's simply below this diagnostic's
	// own threshold while still faintly present on real hardware. Live,
	// continuously-refreshed 10-bit readout of channels 7 and 8's own
	// carrier attenuation (the actual `eg_V` value, not a thresholded
	// bit), reusing the already-existing `ym1_dbg_car_ch_valid`/
	// `ym1_dbg_car_ch_num` per-channel identification (round 121) --
	// exactly the same technique as round 115/121d's ch4/ch0 state taps,
	// generalized to channels 7/8 and to the raw attenuation number
	// instead of just state/rate. Only wired for ym1 (chip 1) -- round
	// 143's own capture already found ym1 and ym2 track bit-for-bit
	// identically for these two channels, so a second copy for ym2
	// would add overlay cost without adding real information.
	output  [9:0] ch7_eg_v_live,
	output  [9:0] ch8_eg_v_live,

	// 2026-08-24, task #8 round 144: channels 7/8's own live internal
	// envelope state/rate/keycode/ksr, mirroring ch4_state_live/
	// ch4_rate_live/ch4_keycode_live/ch4_ksr_live (round 115) exactly --
	// the same methodology that found round 68's original AR=15 fix,
	// applied to the two channels round 143's raw eg_V readout found
	// repeatedly parking at a specific mid-scale attenuation instead of
	// decaying to full silence. Uses jtopl.v's new dbg_ch7car_valid_I/
	// dbg_ch8car_valid_I gates (round 144), NOT the general-purpose
	// dbg_car_ch_valid/dbg_car_ch_num -- see that port's comment for why.
	output  [2:0] ch7_state_live,
	output  [5:0] ch7_rate_live,
	output  [3:0] ch7_keycode_live,
	output        ch7_ksr_live,
	output  [2:0] ch8_state_live,
	output  [5:0] ch8_rate_live,
	output  [3:0] ch8_keycode_live,
	output        ch8_ksr_live,

	// 2026-08-22, task #8 round 122: see ym1_reg_b0_recency_100ms_reg's
	// comment -- independent cross-check of ym1_ch_key_on_state_reg[0]'s
	// own tracking, watching register 0xB0 writes directly.
	output  [7:0] ym1_reg_b0_recency_100ms,

	// 2026-08-23, task #8 round 129: see the ch_audible_gen_ym2 generate
	// block's comment -- ym2's own per-channel live audible bit, never
	// previously wired (round 112 only mirrored the coarser Key-On/
	// stuck-duration checks, not round 121's finer per-channel tap).
	output  [8:0] ym2_ch_audible_live,

	// 2026-08-22, task #8 round 116: see ym1_reg_b4_latch/ym1_reg_2c_latch
	// comments at the implementation. Compares against what the ROM's own
	// register writes say keycode/ksr SHOULD be for channel 4, to determine
	// whether round 115's keycode=0/ksr=0 reading is correct (driver
	// intent) or a genuine misread/misrouted-slot bug.
	output  [3:0] ch4_reg_b4_expected_keycode,
	output        ch4_reg_b4_written_ever,
	output        ch4_reg_2c_expected_ksr,
	output        ch4_reg_2c_written_ever,

	// 2026-08-23, task #8 round 131: see dyn_instr_table_addr_reg's
	// comment at the implementation -- the one genuinely dynamic
	// instrument-load call site (ROM 0x0882-0893) reads its table
	// address out of live song data rather than a fixed literal, so
	// round 120/130's static enumeration of all 59 CALL 0x042C sites
	// could never see it. Captures the real address on real hardware
	// and checks it against the same CON=1/RR=0 defect pattern the
	// round 130 fix already addressed for the 5 statically-found
	// tables, to see if the whine's remaining residue after round 130
	// traces to a 6th, previously-invisible defective instrument.
	output        dyn_instr_captured,
	output        dyn_instr_is_defective
);

	//------------------------------------------------------------------------
	// Z80 Signals
	//------------------------------------------------------------------------
	wire [15:0] z80_addr;
	wire  [7:0] z80_dout;
	reg   [7:0] z80_din;
	wire        n_mreq, n_iorq, n_rd, n_wr, n_m1, n_rfsh;
	
	// Sound Interrupt Flip-Flop
	//
	// 2026-08-16: n_m1 was declared above but NEVER actually connected to
	// anything -- cpu_z80.v's port list had no M1 output at all, so this
	// was a fully undriven internal net (synthesizes to a constant, likely
	// making irq_ack permanently 0 or 1 regardless of real Z80 behavior).
	// This is a REAL functional bug, not just a diagnostic artifact: n_int
	// only ever clears via `else if (irq_ack)` below, so with irq_ack stuck
	// wrong, n_int could never deassert after the first sound command,
	// very likely causing a genuine interrupt-retrigger loop that would
	// explain the Z80 never reaching its intended HALT-based idle loop.
	// Fixed by adding a real nM1 output to cpu_z80.v (from T80s's own
	// M1_n port) and connecting it here.
	reg  n_int;
	assign irq_ack = !n_m1 && !n_iorq;
	
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			n_int <= 1'b1;
		end else begin
			if (snd_irq)
				n_int <= 1'b0;      // Assert IRQ on main CPU write to 0x2E18
			else if (irq_ack)
				n_int <= 1'b1;      // Clear IRQ on Z80 interrupt acknowledge
		end
	end

	//------------------------------------------------------------------------
	// Memory Map Decoding (MAME battlnts_state::sound_map)
	// 0x0000 - 0x7FFF : 32KB Sound ROM
	// 0x8000 - 0x87FF : 2KB Work RAM
	// 0xA000 - 0xA001 : YM3812 #1 (OPL2 Chip 1)
	// 0xC000 - 0xC001 : YM3812 #2 (OPL2 Chip 2)
	// 0xE000 - 0xE000 : Sound Latch Read
	//------------------------------------------------------------------------
	wire mem_acc = !n_mreq && n_rfsh;
	wire rom_cs  = mem_acc && (z80_addr < 16'h8000);
	wire ram_cs  = mem_acc && (z80_addr >= 16'h8000 && z80_addr < 16'h8800);
	wire ym1_cs  = mem_acc && (z80_addr >= 16'hA000 && z80_addr <= 16'hA001);
	wire ym2_cs  = mem_acc && (z80_addr >= 16'hC000 && z80_addr <= 16'hC001);
	wire latch_cs= mem_acc && (z80_addr == 16'hE000);

	// 2026-08-17, task #8: OPL2 "Key On" detection. z80_addr[0]==0 (0xA000/
	// 0xC000) is the register-select write, z80_addr[0]==1 (0xA001/0xC001)
	// is the data write -- matches jtopl2's own .addr(z80_addr[0]) port
	// convention already used below. Registers 0xB0-0xB8 are OPL2's
	// Block/F-Number/Key-On registers; bit 5 of the data byte is Key On.
	reg [7:0] last_ym1_addr, last_ym2_addr;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			last_ym1_addr <= 8'h00;
			last_ym2_addr <= 8'h00;
		end else begin
			if (ym1_cs && !n_wr && !z80_addr[0]) last_ym1_addr <= z80_dout;
			if (ym2_cs && !n_wr && !z80_addr[0]) last_ym2_addr <= z80_dout;
		end
	end

	// 2026-08-21, task #8 round 106: see last_ym1_addr_was_83_ever port
	// comment. Same proven technique as round 85's register-0x63 check.
	reg last_ym1_addr_was_83_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			last_ym1_addr_was_83_ever_reg <= 1'b0;
		end else if (last_ym1_addr == 8'h83) begin
			last_ym1_addr_was_83_ever_reg <= 1'b1;
		end
	end
	assign last_ym1_addr_was_83_ever = last_ym1_addr_was_83_ever_reg;

	// 2026-08-22, task #8 round 116: round 115 found channel 4's carrier
	// computes keycode=0/ksr=0, giving jtopl_eg_step.v's "slowest possible
	// decay" rate=2 -- self-consistent arithmetically, but that's too slow
	// to match round 114's MAME cross-check (~1.2s real decay). This checks
	// whether keycode=0/ksr=0 is what the ROM actually WROTE (bug is
	// elsewhere -- e.g. a slot-alignment issue like rounds 69/74 already
	// found and fixed in this exact pipeline) or a genuine misread (the ROM
	// intended a different Block/FNUM/KSR and this core computed the wrong
	// values from it). Register 0xB4 is channel 4's own Key-On/Block/FNUM-hi
	// register (bit5=KeyOn, bits[4:2]=Block, bits[1:0]=FNUM[9:8] -- keycode
	// = {block,fnum[9]} = {reg0xB4[4:2], reg0xB4[1]}, per round 68's own
	// derivation of jtopl_pg_comb.v's formula). Register 0x2C is channel 4's
	// carrier operator's AM/VIB/EGT/KSR/MULT register (0x20 base + carrier
	// offset 0x0C, same operator-offset formula used throughout this file --
	// bit4=KSR). Same proven "was ever written" technique as round 106.
	reg [7:0] ym1_reg_b4_latch;
	reg       ym1_reg_b4_written_ever;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_reg_b4_latch <= 8'h00;
			ym1_reg_b4_written_ever <= 1'b0;
		end else if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'hB4) begin
			ym1_reg_b4_latch <= z80_dout;
			ym1_reg_b4_written_ever <= 1'b1;
		end
	end
	assign ch4_reg_b4_expected_keycode = { ym1_reg_b4_latch[4:2], ym1_reg_b4_latch[1] };
	assign ch4_reg_b4_written_ever = ym1_reg_b4_written_ever;

	reg [7:0] ym1_reg_2c_latch;
	reg       ym1_reg_2c_written_ever;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_reg_2c_latch <= 8'h00;
			ym1_reg_2c_written_ever <= 1'b0;
		end else if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'h2C) begin
			ym1_reg_2c_latch <= z80_dout;
			ym1_reg_2c_written_ever <= 1'b1;
		end
	end
	assign ch4_reg_2c_expected_ksr = ym1_reg_2c_latch[4];
	assign ch4_reg_2c_written_ever = ym1_reg_2c_written_ever;

	// 2026-08-22, task #8 round 122: round 122's cycle-accurate timing
	// model (freshly rebuilt from jtopl_eg_cnt.v/jtopl_slot_cnt.v/
	// jtopl_div.v/jtopl_eg_step.v/jtopl_eg_pure.v, cross-checked against
	// the real YM3812 datasheet's documented 72-master-clock envelope
	// update period) predicts channel 0's actual RR=7/keycode=0/ksr=0 case
	// should fully decay to silence in ~0.52 REAL seconds worst-case --
	// yet hardware showed this exact state holding for 16+ measured
	// seconds, a ~30x unexplained gap. Before assuming a genuine jtopl2
	// timing bug, checking the other direction per the user's own
	// suggestion: does the real ROM driver ever explicitly mute channel 0
	// (e.g. a Total Level write, independent of relying on the envelope's
	// own natural release) around this transition that this core might be
	// failing to apply? Register 0x43 is channel 0's own carrier Total
	// Level register (0x40 TL base + carrier offset 3, same operator-
	// offset formula used throughout this file, group=0/subslot=3 per the
	// existing dbg_ch0car_valid gate). Same proven "was ever written"
	// technique as round 106/116, but a LIVE mirror (not gated to a single
	// snapshot instant) so its value can be read at any point during the
	// stuck window, not just at the exact moment of a specific edge.
	reg [7:0] ym1_ch0_car_tl_latch;
	reg       ym1_ch0_car_tl_written_ever;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_car_tl_latch <= 8'h00;
			ym1_ch0_car_tl_written_ever <= 1'b0;
		end else if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'h43) begin
			ym1_ch0_car_tl_latch <= z80_dout;
			ym1_ch0_car_tl_written_ever <= 1'b1;
		end
	end
	assign ch0_car_tl_live = ym1_ch0_car_tl_latch;
	assign ch0_car_tl_written_ever = ym1_ch0_car_tl_written_ever;

	// 2026-08-23, task #8 round 128: round 127's long-window capture found
	// channel 0 genuinely Key-On for a real ~20s musical phrase (t=9-29,
	// keycode=14), THEN Key-Off from t=30 onward while its internal
	// state/rate kept showing activity continuously through the entire
	// rest of a 75s capture -- matching the user's own real-time report of
	// a continuous tone persisting from the transition through the Green
	// screen and faintly into the Score screen. Round 121c/d's SL/RR
	// snapshot (0x17, SL=1/RR=7) was captured at an EARLIER, likely
	// unrelated stuck-confirm edge -- this exposes the LIVE (continuously
	// current, not frozen-at-first-confirm) value of the SAME existing
	// ym1_ch_car_sl_rr_latch (round 113) for channel 0 specifically, to
	// see its REAL register value at the moment THIS note's own Key-Off
	// actually happens.
	assign ch0_car_sl_rr_live = ym1_ch_car_sl_rr_latch[7:0];

	// 2026-08-22, task #8 round 122: independent cross-check of the
	// existing ym1_ch_key_on_state_reg[0] tracking itself (per the user's
	// request to verify this before trusting the ~30x timing gap as a real
	// jtopl2 bug) -- a duration-since-last-write counter watching register
	// 0xB0 (channel 0's own Key-On/Block/FNUM-hi register) DIRECTLY via the
	// same last_ym1_addr decode already used for ym1_ch_key_on_state_reg's
	// own update condition, completely independent of that register's own
	// bit5-extraction logic. If this counter reaches the same large values
	// as the existing per-channel stuck-duration counter (ch_audible_gen[0]
	// .ch_stuck_dur_100ms), that confirms register 0xB0 genuinely was never
	// written during the stuck window (the existing tracking is correct).
	// If it's shorter, that reveals a real decode bug in the existing
	// tracking instead.
	reg [22:0] ym1_reg_b0_recency_tick_cnt;
	reg [7:0]  ym1_reg_b0_recency_100ms_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_reg_b0_recency_tick_cnt <= 23'd0;
			ym1_reg_b0_recency_100ms_reg <= 8'd0;
		end else if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'hB0) begin
			ym1_reg_b0_recency_tick_cnt <= 23'd0;
			ym1_reg_b0_recency_100ms_reg <= 8'd0;
		end else begin
			if (ym1_reg_b0_recency_tick_cnt >= 23'd4_800_000 - 23'd1) begin // 100ms @ 48MHz, matches STUCK_AUDIO_TICK_CYCLES
				ym1_reg_b0_recency_tick_cnt <= 23'd0;
				if (ym1_reg_b0_recency_100ms_reg != 8'hFF)
					ym1_reg_b0_recency_100ms_reg <= ym1_reg_b0_recency_100ms_reg + 8'd1;
			end else begin
				ym1_reg_b0_recency_tick_cnt <= ym1_reg_b0_recency_tick_cnt + 23'd1;
			end
		end
	end
	assign ym1_reg_b0_recency_100ms = ym1_reg_b0_recency_100ms_reg;

	wire ym1_key_on = ym1_cs && !n_wr && z80_addr[0] &&
	                  (last_ym1_addr >= 8'hB0 && last_ym1_addr <= 8'hB8) && z80_dout[5];

	// 2026-08-21, task #8 round 103: see ym1_ch_key_on_state port comment.
	reg [8:0] ym1_ch_key_on_state_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch_key_on_state_reg <= 9'b0;
		end else if (ym1_cs && !n_wr && z80_addr[0] &&
		             last_ym1_addr >= 8'hB0 && last_ym1_addr <= 8'hB8) begin
			ym1_ch_key_on_state_reg[last_ym1_addr - 8'hB0] <= z80_dout[5];
		end
	end
	assign ym1_ch_key_on_state = ym1_ch_key_on_state_reg;

	// 2026-08-21, task #8 round 104: see ym1_ch_keyon_held_100ms port
	// comment. Generalizes the existing single-channel pattern (see
	// ym1_ch0_keyon_held_100ms below) to all 9 channels via a generate
	// block, same 100ms@48MHz threshold.
	localparam [22:0] KEYON_HOLD_THRESHOLD_ALL = 23'd4_800_000;
	genvar gc;
	generate
		for (gc = 0; gc < 9; gc = gc + 1) begin : keyon_hold_gen
			reg [22:0] hold_cnt;
			reg        active;
			reg        held_100ms;
			wire       b_write = ym1_cs && !n_wr && z80_addr[0] &&
			                     (last_ym1_addr == (8'hB0 + gc));
			always @(posedge clk or posedge rst) begin
				if (rst) begin
					hold_cnt   <= 23'd0;
					active     <= 1'b0;
					held_100ms <= 1'b0;
				end else if (b_write) begin
					if (active && (hold_cnt >= KEYON_HOLD_THRESHOLD_ALL))
						held_100ms <= 1'b1;
					active   <= z80_dout[5];
					hold_cnt <= 23'd0;
				end else if (active) begin
					if (hold_cnt >= KEYON_HOLD_THRESHOLD_ALL)
						held_100ms <= 1'b1;
					else
						hold_cnt <= hold_cnt + 1'b1;
				end
			end
			assign ym1_ch_keyon_held_100ms[gc] = held_100ms;
		end
	endgenerate

	// 2026-08-21, task #8 round 105: see audio_nonzero_while_all_keyoff_ever
	// port comment. Threshold of 256 matches the existing ym1_snd_mag_gt256
	// convention already used elsewhere in this file for "clearly audible,
	// not just residual noise."
	reg audio_nonzero_while_all_keyoff_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			audio_nonzero_while_all_keyoff_ever_reg <= 1'b0;
		end else if ((ym1_ch_key_on_state_reg == 9'b0) &&
		             ((ym1_snd > 16'sd256) || (ym1_snd < -16'sd256))) begin
			audio_nonzero_while_all_keyoff_ever_reg <= 1'b1;
		end
	end
	assign audio_nonzero_while_all_keyoff_ever = audio_nonzero_while_all_keyoff_ever_reg;

	// 2026-08-21, task #8 round 107: see ch0_sl_rr_at_stuck_audio_snapshot
	// port comment. Edge-detected on the LIVE (not sticky) condition so
	// this captures the exact instant the stuck-audio state first occurs,
	// not some arbitrary later moment.
	wire audio_nonzero_while_all_keyoff_live = (ym1_ch_key_on_state_reg == 9'b0) &&
	             ((ym1_snd > 16'sd256) || (ym1_snd < -16'sd256));
	reg audio_nonzero_while_all_keyoff_live_prev;
	reg [7:0] ch0_sl_rr_at_stuck_audio_snapshot_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			audio_nonzero_while_all_keyoff_live_prev <= 1'b0;
			ch0_sl_rr_at_stuck_audio_snapshot_reg <= 8'hE5;
		end else begin
			audio_nonzero_while_all_keyoff_live_prev <= audio_nonzero_while_all_keyoff_live;
			if (audio_nonzero_while_all_keyoff_live && !audio_nonzero_while_all_keyoff_live_prev)
				ch0_sl_rr_at_stuck_audio_snapshot_reg <= ym1_ch0_sl_rr_latch;
		end
	end
	assign ch0_sl_rr_at_stuck_audio_snapshot = ch0_sl_rr_at_stuck_audio_snapshot_reg;
	assign audio_nonzero_while_all_keyoff_live_out = audio_nonzero_while_all_keyoff_live;

	// 2026-08-22, task #8 round 111b: see stuck_audio_duration_100ms /
	// stuck_envelope_confirmed_ever port comments. First attempt at this
	// diagnostic (round 111a) gated the duration counter on
	// audio_nonzero_while_all_keyoff_live itself and reset it every cycle
	// that condition read false -- but that condition is a raw amplitude
	// threshold on an AC audio waveform, which crosses back through +-256
	// at the note's own (audio-rate) frequency regardless of whether the
	// envelope is decaying normally or genuinely stuck. Hardware confirmed
	// this: the duration counter never accumulated past a handful of
	// cycles even during an 11-second span where the live flag itself read
	// GREEN on every 1-second sample. Fixed by gating the duration counter
	// on the much lower-frequency all-channels-Key-Off condition instead
	// (only changes on real Key-On/Key-Off writes, not every audio
	// zero-crossing), and only latching the sticky "confirmed" flag once
	// that duration has run 5.0s AND the amplitude check is true at that
	// same instant -- i.e. "is this specific channel-off period still
	// audibly ringing 5 seconds after the last note ended," which correctly
	// tolerates the waveform's own oscillation instead of being defeated by
	// it.
	wire all_keyoff = (ym1_ch_key_on_state_reg == 9'b0);
	localparam [22:0] STUCK_AUDIO_TICK_CYCLES = 23'd4_800_000; // 100ms @ 48MHz
	localparam [7:0]  STUCK_AUDIO_CONFIRM_TICKS = 8'd50;       // 5.0s
	reg [22:0] stuck_audio_tick_cnt;
	reg [7:0]  stuck_audio_duration_100ms_reg;
	reg        stuck_envelope_confirmed_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			stuck_audio_tick_cnt <= 23'd0;
			stuck_audio_duration_100ms_reg <= 8'd0;
			stuck_envelope_confirmed_ever_reg <= 1'b0;
		end else if (all_keyoff) begin
			if (stuck_audio_tick_cnt >= STUCK_AUDIO_TICK_CYCLES - 23'd1) begin
				stuck_audio_tick_cnt <= 23'd0;
				if (stuck_audio_duration_100ms_reg != 8'hFF)
					stuck_audio_duration_100ms_reg <= stuck_audio_duration_100ms_reg + 8'd1;
			end else begin
				stuck_audio_tick_cnt <= stuck_audio_tick_cnt + 23'd1;
			end
			if ((stuck_audio_duration_100ms_reg >= STUCK_AUDIO_CONFIRM_TICKS) &&
			    audio_nonzero_while_all_keyoff_live)
				stuck_envelope_confirmed_ever_reg <= 1'b1;
		end else begin
			stuck_audio_tick_cnt <= 23'd0;
			stuck_audio_duration_100ms_reg <= 8'd0;
			// stuck_envelope_confirmed_ever_reg deliberately stays latched
		end
	end
	assign stuck_audio_duration_100ms = stuck_audio_duration_100ms_reg;
	assign stuck_envelope_confirmed_ever = stuck_envelope_confirmed_ever_reg;

	wire ym2_key_on = ym2_cs && !n_wr && z80_addr[0] &&
	                  (last_ym2_addr >= 8'hB0 && last_ym2_addr <= 8'hB8) && z80_dout[5];
	assign key_on_triggered = ym1_key_on || ym2_key_on;

	// 2026-08-22, task #8 round 112: rounds 103-111's entire stuck-envelope
	// investigation (Key-On row, audio_nonzero_while_all_keyoff, the round
	// 111 duration/confirmed diagnostic) was scoped exclusively to chip 1
	// (ym1) -- round 28's own comment above (2026-08-18, well before this
	// whine investigation began) already flagged that chip 2 (ym2) "has
	// never been instrumented at all this session," and that gap was never
	// closed for the whine work either. Round 111 found a clean, confirmed
	// negative for chip 1 (audio genuinely reached and stayed at true
	// silence across 100+ seconds of continuous chip-1 Key-Off, sticky
	// confirm never fired) -- but that only rules chip 1 out. If the note
	// the user hears "hang" at the title->stage# transition is actually
	// being played on chip 2, none of rounds 103-111 could ever have
	// detected it. This mirrors the exact same per-channel Key-On state +
	// duration/confirmed mechanism for chip 2.
	reg [8:0] ym2_ch_key_on_state_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym2_ch_key_on_state_reg <= 9'b0;
		end else if (ym2_cs && !n_wr && z80_addr[0] &&
		             last_ym2_addr >= 8'hB0 && last_ym2_addr <= 8'hB8) begin
			ym2_ch_key_on_state_reg[last_ym2_addr - 8'hB0] <= z80_dout[5];
		end
	end
	assign ym2_ch_key_on_state = ym2_ch_key_on_state_reg;

	wire ym2_all_keyoff = (ym2_ch_key_on_state_reg == 9'b0);
	wire audio_nonzero_while_ym2_all_keyoff_live = ym2_all_keyoff &&
	             ((ym2_snd > 16'sd256) || (ym2_snd < -16'sd256));

	// 2026-08-23, task #8 round 137: live F-Number/Block for ym2 channels
	// 7 and 8 -- see the port declaration's comment. FNUM low byte comes
	// from register 0xA7/0xA8, FNUM high 2 bits + Block come from
	// 0xB7/0xB8 (the same register that also carries Key-On, bit 5).
	reg [7:0] ym2_ch7_fnum_lo, ym2_ch8_fnum_lo;
	reg [7:0] ym2_ch7_b_reg,   ym2_ch8_b_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym2_ch7_fnum_lo <= 8'h00;
			ym2_ch8_fnum_lo <= 8'h00;
			ym2_ch7_b_reg   <= 8'h00;
			ym2_ch8_b_reg   <= 8'h00;
		end else if (ym2_cs && !n_wr && z80_addr[0]) begin
			if (last_ym2_addr == 8'hA7) ym2_ch7_fnum_lo <= z80_dout;
			if (last_ym2_addr == 8'hA8) ym2_ch8_fnum_lo <= z80_dout;
			if (last_ym2_addr == 8'hB7) ym2_ch7_b_reg   <= z80_dout;
			if (last_ym2_addr == 8'hB8) ym2_ch8_b_reg   <= z80_dout;
		end
	end
	assign ym2_ch7_freq_live = {ym2_ch7_b_reg[4:2], ym2_ch7_b_reg[1:0], ym2_ch7_fnum_lo};
	assign ym2_ch8_freq_live = {ym2_ch8_b_reg[4:2], ym2_ch8_b_reg[1:0], ym2_ch8_fnum_lo};

	// 2026-08-23, task #8 round 138: see ym2_retrig_while_audible_ch7/8's
	// port comment. Sampled the same cycle as the real Key-On write, before
	// it has propagated through jtopl's shift-register pipeline, so
	// ym2_ch_audible_live[7]/[8] here still reflects the OLD note.
	wire ym2_ch7_new_keyon = ym2_cs && !n_wr && z80_addr[0] &&
	                          (last_ym2_addr == 8'hB7) && z80_dout[5];
	wire ym2_ch8_new_keyon = ym2_cs && !n_wr && z80_addr[0] &&
	                          (last_ym2_addr == 8'hB8) && z80_dout[5];
	reg retrig_while_audible_ch7_reg, retrig_while_audible_ch8_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			retrig_while_audible_ch7_reg <= 1'b0;
			retrig_while_audible_ch8_reg <= 1'b0;
		end else begin
			if (ym2_ch7_new_keyon && ym2_ch_audible_live[7]) retrig_while_audible_ch7_reg <= 1'b1;
			if (ym2_ch8_new_keyon && ym2_ch_audible_live[8]) retrig_while_audible_ch8_reg <= 1'b1;
		end
	end
	assign ym2_retrig_while_audible_ch7 = retrig_while_audible_ch7_reg;
	assign ym2_retrig_while_audible_ch8 = retrig_while_audible_ch8_reg;
	assign audio_nonzero_while_ym2_all_keyoff_live_out = audio_nonzero_while_ym2_all_keyoff_live;

	reg [22:0] stuck_audio_ym2_tick_cnt;
	reg [7:0]  stuck_audio_ym2_duration_100ms_reg;
	reg        stuck_envelope_ym2_confirmed_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			stuck_audio_ym2_tick_cnt <= 23'd0;
			stuck_audio_ym2_duration_100ms_reg <= 8'd0;
			stuck_envelope_ym2_confirmed_ever_reg <= 1'b0;
		end else if (ym2_all_keyoff) begin
			if (stuck_audio_ym2_tick_cnt >= STUCK_AUDIO_TICK_CYCLES - 23'd1) begin
				stuck_audio_ym2_tick_cnt <= 23'd0;
				if (stuck_audio_ym2_duration_100ms_reg != 8'hFF)
					stuck_audio_ym2_duration_100ms_reg <= stuck_audio_ym2_duration_100ms_reg + 8'd1;
			end else begin
				stuck_audio_ym2_tick_cnt <= stuck_audio_ym2_tick_cnt + 23'd1;
			end
			if ((stuck_audio_ym2_duration_100ms_reg >= STUCK_AUDIO_CONFIRM_TICKS) &&
			    audio_nonzero_while_ym2_all_keyoff_live)
				stuck_envelope_ym2_confirmed_ever_reg <= 1'b1;
		end else begin
			stuck_audio_ym2_tick_cnt <= 23'd0;
			stuck_audio_ym2_duration_100ms_reg <= 8'd0;
			// stuck_envelope_ym2_confirmed_ever_reg deliberately stays latched
		end
	end
	assign stuck_audio_ym2_duration_100ms = stuck_audio_ym2_duration_100ms_reg;
	assign stuck_envelope_ym2_confirmed_ever = stuck_envelope_ym2_confirmed_ever_reg;

	// 2026-08-22, task #8 round 113: round 112's confirmed stuck-audio event
	// implicated channel 4, not channel 0 -- round 27/106's existing SL/RR
	// latch only ever watched register 0x83 (channel 0's own carrier
	// operator). Generalizes that to all 9 channels using OPL2's real
	// operator-offset table (group=ch/3, sub=ch%3, carrier offset =
	// group*8+sub+3, so e.g. channel 4 -> offset 0x0C -> register 0x8C) so a
	// future stuck event on any other channel is captured the same way,
	// per this project's standing preference for generic/dynamic logic over
	// hardcoding to one specific channel.
	// 2026-08-22, task #8 round 114: round 113's per-channel latch array
	// reset to 8'h00, the same value as a real "SL=0,RR=0" reading -- unlike
	// round 107's ch0_sl_rr_at_stuck_audio_snapshot, which deliberately
	// reset to the sentinel 8'hE5 so its default couldn't be mistaken for
	// real captured data (this project's own established discipline for
	// exactly this failure mode). Round 113's array didn't carry that
	// convention over, so its 0x00 reading for channel 4 was ambiguous:
	// real hardware value, or an unwritten register's untouched reset
	// default. Adds a per-channel sticky "was this channel's own carrier
	// SL/RR register ever written" bit, mirroring round 106's exact
	// technique (last_ym1_addr_was_83_ever) but generalized to whichever
	// channel gets implicated, so that ambiguity can be resolved for any
	// future stuck-channel event, not just channel 4 specifically.
	wire [71:0] ym1_ch_car_sl_rr_latch;
	reg  [8:0]  ym1_ch_car_sl_rr_written_ever;
	genvar gs;
	generate
		for (gs = 0; gs < 9; gs = gs + 1) begin : ch_sl_rr_gen
			localparam [7:0] SL_RR_REG = 8'h80 + ((gs/3)*8) + (gs%3) + 3;
			reg [7:0] sl_rr_latch;
			always @(posedge clk or posedge rst) begin
				if (rst) begin
					sl_rr_latch <= 8'h00;
					ym1_ch_car_sl_rr_written_ever[gs] <= 1'b0;
				end else if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == SL_RR_REG) begin
					sl_rr_latch <= z80_dout;
					ym1_ch_car_sl_rr_written_ever[gs] <= 1'b1;
				end
			end
			assign ym1_ch_car_sl_rr_latch[gs*8 +: 8] = sl_rr_latch;
		end
	endgenerate

	// 2026-08-22, task #8 round 121: see ym1_ch_audible_live's port
	// comment above. For each of the 9 real channels, latches whether
	// THAT channel's own carrier envelope currently reads below the
	// eg_V<256 audible threshold, updated every time ym1_dbg_car_ch_valid
	// identifies dbg_eg_V as belonging to that channel's carrier (once per
	// 18-cenop round-robin loop) and held between updates -- same "live,
	// continuously refreshed" convention as round 115's ch4_state_live/
	// ch4_rate_live.
	//
	// 2026-08-22, task #8 round 121b: a first hardware capture using just
	// the live bit above came back essentially noisy across every
	// channel (0,1,2,3,4,6,7,8 all showed "audible" at one sampled instant
	// or another) -- because EVERY music channel's own attenuation
	// legitimately dips below 256 constantly during ordinary, correct
	// note playback. A single-instant snapshot can't tell "genuinely
	// stuck" from "just playing a loud note right now"; it needs the same
	// duration/persistence requirement as the existing GLOBAL check
	// (stuck_audio_duration_100ms/stuck_envelope_confirmed_ever, round
	// 111b), just scoped to each channel's own Key-On instead of ALL
	// channels' Key-On. ym1_ch_stuck_confirmed[N] latches once channel N
	// has read Key-Off AND audible continuously for
	// STUCK_AUDIO_CONFIRM_TICKS (5.0s) -- the real, unambiguous "which
	// channel is actually stuck" signal.
	genvar ga;
	generate
		for (ga = 0; ga < 9; ga = ga + 1) begin : ch_audible_gen
			reg audible_live;
			reg [22:0] ch_stuck_tick_cnt;
			reg [7:0]  ch_stuck_dur_100ms;
			reg        ch_stuck_confirmed_ever;
			wire ch_keyoff = !ym1_ch_key_on_state_reg[ga];

			always @(posedge clk or posedge rst) begin
				if (rst) begin
					audible_live <= 1'b0;
				end else if (ym1_dbg_car_ch_valid && (ym1_dbg_car_ch_num == ga[3:0])) begin
					// 2026-08-23, task #8 round 135: widened from 10'd256 --
					// OPL2's attenuation scale is logarithmic, not linear, so
					// a channel sitting just above the old, arbitrary 256
					// cutoff (out of a max ~1023) could still contribute real,
					// perceptible amplitude to the final summed mix even
					// though every per-channel check all session called it
					// "silent". Testing whether a much more permissive
					// threshold reveals a channel that was invisible before,
					// per the user's "process of elimination" direction.
					audible_live <= (ym1_dbg_eg_V < 10'd700);
				end
			end
			assign ym1_ch_audible_live[ga] = audible_live;

			always @(posedge clk or posedge rst) begin
				if (rst) begin
					ch_stuck_tick_cnt <= 23'd0;
					ch_stuck_dur_100ms <= 8'd0;
					ch_stuck_confirmed_ever <= 1'b0;
				end else if (ch_keyoff) begin
					if (ch_stuck_tick_cnt >= STUCK_AUDIO_TICK_CYCLES - 23'd1) begin
						ch_stuck_tick_cnt <= 23'd0;
						if (ch_stuck_dur_100ms != 8'hFF)
							ch_stuck_dur_100ms <= ch_stuck_dur_100ms + 8'd1;
					end else begin
						ch_stuck_tick_cnt <= ch_stuck_tick_cnt + 23'd1;
					end
					if ((ch_stuck_dur_100ms >= STUCK_AUDIO_CONFIRM_TICKS) && audible_live)
						ch_stuck_confirmed_ever <= 1'b1;
				end else begin
					ch_stuck_tick_cnt <= 23'd0;
					ch_stuck_dur_100ms <= 8'd0;
					// ch_stuck_confirmed_ever deliberately stays latched
				end
			end
			assign ym1_ch_stuck_confirmed[ga] = ch_stuck_confirmed_ever;

			// 2026-08-22, task #8 round 121c: found (via a fresh-reload,
			// 1s-interval capture) that channels 1-8 all read "confirmed"
			// from the very first post-reload screenshot -- almost
			// certainly a reset/boot-silence artifact (envelope state
			// before any real note has ever played), not a real bug.
			// Channel 0 alone stayed clean through the whole title screen
			// and then flipped to confirmed at exactly t=18s, matching
			// round 119's independent real-audio acoustic measurement of
			// the whine's own start time precisely. Snapshots THIS
			// channel's own carrier SL/RR register (from the already-
			// existing ym1_ch_car_sl_rr_latch, round 113) at the exact
			// edge this channel's own ch_stuck_confirmed_ever first sets,
			// mirroring round 113's snapshot technique but keyed on each
			// channel's own real confirm event instead of the ambiguous
			// "last channel to go key-off" heuristic.
			reg [7:0] stuck_sl_rr_snapshot;
			reg       ch_stuck_confirmed_prev;
			always @(posedge clk or posedge rst) begin
				if (rst) begin
					stuck_sl_rr_snapshot <= 8'hE5; // sentinel, round 107's convention
					ch_stuck_confirmed_prev <= 1'b0;
				end else begin
					ch_stuck_confirmed_prev <= ch_stuck_confirmed_ever;
					if (ch_stuck_confirmed_ever && !ch_stuck_confirmed_prev)
						stuck_sl_rr_snapshot <= ym1_ch_car_sl_rr_latch[ga*8 +: 8];
				end
			end
			assign ym1_ch_stuck_sl_rr_snapshot[ga*8 +: 8] = stuck_sl_rr_snapshot;
		end
	endgenerate

	// 2026-08-23, task #8 round 141: see ym1_ch_audible_ever_differed's
	// port comment. Sampled every clock cycle, full hardware speed --
	// not gated by any screenshot/overlay refresh rate.
	reg ym1_ch_audible_ever_differed_reg;
	always @(posedge clk or posedge rst) begin
		if (rst)
			ym1_ch_audible_ever_differed_reg <= 1'b0;
		else if (|(ym1_ch_audible_live ^ {9{ym1_ch_audible_live[0]}}))
			ym1_ch_audible_ever_differed_reg <= 1'b1;
	end
	assign ym1_ch_audible_ever_differed = ym1_ch_audible_ever_differed_reg;

	// Tracks which channel most recently had a real Key-On(=1) write, so
	// whichever channel was actually playing right before a stuck-audio
	// event can be identified without assuming it's always channel 0 (or
	// always channel 4 -- round 112's result was itself just one instance).
	reg [3:0] ym1_last_keyon_ch;
	wire [7:0] ym1_keyon_ch_delta = last_ym1_addr - 8'hB0;
	always @(posedge clk or posedge rst) begin
		if (rst)
			ym1_last_keyon_ch <= 4'hF; // sentinel: no Key-On seen yet
		else if (ym1_cs && !n_wr && z80_addr[0] &&
		         last_ym1_addr >= 8'hB0 && last_ym1_addr <= 8'hB8 && z80_dout[5])
			// 2026-09-02, task #77: explicit 4-bit slice (via an 8-bit
			// intermediate wire, since a part-select of a parenthesized
			// expression is SystemVerilog-only and Verilator's plain
			// Verilog-2001 parser rejects it) instead of an 8-bit
			// subtraction result assigned into a 4-bit reg -- silences
			// Quartus's truncation warning (10230). Same value: the guard
			// above already bounds the result to 0-8.
			ym1_last_keyon_ch <= ym1_keyon_ch_delta[3:0];
	end

	// Snapshots the last-active channel's index and its own carrier SL/RR
	// value at the exact instant stuck_envelope_confirmed_ever's own set
	// condition first fires (edge-detected, same technique as round 107's
	// ch0_sl_rr_at_stuck_audio_snapshot) -- by the time this can fire,
	// ym1_last_keyon_ch is guaranteed already valid (all_keyoff having held
	// 5+ seconds requires at least one prior real Key-On/Key-Off cycle).
	wire stuck_confirm_set_cond = all_keyoff &&
	             (stuck_audio_duration_100ms_reg >= STUCK_AUDIO_CONFIRM_TICKS) &&
	             audio_nonzero_while_all_keyoff_live;
	reg stuck_confirm_set_cond_prev;
	reg [3:0] stuck_channel_index_snapshot_reg;
	reg [7:0] stuck_channel_sl_rr_snapshot_reg;
	reg       stuck_channel_sl_rr_was_written_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			stuck_confirm_set_cond_prev <= 1'b0;
			stuck_channel_index_snapshot_reg <= 4'hF;
			stuck_channel_sl_rr_snapshot_reg <= 8'hE5;
			stuck_channel_sl_rr_was_written_reg <= 1'b0;
		end else begin
			stuck_confirm_set_cond_prev <= stuck_confirm_set_cond;
			if (stuck_confirm_set_cond && !stuck_confirm_set_cond_prev) begin
				stuck_channel_index_snapshot_reg <= ym1_last_keyon_ch;
				stuck_channel_sl_rr_snapshot_reg <= ym1_ch_car_sl_rr_latch[ym1_last_keyon_ch*8 +: 8];
				stuck_channel_sl_rr_was_written_reg <= ym1_ch_car_sl_rr_written_ever[ym1_last_keyon_ch];
			end
		end
	end
	assign stuck_channel_index_snapshot = stuck_channel_index_snapshot_reg;
	assign stuck_channel_sl_rr_snapshot = stuck_channel_sl_rr_snapshot_reg;
	assign stuck_channel_sl_rr_was_written = stuck_channel_sl_rr_was_written_reg;

	// 2026-08-22, task #8 round 115: round 114 confirmed channel 4's own
	// carrier SL/RR register genuinely holds RR=0, and a real-MAME
	// cross-check proved this exact note decays cleanly (~1.2s) on correct
	// hardware -- so this is a genuine core defect. jtopl_eg_ctrl.v's
	// base_rate={rrate,1'b1} means RR=0 still yields a finite base_rate=1,
	// not zero, so "RR=0 never decays" isn't the actual mechanism -- the
	// real question is what this core's own state/rate/keycode/ksr compute
	// to for channel 4 right now, live, continuously refreshed every time
	// its own carrier slot comes around in the 18-slot round-robin (not
	// gated to the exact stuck-confirm instant -- rounds 112-114 already
	// established the hang persists for many seconds, so a plain live
	// readout captured any time during that window answers the same
	// question with far simpler logic). ym1_dbg_ch4car_valid_I mirrors
	// ym1_dbg_ch0car_valid_I exactly (see jtopl.v's port comment);
	// state_in_I is a "stage I" signal (same cycle as the valid gate),
	// rate_II/keycode_II/ksr_II are "stage II" (need the same 1-cycle
	// _d1 delay round 68 already established for dbg_rate_II).
	reg ym1_dbg_ch4car_valid_I_d1;
	always @(posedge clk) if (ym1_dbg_cenop) ym1_dbg_ch4car_valid_I_d1 <= ym1_dbg_ch4car_valid_I;

	reg [2:0] ym1_ch4_state_live_reg;
	reg [5:0] ym1_ch4_rate_live_reg;
	reg [3:0] ym1_ch4_keycode_live_reg;
	reg       ym1_ch4_ksr_live_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch4_state_live_reg <= 3'b000;
			ym1_ch4_rate_live_reg <= 6'd0;
			ym1_ch4_keycode_live_reg <= 4'd0;
			ym1_ch4_ksr_live_reg <= 1'b0;
		end else begin
			if (ym1_dbg_ch4car_valid_I)
				ym1_ch4_state_live_reg <= ym1_dbg_state_in_I;
			if (ym1_dbg_ch4car_valid_I_d1) begin
				ym1_ch4_rate_live_reg <= ym1_dbg_rate_II;
				ym1_ch4_keycode_live_reg <= ym1_dbg_keycode_II;
				ym1_ch4_ksr_live_reg <= ym1_dbg_ksr_II;
			end
		end
	end
	assign ch4_state_live = ym1_ch4_state_live_reg;
	assign ch4_rate_live = ym1_ch4_rate_live_reg;
	assign ch4_keycode_live = ym1_ch4_keycode_live_reg;
	assign ch4_ksr_live = ym1_ch4_ksr_live_reg;

	// 2026-08-22, task #8 round 121d: same live tap as ch4_state_live/
	// ch4_rate_live/ch4_keycode_live/ch4_ksr_live above, but for channel 0
	// -- round 121c's timing sweep found channel 0 (not channel 4) is the
	// real stuck channel matching the whine's actual t=18s start time, and
	// its own SL/RR snapshot read 0x17 (SL=1, RR=7) -- a real, deliberate-
	// looking register value, not an obviously "broken" RR=0 the way
	// channel 4's was. This checks whether jtopl2's own internal
	// keycode/ksr scaling still computes an anomalously slow rate for
	// this genuinely different RR value, using the ALREADY-EXISTING
	// ym1_dbg_ch0car_valid_I gate (round 40) -- no new jtopl.v wiring
	// needed. Reuses the ALREADY-EXISTING ym1_dbg_ch0car_valid_I_d1
	// register (declared further below for round 68's own AR=15
	// diagnostics) rather than re-declaring it.
	reg [2:0] ym1_ch0_state_live_reg;
	reg [5:0] ym1_ch0_rate_live_reg;
	reg [3:0] ym1_ch0_keycode_live_reg;
	reg       ym1_ch0_ksr_live_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_state_live_reg <= 3'b000;
			ym1_ch0_rate_live_reg <= 6'd0;
			ym1_ch0_keycode_live_reg <= 4'd0;
			ym1_ch0_ksr_live_reg <= 1'b0;
		end else begin
			if (ym1_dbg_ch0car_valid_I)
				ym1_ch0_state_live_reg <= ym1_dbg_state_in_I;
			if (ym1_dbg_ch0car_valid_I_d1) begin
				ym1_ch0_rate_live_reg <= ym1_dbg_rate_II;
				ym1_ch0_keycode_live_reg <= ym1_dbg_keycode_II;
				ym1_ch0_ksr_live_reg <= ym1_dbg_ksr_II;
			end
		end
	end
	assign ch0_state_live = ym1_ch0_state_live_reg;
	assign ch0_rate_live = ym1_ch0_rate_live_reg;
	assign ch0_keycode_live = ym1_ch0_keycode_live_reg;
	assign ch0_ksr_live = ym1_ch0_ksr_live_reg;

	// 2026-08-24, task #8 round 142: see ch0_con_live's port comment.
	// Both reuse already-existing, continuously-updated register latches
	// (ym1_ch0_fbcon_latch, round 19; ym1_ch0_egtyp_latch, round 22) --
	// no new register-write monitoring needed.
	assign ch0_con_live   = ym1_ch0_fbcon_latch[0];
	assign ch0_am_live    = ym1_ch0_egtyp_latch[7];
	assign ch0_egtyp_live = ym1_ch0_egtyp_latch[5];

	// 2026-08-24, task #8 round 142: see ch0_internal_retrig_no_keyon's
	// port comment. jtopl_eg_ctrl.v's state encoding (confirmed directly
	// in that file): ATTACK=3'b001, DECAY=3'b010, HOLD=3'b100,
	// RELEASE=3'b000 (the default/reset state).
	reg ch0_internal_retrig_no_keyon_reg;
	always @(posedge clk or posedge rst) begin
		if (rst)
			ch0_internal_retrig_no_keyon_reg <= 1'b0;
		else if (!ym1_ch_key_on_state_reg[0] &&
		         ((ym1_ch0_state_live_reg == 3'b001) || (ym1_ch0_state_live_reg == 3'b010)))
			ch0_internal_retrig_no_keyon_reg <= 1'b1;
	end
	assign ch0_internal_retrig_no_keyon = ch0_internal_retrig_no_keyon_reg;

	// 2026-08-24, task #8 round 143: see ch7_eg_v_live's port comment.
	// Reuses the already-existing ym1_dbg_car_ch_valid/ym1_dbg_car_ch_num
	// per-channel identification (round 121) -- same "live, continuously
	// refreshed" pattern as ym1_ch0_state_live_reg above, just capturing
	// the raw ym1_dbg_eg_V number instead of a thresholded/derived value.
	reg [9:0] ym1_ch7_eg_v_live_reg;
	reg [9:0] ym1_ch8_eg_v_live_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch7_eg_v_live_reg <= 10'h3FF;
			ym1_ch8_eg_v_live_reg <= 10'h3FF;
		end else begin
			if (ym1_dbg_car_ch_valid && (ym1_dbg_car_ch_num == 4'd7))
				ym1_ch7_eg_v_live_reg <= ym1_dbg_eg_V;
			if (ym1_dbg_car_ch_valid && (ym1_dbg_car_ch_num == 4'd8))
				ym1_ch8_eg_v_live_reg <= ym1_dbg_eg_V;
		end
	end
	assign ch7_eg_v_live = ym1_ch7_eg_v_live_reg;
	assign ch8_eg_v_live = ym1_ch8_eg_v_live_reg;

	// 2026-08-24, task #8 round 144: see ch7_state_live's port comment --
	// exact mirror of ym1_ch4_state_live_reg's block above, just using
	// jtopl.v's new dbg_ch7car_valid_I/dbg_ch8car_valid_I gates.
	reg ym1_dbg_ch7car_valid_I_d1;
	reg ym1_dbg_ch8car_valid_I_d1;
	always @(posedge clk) if (ym1_dbg_cenop) begin
		ym1_dbg_ch7car_valid_I_d1 <= ym1_dbg_ch7car_valid_I;
		ym1_dbg_ch8car_valid_I_d1 <= ym1_dbg_ch8car_valid_I;
	end

	reg [2:0] ym1_ch7_state_live_reg;
	reg [5:0] ym1_ch7_rate_live_reg;
	reg [3:0] ym1_ch7_keycode_live_reg;
	reg       ym1_ch7_ksr_live_reg;
	reg [2:0] ym1_ch8_state_live_reg;
	reg [5:0] ym1_ch8_rate_live_reg;
	reg [3:0] ym1_ch8_keycode_live_reg;
	reg       ym1_ch8_ksr_live_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch7_state_live_reg <= 3'b000;
			ym1_ch7_rate_live_reg <= 6'd0;
			ym1_ch7_keycode_live_reg <= 4'd0;
			ym1_ch7_ksr_live_reg <= 1'b0;
			ym1_ch8_state_live_reg <= 3'b000;
			ym1_ch8_rate_live_reg <= 6'd0;
			ym1_ch8_keycode_live_reg <= 4'd0;
			ym1_ch8_ksr_live_reg <= 1'b0;
		end else begin
			if (ym1_dbg_ch7car_valid_I)
				ym1_ch7_state_live_reg <= ym1_dbg_state_in_I;
			if (ym1_dbg_ch7car_valid_I_d1) begin
				ym1_ch7_rate_live_reg <= ym1_dbg_rate_II;
				ym1_ch7_keycode_live_reg <= ym1_dbg_keycode_II;
				ym1_ch7_ksr_live_reg <= ym1_dbg_ksr_II;
			end
			if (ym1_dbg_ch8car_valid_I)
				ym1_ch8_state_live_reg <= ym1_dbg_state_in_I;
			if (ym1_dbg_ch8car_valid_I_d1) begin
				ym1_ch8_rate_live_reg <= ym1_dbg_rate_II;
				ym1_ch8_keycode_live_reg <= ym1_dbg_keycode_II;
				ym1_ch8_ksr_live_reg <= ym1_dbg_ksr_II;
			end
		end
	end
	assign ch7_state_live = ym1_ch7_state_live_reg;
	assign ch7_rate_live = ym1_ch7_rate_live_reg;
	assign ch7_keycode_live = ym1_ch7_keycode_live_reg;
	assign ch7_ksr_live = ym1_ch7_ksr_live_reg;
	assign ch8_state_live = ym1_ch8_state_live_reg;
	assign ch8_rate_live = ym1_ch8_rate_live_reg;
	assign ch8_keycode_live = ym1_ch8_keycode_live_reg;
	assign ch8_ksr_live = ym1_ch8_ksr_live_reg;

	// 2026-08-18, task #8 round 18: channel-0-specific Key-On (register
	// 0xB0 only, not the whole 0xB0-0xB8 range key_on_triggered watches)
	// -- see the port declaration comment above for ch0_tl_loud_at_keyon.
	wire ym1_ch0_key_on = ym1_cs && !n_wr && z80_addr[0] &&
	                      (last_ym1_addr == 8'hB0) && z80_dout[5];

	// 2026-08-18, task #8 round 13: key_on_triggered and the (now-reverted)
	// wait-state fix and (still-insufficient) NMI wiring are all confirmed
	// individually correct, yet sound is still silent. Next question: is
	// the note that triggers actually set up with sane parameter data, or
	// is Key-On the only write that "sticks" while frequency/volume data
	// upstream is zero/garbage? Register 0xA0 (YM1 channel 0's F-Number
	// low byte) is the cheapest single register to latch and check.
	reg [7:0] ym1_ch0_fnum_latch;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_fnum_latch <= 8'h00;
		end else begin
			if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'hA0)
				ym1_ch0_fnum_latch <= z80_dout;
		end
	end
	assign ch0_fnum_nonzero = (ym1_ch0_fnum_latch != 8'h00);

	// 2026-08-19, task #8 round 37: real frequency check -- see the port
	// declaration comment above. z80_dout is used directly (not a
	// separately-latched register) because register 0xB0 is the SAME
	// register this exact write event is targeting -- at the cycle
	// ym1_ch0_key_on fires, z80_dout genuinely IS the real, current
	// Block/FreqHi byte, not a stale prior value. ym1_ch0_fnum_latch is
	// safe to read here because standard note-on sequencing (confirmed
	// throughout this investigation) always writes F-Number low (0xA0)
	// before Key-On (0xB0).
	wire [9:0]  ym1_ch0_freq_word    = {z80_dout[1:0], ym1_ch0_fnum_latch};
	wire [2:0]  ym1_ch0_block        = z80_dout[4:2];
	wire [16:0] ym1_ch0_freq_shifted = ym1_ch0_freq_word << ym1_ch0_block;
	reg ch0_freq_infrasonic_at_keyon_reg;
	always @(posedge clk or posedge rst) begin
		if (rst)
			ch0_freq_infrasonic_at_keyon_reg <= 1'b0;
		else if (ym1_ch0_key_on)
			ch0_freq_infrasonic_at_keyon_reg <= (ym1_ch0_freq_shifted < 17'd256);
	end
	assign ch0_freq_infrasonic_at_keyon = ch0_freq_infrasonic_at_keyon_reg;

	// 2026-08-18, task #8 round 14: ch0_fnum_nonzero=GREEN -- the note has
	// real frequency data too. Still no audible output. Next candidate:
	// Total Level (volume/attenuation). Confirmed directly in
	// rtl/jtopl/hdl/jtopl_mmr.v's register decode (~lines 190-226, the
	// selreg[4:3]/[2:0] -> sel_group/sel_sub mapping for the 0x20-0x95
	// operator-register ranges) that channel 0's two operators sit at
	// register offsets 0x00 and 0x03 within each parameter block -- so
	// the KSL/Total-Level register (base 0x40) for channel 0's operator 2
	// (the carrier in the simplest FM connection/algorithm, the one whose
	// output actually reaches the mixer when the channel isn't in
	// additive mode) is 0x43. TL occupies the low 6 bits (0=loudest,
	// 0x3F=maximum attenuation/silent); bits 7:6 are KSL, irrelevant to
	// muting. Checks whether register 0x43 was ever written with TL less
	// than fully attenuated.
	reg [7:0] ym1_ch0_op2_tl_latch;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_op2_tl_latch <= 8'hFF;
		end else begin
			if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'h43)
				ym1_ch0_op2_tl_latch <= z80_dout;
		end
	end
	assign ch0_op2_tl_not_max = (ym1_ch0_op2_tl_latch[5:0] != 6'h3F);

	// 2026-08-18, task #8 round 17: sharper companion to ch0_op2_tl_not_max
	// -- was this same register ever written with a genuinely LOW
	// attenuation value (close to full volume), not just "not the single
	// maximum value". See the port declaration comment above.
	assign ch0_op2_tl_ever_loud = (ym1_ch0_op2_tl_latch[5:0] <= 6'd8);

	// 2026-08-18, task #8 round 18: the real correlated test -- snapshot
	// channel 0's carrier TL specifically at the instant channel 0's own
	// Key-On fires, not tracked as two independent stickies. See the
	// port declaration comment above.
	reg [5:0] ym1_ch0_tl_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_tl_at_keyon <= 6'h3F;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_tl_at_keyon <= ym1_ch0_op2_tl_latch[5:0];
		end
	end
	assign ch0_tl_loud_at_keyon = (ym1_ch0_tl_at_keyon <= 6'd8);

	// 2026-08-18, task #8 round 19: channel 0's Feedback/Connection
	// register (0xC0), same latch-then-snapshot-at-keyon pattern as TL.
	// See the port declaration comment above.
	reg [7:0] ym1_ch0_fbcon_latch;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_fbcon_latch <= 8'h00;
		end else begin
			if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'hC0)
				ym1_ch0_fbcon_latch <= z80_dout;
		end
	end
	reg ym1_ch0_con_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_con_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_con_at_keyon <= ym1_ch0_fbcon_latch[0];
		end
	end
	assign ch0_con_additive_at_keyon = ym1_ch0_con_at_keyon;

	// 2026-08-19, task #8 round 39: Feedback (FB) nibble check -- see the
	// port declaration comment above. Reuses ym1_ch0_fbcon_latch (round
	// 19), same snapshot-at-keyon pattern as ch0_con_additive_at_keyon.
	reg ym1_ch0_fb_nonzero_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_fb_nonzero_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_fb_nonzero_at_keyon <= (ym1_ch0_fbcon_latch[3:1] != 3'h0);
		end
	end
	assign ch0_fb_nonzero_at_keyon = ym1_ch0_fb_nonzero_at_keyon;

	// 2026-08-19, task #8 round 40: sticky "ever" latches on the internal
	// envelope generator's own attenuation value, gated on
	// ym1_dbg_ch0car_valid (the one cycle in the 18-cycle round-robin
	// where ym1_dbg_eg_V genuinely belongs to channel 0's carrier). See
	// the port declaration comment above for the full reasoning.
	reg ch0_car_eg_lt256_ever_reg, ch0_car_eg_lt64_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0_car_eg_lt256_ever_reg <= 1'b0;
			ch0_car_eg_lt64_ever_reg  <= 1'b0;
		end else if (ym1_dbg_ch0car_valid) begin
			if (ym1_dbg_eg_V < 10'd256) ch0_car_eg_lt256_ever_reg <= 1'b1;
			if (ym1_dbg_eg_V < 10'd64)  ch0_car_eg_lt64_ever_reg  <= 1'b1;
		end
	end
	assign ch0_car_eg_lt256_ever = ch0_car_eg_lt256_ever_reg;
	assign ch0_car_eg_lt64_ever  = ch0_car_eg_lt64_ever_reg;

	// 2026-08-19, task #8 round 41: does the internal envelope for
	// channel 0's carrier ever change value at all, sampled every time
	// ym1_dbg_ch0car_valid fires. See the port declaration comment above.
	reg [9:0] ch0_car_eg_prev;
	reg       ch0_car_eg_prev_valid;
	reg       ch0_car_eg_ever_changed_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0_car_eg_prev             <= 10'd0;
			ch0_car_eg_prev_valid       <= 1'b0;
			ch0_car_eg_ever_changed_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid) begin
			if (ch0_car_eg_prev_valid && (ym1_dbg_eg_V != ch0_car_eg_prev))
				ch0_car_eg_ever_changed_reg <= 1'b1;
			ch0_car_eg_prev       <= ym1_dbg_eg_V;
			ch0_car_eg_prev_valid <= 1'b1;
		end
	end
	assign ch0_car_eg_ever_changed = ch0_car_eg_ever_changed_reg;

	// 2026-08-19, task #8 round 43: does the shared global envelope
	// timebase (eg_cnt) ever change value at all. Unlike the per-slot
	// eg_V check, this is not gated on any particular slot being active
	// -- eg_cnt is a single counter, valid every cycle, so a plain
	// every-clk_sys-cycle comparison against its own previous value is
	// sufficient (it only changes synchronously on real transitions).
	reg [14:0] eg_cnt_prev;
	reg        eg_cnt_ever_changed_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			eg_cnt_prev             <= 15'd0;
			eg_cnt_ever_changed_reg <= 1'b0;
		end else begin
			if (ym1_dbg_eg_cnt != eg_cnt_prev) eg_cnt_ever_changed_reg <= 1'b1;
			eg_cnt_prev <= ym1_dbg_eg_cnt;
		end
	end
	assign eg_cnt_ever_changed = eg_cnt_ever_changed_reg;

	// 2026-08-19, task #8 round 44: does the internal Key-On edge-detect
	// pulse ever fire for channel 0's carrier specifically. Both signals
	// are "stage I" (undelayed), so a plain AND-then-latch is sufficient
	// -- no delay-matching needed, same as round 43's eg_cnt check.
	reg ch0car_keyon_now_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_keyon_now_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I && ym1_dbg_keyon_now_I) begin
			ch0car_keyon_now_ever_reg <= 1'b1;
		end
	end
	assign ch0car_keyon_now_ever = ch0car_keyon_now_ever_reg;

	// 2026-08-19, task #8 round 48: does sum_up_II ever fire for channel
	// 0's carrier. The 1-cycle delay this needs (sum_up_II is a "stage
	// II" signal, one cenop cycle after the raw group/subslot) is built
	// here using the newly-exposed ym1_dbg_cenop, instead of as a new
	// register inside jtopl.v (rounds 45/46's approach, which caused a
	// real hardware regression twice).
	reg ym1_dbg_ch0car_valid_I_d1;
	always @(posedge clk) if (ym1_dbg_cenop) ym1_dbg_ch0car_valid_I_d1 <= ym1_dbg_ch0car_valid_I;

	reg ch0car_sum_up_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_sum_up_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I_d1 && ym1_dbg_sum_up_II) begin
			ch0car_sum_up_ever_reg <= 1'b1;
		end
	end
	assign ch0car_sum_up_ever = ch0car_sum_up_ever_reg;

	// 2026-08-19, task #8 round 49: does eg_in_I (the raw persistent
	// value) ever change for channel 0's carrier. eg_in_I is a "stage I"
	// signal (same timing as keyon_I), so the already-existing undelayed
	// ym1_dbg_ch0car_valid_I is reused directly -- no new delay needed.
	reg [9:0] ch0car_eg_in_I_prev;
	reg       ch0car_eg_in_I_prev_valid;
	reg       ch0car_eg_in_I_ever_changed_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_eg_in_I_prev             <= 10'd0;
			ch0car_eg_in_I_prev_valid       <= 1'b0;
			ch0car_eg_in_I_ever_changed_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I) begin
			if (ch0car_eg_in_I_prev_valid && (ym1_dbg_eg_in_I != ch0car_eg_in_I_prev))
				ch0car_eg_in_I_ever_changed_reg <= 1'b1;
			ch0car_eg_in_I_prev       <= ym1_dbg_eg_in_I;
			ch0car_eg_in_I_prev_valid <= 1'b1;
		end
	end
	assign ch0car_eg_in_I_ever_changed = ch0car_eg_in_I_ever_changed_reg;

	// 2026-08-20, task #8 round 71: see ch0car_arate_was_15_ever/
	// ch0car_rate_was_63_ever port comments above for the full reasoning.
	reg ch0car_arate_was_15_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_arate_was_15_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I && (ym1_dbg_arate_I == 4'd15)) begin
			ch0car_arate_was_15_ever_reg <= 1'b1;
		end
	end
	assign ch0car_arate_was_15_ever = ch0car_arate_was_15_ever_reg;

	// 2026-08-20, task #8 round 73: broadened from an exact rate==63 match
	// to rate[5:2]==4'hf (rate 60-63 inclusive) -- that's jtopl_eg_step.v's
	// actual mux_sel-overflow trigger condition, not just the saturated
	// max value. Round 72's readback narrowed the real AR to nonzero,
	// >=8 (not 15) -- a rate in [60,63] is still reachable from a lower AR
	// (e.g. 14) combined with a high enough keycode/KSR contribution, so
	// the exact-63 check could have missed the real note even if it hits
	// the identical structural bug. Port name kept as _63 for minimal
	// diff; it now really means "rate ever fell in the mux_sel-overflow
	// zone".
	reg ch0car_rate_was_63_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_rate_was_63_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I_d1 && (ym1_dbg_rate_II[5:2] == 4'hf)) begin
			ch0car_rate_was_63_ever_reg <= 1'b1;
		end
	end
	assign ch0car_rate_was_63_ever = ch0car_rate_was_63_ever_reg;

	// 2026-08-19, task #8 round 51: does step_II ever fire for channel
	// 0's carrier, gated on the already-existing round-48 delayed valid
	// signal (step_II is the same "stage II" timing as sum_up_II, no new
	// delay logic needed).
	reg ch0car_step_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_step_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I_d1 && ym1_dbg_step_II) begin
			ch0car_step_ever_reg <= 1'b1;
		end
	end
	assign ch0car_step_ever = ch0car_step_ever_reg;

	// 2026-08-19, task #8 round 52: was state_in_I ever == ATTACK
	// (3'b001) for channel 0's carrier. state_in_I is a "stage I" signal
	// (same timing as keyon_I), reuses the existing undelayed
	// ym1_dbg_ch0car_valid_I directly -- no new delay logic needed.
	reg ch0car_state_attack_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_state_attack_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I && (ym1_dbg_state_in_I == 3'b001)) begin
			ch0car_state_attack_ever_reg <= 1'b1;
		end
	end
	assign ch0car_state_attack_ever = ch0car_state_attack_ever_reg;

	// 2026-08-19, task #8 round 53: the joint condition. attack_II shares
	// the same "stage II" timing as sum_up_II/step_II, so the existing
	// round-48 delayed valid signal is reused directly -- no new delay.
	reg ch0car_attack_step_sumup_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_attack_step_sumup_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I_d1 && ym1_dbg_attack_II && ym1_dbg_step_II && ym1_dbg_sum_up_II) begin
			ch0car_attack_step_sumup_ever_reg <= 1'b1;
		end
	end
	assign ch0car_attack_step_sumup_ever = ch0car_attack_step_sumup_ever_reg;

	// 2026-08-19, task #8 round 55: round 54 confirmed (ModelSim, 64 real
	// hits) that round 53's joint condition is genuinely achievable with
	// the identical source -- ruling out "diagnostic-wiring artifact" as
	// the explanation for round 53's real-hardware RED. User explicitly
	// authorized registering the joint-AND inside jtopl_eg.v itself
	// (dbg_joint_hit_II), at the exact same pipeline point attack_II/
	// step_II/sum_up_II are already used at, removing the 3-wire/
	// 4-module-boundary routing that round 53's version needed. That
	// register is written using attack_II/step_II/sum_out_II's CURRENT
	// values in the SAME always block that also sets attack_III/step_III/
	// sum_in_III from the SAME source values -- meaning dbg_joint_hit_II
	// becomes valid at "stage III" timing (one cenop cycle later than
	// attack_II/step_II/sum_up_II's own "stage II" timing), not "stage
	// II" despite the signal's own name. Needs a 2-cycle-delayed valid
	// gate, not the existing round-48 1-cycle one.
	reg ym1_dbg_ch0car_valid_I_d2;
	always @(posedge clk) if (ym1_dbg_cenop) ym1_dbg_ch0car_valid_I_d2 <= ym1_dbg_ch0car_valid_I_d1;

	reg ch0car_joint_hit_reg_ever;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_joint_hit_reg_ever <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I_d2 && ym1_dbg_joint_hit_II) begin
			ch0car_joint_hit_reg_ever <= 1'b1;
		end
	end
	assign ch0car_joint_hit_reg_ever_out = ch0car_joint_hit_reg_ever;

	// 2026-08-20, task #8 round 63: joint_hit_III is a plain wire (attack_III
	// && step_III && sum_in_III), valid at the same "stage III" timing as
	// dbg_joint_hit_II (both are simple functions of stage-III registers),
	// so the existing ym1_dbg_ch0car_valid_I_d2 delayed valid gate is reused
	// directly -- no new delay logic needed.
	reg ch0car_joint_hit_III_ever_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ch0car_joint_hit_III_ever_reg <= 1'b0;
		end else if (ym1_dbg_ch0car_valid_I_d2 && ym1_dbg_joint_hit_III) begin
			ch0car_joint_hit_III_ever_reg <= 1'b1;
		end
	end
	assign ch0car_joint_hit_III_ever_out = ch0car_joint_hit_III_ever_reg;

	// 2026-08-18, task #8 round 20: channel 0's carrier Attack/Decay Rate
	// register (0x63), same latch-then-snapshot-at-keyon pattern as TL
	// and FBCON. See the port declaration comment above.
	reg [7:0] ym1_ch0_ar_dr_latch;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_ar_dr_latch <= 8'hFF;
		end else begin
			if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'h63)
				ym1_ch0_ar_dr_latch <= z80_dout;
		end
	end
	reg ym1_ch0_ar_zero_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_ar_zero_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_ar_zero_at_keyon <= (ym1_ch0_ar_dr_latch[7:4] == 4'h0);
		end
	end
	assign ch0_ar_zero_at_keyon = ym1_ch0_ar_zero_at_keyon;

	// 2026-08-19, task #8 round 31: companion check to round 20 -- was
	// AR in the fast half (>=8) of its 0-15 range at the same keyon
	// instant, reusing the same ym1_ch0_ar_dr_latch. See the port
	// declaration comment above.
	reg ym1_ch0_ar_fast_at_keyon_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_ar_fast_at_keyon_reg <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_ar_fast_at_keyon_reg <= (ym1_ch0_ar_dr_latch[7:4] >= 4'h8);
		end
	end
	assign ym1_ch0_ar_fast_at_keyon = ym1_ch0_ar_fast_at_keyon_reg;

	// 2026-08-18, task #8 round 22: channel 0's carrier MULT/KSR/EG-TYP/
	// VIB/AM register (0x23), same latch-then-snapshot-at-keyon pattern.
	// EG-TYP is bit5. See the port declaration comment above.
	reg [7:0] ym1_ch0_egtyp_latch;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_egtyp_latch <= 8'h00;
		end else begin
			if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'h23)
				ym1_ch0_egtyp_latch <= z80_dout;
		end
	end
	reg ym1_ch0_eg_type_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_eg_type_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_eg_type_at_keyon <= ym1_ch0_egtyp_latch[5];
		end
	end
	assign ch0_eg_type_at_keyon = ym1_ch0_eg_type_at_keyon;

	// 2026-08-18, task #8 round 23: KSL (register 0x43 bits 7:6), same
	// snapshot-at-keyon instant, reusing the already-populated
	// ym1_ch0_op2_tl_latch (full byte) from rounds 14/17/18. See the
	// port declaration comment above.
	reg [1:0] ym1_ch0_ksl_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_ksl_at_keyon <= 2'b00;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_ksl_at_keyon <= ym1_ch0_op2_tl_latch[7:6];
		end
	end
	assign ch0_ksl_nonzero_at_keyon = (ym1_ch0_ksl_at_keyon != 2'b00);

	// 2026-08-18, task #8 round 24: KSR (register 0x23 bit4), reusing
	// the already-populated ym1_ch0_egtyp_latch (full byte from round
	// 22) -- same snapshot-at-keyon instant. See the port declaration
	// comment above.
	reg ym1_ch0_ksr_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_ksr_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_ksr_at_keyon <= ym1_ch0_egtyp_latch[4];
		end
	end
	assign ch0_ksr_at_keyon = ym1_ch0_ksr_at_keyon;

	// 2026-08-18, task #8 round 26: Decay Rate (register 0x63 lower
	// nibble), reusing the already-populated ym1_ch0_ar_dr_latch from
	// round 20 -- same snapshot-at-keyon instant. See the port
	// declaration comment above.
	reg ym1_ch0_dr_zero_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_dr_zero_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_dr_zero_at_keyon <= (ym1_ch0_ar_dr_latch[3:0] == 4'h0);
		end
	end
	assign ch0_dr_zero_at_keyon = ym1_ch0_dr_zero_at_keyon;

	// 2026-08-18, task #8 round 27: Sustain Level / Release Rate
	// (register 0x83), new latch. See the port declaration comment
	// above.
	reg [7:0] ym1_ch0_sl_rr_latch;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_sl_rr_latch <= 8'h00;
		end else begin
			if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'h83)
				ym1_ch0_sl_rr_latch <= z80_dout;
		end
	end
	reg ym1_ch0_sl_rr_zero_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_sl_rr_zero_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_sl_rr_zero_at_keyon <= (ym1_ch0_sl_rr_latch == 8'h00);
		end
	end
	assign ch0_sl_rr_zero_at_keyon = ym1_ch0_sl_rr_zero_at_keyon;

	// 2026-08-18, task #8 round 25: Test Register (register 0x01) check.
	// We monitor writes to register 0x01 on YM1. If this register is
	// written with a nonzero value, it could enable global test/mute modes.
	reg [7:0] ym1_test_reg_latch;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_test_reg_latch <= 8'h00;
		end else begin
			if (ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'h01)
				ym1_test_reg_latch <= z80_dout;
		end
	end

	reg ym1_ch0_test_reg_nonzero_at_keyon;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_test_reg_nonzero_at_keyon <= 1'b0;
		end else begin
			if (ym1_ch0_key_on) ym1_ch0_test_reg_nonzero_at_keyon <= (ym1_test_reg_latch != 8'h00);
		end
	end
	assign ch0_test_reg_nonzero_at_keyon = ym1_ch0_test_reg_nonzero_at_keyon;

	//------------------------------------------------------------------------
	// 32KB Sound ROM (Dual-Port BRAM: Port A = IOCTL Write, Port B = Z80 Read)
	//------------------------------------------------------------------------
	wire [7:0] rom_dout;
	
	altsyncram #(
		.operation_mode("DUAL_PORT"),
		.width_a(8),
		.widthad_a(15),
		.width_b(8),
		.widthad_b(15)
	) sound_rom (
		.clock0(clk),
		.address_a(ioctl_sound_addr),
		.data_a(ioctl_sound_data),
		.wren_a(ioctl_sound_we),
		.clock1(clk),
		.address_b(z80_addr[14:0]),
		.q_b(rom_dout)
	);

	//------------------------------------------------------------------------
	// 2KB Sound Work RAM (Single-Port BRAM)
	//------------------------------------------------------------------------
	wire [7:0] ram_dout;
	wire ram_we = mem_acc && !n_wr && ram_cs;

	// 2026-08-21, task #8 round 109: see ram_8115_fade_level_live/
	// ram_8116_fade_active_live port comments above. Plain live snoops
	// (not sticky) of the Z80 driver's own fade-level and fade-active RAM
	// bytes, so a screenshot shows the exact instantaneous state.
	reg [7:0] ram_8115_fade_level_live_reg;
	reg       ram_8116_fade_active_live_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ram_8115_fade_level_live_reg <= 8'h00;
			ram_8116_fade_active_live_reg <= 1'b0;
		end else begin
			if (ram_we && z80_addr == 16'h8115) ram_8115_fade_level_live_reg <= z80_dout;
			if (ram_we && z80_addr == 16'h8116) ram_8116_fade_active_live_reg <= z80_dout[0];
		end
	end
	assign ram_8115_fade_level_live = ram_8115_fade_level_live_reg;
	assign ram_8116_fade_active_live = ram_8116_fade_active_live_reg;

	altsyncram #(
		.operation_mode("SINGLE_PORT"),
		.width_a(8),
		.widthad_a(11)
	) sound_ram (
		.clock0(clk),
		.address_a(z80_addr[10:0]),
		.data_a(z80_dout),
		.wren_a(ram_we),
		.q_a(ram_dout)
	);

	//------------------------------------------------------------------------
	// YM3812 #1 & #2 Registers & Data Mux
	//------------------------------------------------------------------------
	//------------------------------------------------------------------------
	// YM3812 #1 & #2 OPL2 Instances
	//------------------------------------------------------------------------
	wire [7:0] ym1_dout, ym2_dout;
	wire ym1_irq_n, ym2_irq_n;
	wire signed [15:0] ym1_snd, ym2_snd;

	wire ym1_cs_n = !ym1_cs;
	wire ym2_cs_n = !ym2_cs;
	wire wr_n = n_wr;

	// 2026-08-23, task #8 round 132: tried (and reverted) an experimental
	// waveform-select-enable (WSE, OPL2 register 0x01 bit 5) injector
	// here -- the real ROM never writes this register anywhere (verified
	// exhaustively), so WSE stays at the real YM3812's documented reset
	// default of 0, forcing sine-only waveform output. The experiment
	// forced WSE=1 via a synthetic post-reset register write to both
	// chips, purely to A/B test whether that was an authoring gap. User's
	// listening test: "nothing really changed, hard to say if it's better
	// or worse." Checked why: across all 51 known instrument tables (102
	// waveform slots total), 100 already use WS=0 (sine) regardless of
	// WSE -- only ONE instrument (ROM 0x69e7) uses a non-sine waveform at
	// all, for both its modulator and carrier. With such a narrow
	// footprint, no audible difference was ever likely. Reverted rather
	// than keep an unconfirmed deviation from real chip reset behavior
	// with no demonstrated benefit -- see round 132's write-up in
	// project_history/TASKS.md for the full reasoning and search methodology,
	// preserved there in case a reference recording ever turns up to
	// settle whether this is a genuine 1987 authoring gap.

	// 2026-08-17, task #8: previously ym1_irq_n/ym2_irq_n were declared but
	// left completely unconnected, and the Z80's NMI was permanently
	// hardwired inactive (1'b1). extra/jtcores_ref/cores/castle/hdl/
	// jtcastle_sound.v (Haunted Castle, a real shipped Konami core using
	// the same jtopl2 core) wires jtopl2's irq_n straight to the Z80's
	// nmi_n -- the OPL2's internal timers drive a real hardware interrupt
	// there. Both irq_n outputs are active-low, so wired-AND (both must be
	// high/inactive for NMI to stay inactive) correctly ORs the two
	// chips' interrupt conditions onto the single NMI line.
	wire z80_n_nmi = ym1_irq_n & ym2_irq_n;

	// 2026-08-19, task #8 round 40: internal envelope-generator taps, only
	// from ym1 (chip 1) since that's the chip this whole investigation has
	// focused on. See jtopl.v's port declaration comment for the full
	// reasoning.
	wire [9:0]  ym1_dbg_eg_V;
	wire        ym1_dbg_ch0car_valid;
	wire [14:0] ym1_dbg_eg_cnt;
	wire        ym1_dbg_keyon_now_I;
	wire        ym1_dbg_ch0car_valid_I;
	wire        ym1_dbg_sum_up_II;
	wire        ym1_dbg_cenop;
	wire [9:0]  ym1_dbg_eg_in_I;
	wire        ym1_dbg_step_II;
	wire [2:0]  ym1_dbg_state_in_I;
	wire        ym1_dbg_attack_II;
	wire        ym1_dbg_joint_hit_II;
	wire        ym1_dbg_joint_hit_III;
	wire [3:0]  ym1_dbg_arate_I;
	wire [5:0]  ym1_dbg_rate_II;
	wire        ym1_dbg_ch4car_valid_I;
	wire [3:0]  ym1_dbg_keycode_II;
	wire        ym1_dbg_ksr_II;

	// 2026-08-22, task #8 round 121: see the generate block below (and
	// jtopl.v's dbg_car_ch_valid/dbg_car_ch_num port comment) for the full
	// reasoning -- generalizes ym1_dbg_ch0car_valid/ym1_dbg_ch4car_valid_I
	// to all 9 real channels at once.
	wire        ym1_dbg_car_ch_valid;
	wire [3:0]  ym1_dbg_car_ch_num;

	// 2026-08-24, task #8 round 144: see jtopl.v's dbg_ch7car_valid_I/
	// dbg_ch8car_valid_I port comment.
	wire        ym1_dbg_ch7car_valid_I;
	wire        ym1_dbg_ch8car_valid_I;

	jtopl2 u_ym3812_1 (
		.rst    ( rst           ),
		.clk    ( clk           ),
		.cen    ( ce_ym3812     ),
		.din    ( z80_dout      ),
		.addr   ( z80_addr[0]   ),
		.cs_n   ( ym1_cs_n      ),
		.wr_n   ( wr_n          ),
		.dout   ( ym1_dout      ),
		.irq_n  ( ym1_irq_n     ),
		.snd    ( ym1_snd       ),
		.sample (               ),
		.dbg_eg_V         ( ym1_dbg_eg_V         ),
		.dbg_ch0car_valid ( ym1_dbg_ch0car_valid ),
		.dbg_eg_cnt       ( ym1_dbg_eg_cnt       ),
		.dbg_keyon_now_I    ( ym1_dbg_keyon_now_I    ),
		.dbg_ch0car_valid_I ( ym1_dbg_ch0car_valid_I ),
		.dbg_sum_up_II ( ym1_dbg_sum_up_II ),
		.dbg_cenop     ( ym1_dbg_cenop     ),
		.dbg_eg_in_I   ( ym1_dbg_eg_in_I   ),
		.dbg_step_II   ( ym1_dbg_step_II   ),
		.dbg_state_in_I( ym1_dbg_state_in_I),
		.dbg_attack_II ( ym1_dbg_attack_II ),
		.dbg_joint_hit_II ( ym1_dbg_joint_hit_II ),
		.dbg_joint_hit_III ( ym1_dbg_joint_hit_III ),
		.dbg_arate_I ( ym1_dbg_arate_I ),
		.dbg_rate_II ( ym1_dbg_rate_II ),
		.dbg_ch4car_valid_I ( ym1_dbg_ch4car_valid_I ),
		.dbg_keycode_II ( ym1_dbg_keycode_II ),
		.dbg_ksr_II ( ym1_dbg_ksr_II ),
		.dbg_car_ch_valid ( ym1_dbg_car_ch_valid ),
		.dbg_car_ch_num   ( ym1_dbg_car_ch_num   ),
		.dbg_ch7car_valid_I ( ym1_dbg_ch7car_valid_I ),
		.dbg_ch8car_valid_I ( ym1_dbg_ch8car_valid_I )
	);

	// 2026-08-23, task #8 round 129: round 112 mirrored the Key-On/stuck-
	// duration checks to ym2, but assumed ym1==ym2 behavior since both
	// chips receive the SAME real register writes (round 118's ROM
	// disassembly confirmed the driver deliberately writes both chips
	// identically) -- this assumption was never actually verified with
	// round 121's finer-grained per-channel envelope tap, which ym2 never
	// had wired at all. After three separate wide sweeps found no
	// sustained audible-while-Key-Off channel anywhere on ym1, checking
	// the one genuinely untested gap rather than a new speculative theory.
	wire [9:0] ym2_dbg_eg_V;
	wire       ym2_dbg_car_ch_valid;
	wire [3:0] ym2_dbg_car_ch_num;
	jtopl2 u_ym3812_2 (
		.rst    ( rst           ),
		.clk    ( clk           ),
		.cen    ( ce_ym3812     ),
		.din    ( z80_dout      ),
		.addr   ( z80_addr[0]   ),
		.cs_n   ( ym2_cs_n      ),
		.wr_n   ( wr_n          ),
		.dout   ( ym2_dout      ),
		.irq_n  ( ym2_irq_n     ),
		.snd    ( ym2_snd       ),
		.sample (               ),
		.dbg_ch0car_valid (                      ),
		.dbg_eg_cnt       (                      ),
		.dbg_keyon_now_I    (                    ),
		.dbg_ch0car_valid_I (                    ),
		.dbg_sum_up_II ( ),
		.dbg_cenop     ( ),
		.dbg_eg_in_I   ( ),
		.dbg_step_II   ( ),
		.dbg_state_in_I( ),
		.dbg_attack_II ( ),
		.dbg_joint_hit_II ( ),
		.dbg_joint_hit_III ( ),
		.dbg_arate_I ( ),
		.dbg_rate_II ( ),
		.dbg_ch4car_valid_I ( ),
		.dbg_keycode_II ( ),
		.dbg_ksr_II ( ),
		.dbg_car_ch_valid ( ym2_dbg_car_ch_valid ),
		.dbg_car_ch_num   ( ym2_dbg_car_ch_num   ),
		.dbg_eg_V         ( ym2_dbg_eg_V         ),
		.dbg_ch7car_valid_I ( ),
		.dbg_ch8car_valid_I ( )
	);

	genvar gb;
	generate
		for (gb = 0; gb < 9; gb = gb + 1) begin : ch_audible_gen_ym2
			reg audible_live_ym2;
			always @(posedge clk or posedge rst) begin
				if (rst) begin
					audible_live_ym2 <= 1'b0;
				end else if (ym2_dbg_car_ch_valid && (ym2_dbg_car_ch_num == gb[3:0])) begin
					audible_live_ym2 <= (ym2_dbg_eg_V < 10'd700); // round 135: widened, see ym1's identical comment above
				end
			end
			assign ym2_ch_audible_live[gb] = audible_live_ym2;

			// 2026-08-23, task #8 round 139: see ym2_ch_stuck_confirmed's
			// port comment -- exact mirror of ym1's ch_audible_gen block's
			// duration/confirm logic (round 121), just keyed on ym2's own
			// per-channel Key-On state instead.
			reg [22:0] ch_stuck_tick_cnt_ym2;
			reg [7:0]  ch_stuck_dur_100ms_ym2;
			reg        ch_stuck_confirmed_ever_ym2;
			wire ch_keyoff_ym2 = !ym2_ch_key_on_state_reg[gb];
			always @(posedge clk or posedge rst) begin
				if (rst) begin
					ch_stuck_tick_cnt_ym2 <= 23'd0;
					ch_stuck_dur_100ms_ym2 <= 8'd0;
					ch_stuck_confirmed_ever_ym2 <= 1'b0;
				end else if (ch_keyoff_ym2) begin
					if (ch_stuck_tick_cnt_ym2 >= STUCK_AUDIO_TICK_CYCLES - 23'd1) begin
						ch_stuck_tick_cnt_ym2 <= 23'd0;
						if (ch_stuck_dur_100ms_ym2 != 8'hFF)
							ch_stuck_dur_100ms_ym2 <= ch_stuck_dur_100ms_ym2 + 8'd1;
					end else begin
						ch_stuck_tick_cnt_ym2 <= ch_stuck_tick_cnt_ym2 + 23'd1;
					end
					if ((ch_stuck_dur_100ms_ym2 >= STUCK_AUDIO_CONFIRM_TICKS) && audible_live_ym2)
						ch_stuck_confirmed_ever_ym2 <= 1'b1;
				end else begin
					ch_stuck_tick_cnt_ym2 <= 23'd0;
					ch_stuck_dur_100ms_ym2 <= 8'd0;
				end
			end
			assign ym2_ch_stuck_confirmed[gb] = ch_stuck_confirmed_ever_ym2;
		end
	endgenerate

	always @(*) begin
		case (1'b1)
			rom_cs:   z80_din = rom_dout;
			ram_cs:   z80_din = ram_dout;
			ym1_cs:   z80_din = ym1_dout;
			ym2_cs:   z80_din = ym2_dout;
			latch_cs: z80_din = snd_latch;
			default:  z80_din = 8'hFF;
		endcase
	end

	//------------------------------------------------------------------------
	// YM3812 wait-state generator: tried and reverted (2026-08-17, task #8)
	//------------------------------------------------------------------------
	// Two rounds of a jtopl-pipeline-timing wait-state fix (rising-edge,
	// then falling-edge triggered) were implemented, verified against the
	// actual jtopl RTL, deployed, and confirmed engaging correctly on real
	// hardware (key_on_triggered and ym_wait_engaged both GREEN) -- yet
	// neither produced audible sound. Decisive counter-evidence found by
	// comparing against extra/jtcores_ref/cores/castle/hdl/jtcastle_sound.v
	// (Haunted Castle, a real shipped Jotego core for an actual Konami
	// game using the same jtopl2 core): it wires a Z80 straight to jtopl2
	// with NO wait-state logic at all, and Jotego's own framework has no
	// generic mechanism for this (jtframe_z80wait.v only handles ROM/SDRAM
	// access latency). If jtopl genuinely couldn't keep up with realistic
	// Z80 write cadences, a proven, widely-used reference wouldn't need
	// zero special handling for it. Removed as very likely a red herring.

	//------------------------------------------------------------------------
	// Z80 CPU Instance (T80s VHDL Wrapper)
	//------------------------------------------------------------------------
	wire n_halt;
	wire [7:0] z80_a_reg;
	wire z80_f_z_reg;
	cpu_z80 u_z80 (
		.nRESET  ( ~rst     ),
		.clk     ( clk      ),
		.clken   ( ce_z80   ),
		.Z80_DIN ( z80_din  ),
		.Z80_DOUT( z80_dout ),
		.Z80_ADDR( z80_addr ),
		.nIORQ   ( n_iorq   ),
		.nMREQ   ( n_mreq   ),
		.nRFSH   ( n_rfsh   ),
		.nRD     ( n_rd     ),
		.nWR     ( n_wr     ),
		.nINT    ( n_int    ),
		.nNMI    ( z80_n_nmi ),
		.nWAIT   ( 1'b1     ),
		.nHALT   ( n_halt   ),
		.nM1     ( n_m1     ),
		.z80_a   ( z80_a_reg   ),
		.z80_f_z ( z80_f_z_reg )
	);
	assign z80_halted = !n_halt;

	// 2026-08-18, task #8 round 15: every OPL2 register-level parameter
	// checked (key-on, frequency, volume) is confirmed correct -- the Z80
	// sends a fully well-formed note. Checks jtopl2's own raw combined
	// output directly, before this project's mixing step, to isolate
	// "jtopl2 itself isn't synthesizing despite correct register state"
	// from "the bug is in this project's own mixing/output code."
	assign ym1_snd_ever_nonzero = (ym1_snd != 16'sd0);

	// Mix both YM3812 audio outputs
	wire signed [16:0] mixed_audio_raw = $signed(ym1_snd) + $signed(ym2_snd);
	// 2026-08-21, task #8 round 108: the halving here was a plain bit
	// slice (mixed_audio_raw[16:1]), equivalent to a truncating (floor)
	// divide-by-2 -- for FM synthesis output, which spends much of its
	// time at small/decaying amplitudes, always rounding toward negative
	// infinity introduces a real quantization bias that reads as harsh/
	// crunchy rather than clean noise-shaped rounding. Switched to
	// round-half-up (add 1 before the arithmetic shift), a standard,
	// low-risk fix for exactly this class of truncation artifact.
	wire signed [16:0] mixed_audio_rounded = mixed_audio_raw + 17'sd1;
	// 2026-09-02, task #77: explicit [16:1] slice instead of an arithmetic
	// shift assigned into a narrower target -- bit-for-bit identical
	// result (dropping bit 0 and keeping the sign-extended top), but
	// silences Quartus's truncation warning (10230).
	wire signed [15:0] mixed_audio = mixed_audio_rounded[16:1];

	assign audio_l = mixed_audio;
	assign audio_r = mixed_audio;

	// 2026-08-18, task #8 round 16: magnitude check on the final mixed
	// output (post-mixing, exactly what reaches AUDIO_L/AUDIO_R) -- see
	// the port declaration comment above.
	assign audio_mag_gt256_ever  = (mixed_audio > 16'sd256)  || (mixed_audio < -16'sd256);
	assign audio_mag_gt4096_ever = (mixed_audio > 16'sd4096) || (mixed_audio < -16'sd4096);

	// 2026-08-18, task #8 round 28: same magnitude check, but on ym1_snd
	// alone, before mixing with ym2_snd -- see the port declaration
	// comment above.
	assign ym1_snd_mag_gt256_ever = (ym1_snd > 16'sd256) || (ym1_snd < -16'sd256);

	// 2026-08-19, task #8 round 30: measures how long register 0xB0
	// (channel 0's Key-On/block/fnum-high register) goes untouched after
	// a real Key-On write, before the Z80 writes to it again for any
	// reason. Threshold: 100ms at the real 48MHz clk_sys (4,800,000
	// cycles) -- comfortably below the ~150ms the isolated simulation
	// needed to reach a real, audible-range peak (round 29), so GREEN
	// here would still leave real room for the note to have gotten
	// genuinely loud if this were the only factor. See the port
	// declaration comment above.
	localparam [22:0] KEYON_HOLD_THRESHOLD = 23'd4_800_000; // 100ms @ 48MHz
	reg [22:0] ym1_ch0_keyon_hold_cnt;
	reg        ym1_ch0_keyon_active;
	reg        ym1_ch0_keyon_held_100ms_reg;
	wire       ym1_ch0_b0_write = ym1_cs && !n_wr && z80_addr[0] && last_ym1_addr == 8'hB0;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			ym1_ch0_keyon_hold_cnt       <= 23'd0;
			ym1_ch0_keyon_active         <= 1'b0;
			ym1_ch0_keyon_held_100ms_reg <= 1'b0;
		end else begin
			if (ym1_ch0_b0_write) begin
				// A new write to the Key-On register arrived -- if the
				// PRIOR key-on had already been held long enough,
				// latch that before updating to the new state.
				if (ym1_ch0_keyon_active && (ym1_ch0_keyon_hold_cnt >= KEYON_HOLD_THRESHOLD))
					ym1_ch0_keyon_held_100ms_reg <= 1'b1;
				ym1_ch0_keyon_active   <= z80_dout[5];
				ym1_ch0_keyon_hold_cnt <= 23'd0;
			end else if (ym1_ch0_keyon_active) begin
				if (ym1_ch0_keyon_hold_cnt >= KEYON_HOLD_THRESHOLD)
					ym1_ch0_keyon_held_100ms_reg <= 1'b1;
				else
					ym1_ch0_keyon_hold_cnt <= ym1_ch0_keyon_hold_cnt + 1'b1;
			end
		end
	end
	assign ym1_ch0_keyon_held_100ms = ym1_ch0_keyon_held_100ms_reg;

	// Debug observability (irq_ack is already driven by its own assign
	// statement above -- no second driver needed)
	assign z80_fetching = mem_acc && !n_rd;
	assign ym_written = (ym1_cs || ym2_cs) && !n_wr;

	// PC-reached checks -- gated on !n_m1 (a genuine opcode-fetch cycle,
	// now that n_m1 is properly wired) rather than the broader
	// z80_fetching, so these specifically mean "the CPU fetched THIS
	// instruction", not "some memory read happened to touch this address".
	wire z80_opcode_fetch = mem_acc && !n_rd && !n_m1;
	assign pc_hit_ei_364 = z80_opcode_fetch && (z80_addr == 16'h0364);
	assign pc_hit_0038 = z80_opcode_fetch && (z80_addr == 16'h0038);
	assign pc_hit_csumfail_2be = z80_opcode_fetch && (z80_addr == 16'h02BE);
	assign pc_past_delay_loop = z80_opcode_fetch && (z80_addr == 16'h02F9);
	assign pc_past_ramtest_loop = z80_opcode_fetch && (z80_addr == 16'h0311);
	assign pc_past_checksum_loop = z80_opcode_fetch && (z80_addr == 16'h0322);
	assign pc_hit_0000 = z80_opcode_fetch && (z80_addr == 16'h0000);
	assign pc_hit_0000_wrong_data = pc_hit_0000 && (z80_din != 8'hED);
	// z80_fetching (mem_acc && !n_rd, declared above) is used here instead
	// of z80_opcode_fetch since 0x000E is the CP instruction's operand
	// byte, read on a plain memory-read cycle, not an M1 opcode fetch.
	wire pc_hit_000e = z80_fetching && (z80_addr == 16'h000E); // no longer a module output (retired) -- kept internal, still feeds pc_hit_000e_wrong_data below
	assign pc_hit_000e_wrong_data = pc_hit_000e && (z80_din != 8'h88);
	assign hl_reached_8800 = mem_acc && !n_wr && (z80_addr == 16'h8800);
	// 2026-08-18, task #8 round 19: was channel 0's Feedback/Connection
	// register (0xC0, bit0 = CON) ever set to additive mode (CON=1) at
	// the moment of its own Key-On? See the port declaration comment
	// above for ch0_con_additive_at_keyon. FM mode (CON=0) is the
	// standard/default connection where only the carrier's (op2, 0x43)
	// TL matters -- already confirmed loud at keyon. Additive mode
	// (CON=1) would mean operator 1's own TL (0x40, not yet checked)
	// also contributes directly to the output and could independently
	// be muted, which would explain quiet output despite a loud carrier.
	wire at_jr_nz = z80_opcode_fetch && (z80_addr == 16'h000F);
	assign a_hit_88_at_jrnz = at_jr_nz && (z80_a_reg == 8'h88);
	assign z_wrong_when_a_88 = at_jr_nz && (z80_a_reg == 8'h88) && !z80_f_z_reg;
	assign executed_ex_af = z80_opcode_fetch && (z80_din == 8'h08);

	// Edge-detected: z80_opcode_fetch is held combinationally across every
	// `clk` cycle between ce_z80 pulses (many, since ce_z80 divides clk),
	// so counting on the raw level would just count clk cycles, not real
	// distinct fetches. Count rising edges instead.
	reg z80_opcode_fetch_prev;
	always @(posedge clk) z80_opcode_fetch_prev <= z80_opcode_fetch;
	wire z80_opcode_fetch_edge = z80_opcode_fetch && !z80_opcode_fetch_prev;

	reg [3:0] z80_fetch_count;
	reg z80_fetch_count_reached_8_r;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			z80_fetch_count <= 4'd0;
			z80_fetch_count_reached_8_r <= 1'b0;
		end else if (z80_opcode_fetch_edge) begin
			if (z80_fetch_count != 4'd15) z80_fetch_count <= z80_fetch_count + 1'b1;
			if (z80_fetch_count >= 4'd7) z80_fetch_count_reached_8_r <= 1'b1;
		end
	end
	assign z80_fetch_count_reached_8 = z80_fetch_count_reached_8_r;

	// 2026-08-23, task #8 round 131: check the ONE genuinely dynamic
	// instrument-load call site (ROM 0x0882-0893) for the same CON=1/
	// RR=0 defect round 130 already fixed on the 5 statically-resolved
	// tables. This site reads its 11-byte table's address out of the
	// currently-playing song's own data stream (via DE) instead of a
	// fixed `LD HL,nnnn` literal, so it was invisible to round 120/130's
	// static scan of all 59 `CALL 0x042C` sites (58 of the 59 resolve to
	// one of 51 literal addresses; this is the 59th).
	//
	// round 131's first attempt tried to read the table's bytes back out
	// of a second, dedicated ROM-mirror BRAM at the captured address --
	// that failed to fit the device (an extra 32KB block was too much).
	// This version needs no extra memory at all: the SAME shared loader
	// body (entered via this call, whichever address HL holds) already
	// reads all three bytes that matter off the real bus on its own, at
	// fixed PC locations -- byte0/FBCON at 0x0435 (`LD C,(HL)`, HL still
	// at the table's base), byte4/modulator-SL-RR at 0x045E (after 4
	// intervening `INC HL`s), byte9/carrier-SL-RR at 0x048C (after 9) --
	// so this just watches the real CPU's own data bus (`z80_din`) at
	// those three points directly, gated to only this one invocation by
	// `dyn_active` (armed at 0x0887's own opcode fetch, the dynamic
	// path's unique `CALL 0x042C` site, and held through all three
	// captures). Each capture uses the same two-stage "PC hit arms a
	// flag, the very next non-opcode memory read is guaranteed by Z80
	// M-cycle timing to be that exact `LD C,(HL)`'s own (HL) access"
	// technique as round 131's first attempt (a 1-byte opcode leaves no
	// room for anything else to intervene) -- deliberately still not
	// reading T80's internal HL register directly, per round 6's own
	// history of that being a real risk of a wrong bit-offset wasting a
	// compile.
	wire z80_mem_read = mem_acc && !n_rd && n_m1;
	reg z80_mem_read_prev;
	always @(posedge clk) z80_mem_read_prev <= z80_mem_read;
	wire z80_mem_read_edge = z80_mem_read && !z80_mem_read_prev;

	wire pc_hit_0887_edge = z80_opcode_fetch_edge && (z80_addr == 16'h0887);
	wire pc_hit_0435_edge = z80_opcode_fetch_edge && (z80_addr == 16'h0435); // byte0 FBCON read site
	wire pc_hit_045e_edge = z80_opcode_fetch_edge && (z80_addr == 16'h045E); // byte4 mod SL/RR read site
	wire pc_hit_048c_edge = z80_opcode_fetch_edge && (z80_addr == 16'h048C); // byte9 car SL/RR read site

	reg dyn_active; // high from 0887's opcode fetch until byte9 is captured
	reg dyn_wait_byte0_pc, dyn_wait_byte4_pc, dyn_wait_byte9_pc; // waiting for the next specific PC hit
	reg dyn_arm_byte0, dyn_arm_byte4, dyn_arm_byte9; // PC hit seen, waiting for the mem-read edge
	reg [7:0] dyn_instr_fbcon_byte, dyn_instr_mod_rr_byte, dyn_instr_car_rr_byte;
	reg dyn_instr_captured_reg;
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			dyn_active <= 1'b0;
			dyn_wait_byte0_pc <= 1'b0; dyn_wait_byte4_pc <= 1'b0; dyn_wait_byte9_pc <= 1'b0;
			dyn_arm_byte0 <= 1'b0; dyn_arm_byte4 <= 1'b0; dyn_arm_byte9 <= 1'b0;
			dyn_instr_captured_reg <= 1'b0;
		end else begin
			if (pc_hit_0887_edge) begin
				dyn_active <= 1'b1;
				dyn_wait_byte0_pc <= 1'b1;
			end
			if (dyn_active && dyn_wait_byte0_pc && pc_hit_0435_edge) begin
				dyn_wait_byte0_pc <= 1'b0;
				dyn_arm_byte0 <= 1'b1;
			end
			if (dyn_arm_byte0 && z80_mem_read_edge) begin
				dyn_arm_byte0 <= 1'b0;
				dyn_instr_fbcon_byte <= z80_din;
				dyn_wait_byte4_pc <= 1'b1;
			end
			if (dyn_active && dyn_wait_byte4_pc && pc_hit_045e_edge) begin
				dyn_wait_byte4_pc <= 1'b0;
				dyn_arm_byte4 <= 1'b1;
			end
			if (dyn_arm_byte4 && z80_mem_read_edge) begin
				dyn_arm_byte4 <= 1'b0;
				dyn_instr_mod_rr_byte <= z80_din;
				dyn_wait_byte9_pc <= 1'b1;
			end
			if (dyn_active && dyn_wait_byte9_pc && pc_hit_048c_edge) begin
				dyn_wait_byte9_pc <= 1'b0;
				dyn_arm_byte9 <= 1'b1;
			end
			if (dyn_arm_byte9 && z80_mem_read_edge) begin
				dyn_arm_byte9 <= 1'b0;
				dyn_instr_car_rr_byte <= z80_din;
				dyn_active <= 1'b0;
				dyn_instr_captured_reg <= 1'b1;
			end
		end
	end
	assign dyn_instr_captured = dyn_instr_captured_reg;
	assign dyn_instr_is_defective = dyn_instr_captured_reg && dyn_instr_fbcon_byte[0] &&
		((dyn_instr_mod_rr_byte[3:0] == 4'd0) || (dyn_instr_car_rr_byte[3:0] == 4'd0));

endmodule
