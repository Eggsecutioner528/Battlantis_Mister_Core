// Task #24 revival (Task #90): Direct Video portrait-rotation buffer,
// integrated form. Combines the confirmed-correct rotation addressing from
// rtl/direct_video_portrait_buffer.v and the confirmed output timing from
// rtl/direct_video_output_timing.v into a single module Battlantis.sv can
// instantiate, backed by real on-chip BRAM (double-buffered, 12 bits/pixel --
// 4 bits per channel, 4096 colors) instead of the prototypes' behavioral
// full-24-bit arrays.
//
// Why 12bpp double-buffered instead of 24bpp single-buffered: SDRAM was
// evaluated and rejected (rtl/sdram_arbiter.sv's ports are single-direction
// only, and per-pixel round-trip bandwidth doesn't fit the 8-clk_sys-cycle-
// per-pixel budget at 48MHz/6MHz). On-chip BRAM at full 24bpp only fits
// single-buffered (~168 of 180 free M10K blocks with zero spare for double-
// buffering), but single-buffering was rejected too: the native game timing
// (V_total=262/264, must not change) and this module's own output timing
// (V_total varies by mode below, e.g. 264 or 312, needed for real vertical
// blanking margin) have different frame lengths, so a single buffer tears
// predictably (roughly every 12 output frames at the original V_total=288
// this project first tried, before that mode was replaced -- the exact
// period depends on which mode's V_total is active, but the tearing risk
// itself applies to every mode here since none share native's exact
// frame length) as the write side gains a whole frame on the read side.
// Double-buffering avoids that entirely, and 12bpp (4 bits/channel)
// keeps double-buffering inside the M10K budget (~168 of 180 free blocks)
// with zero risk of the palette-index/stale-fade-color problem considered
// and rejected earlier for this same feature (this stores final resolved
// color, not a palette index, so it's immune to later palette RAM writes).
//
// Read-side BRAM inference follows this project's own proven, hard-won
// template (rtl/k007342.v's tile_cache_way0/way1, rtl/k007420.v's
// sprite_cache): each buffer is read completely UNCONDITIONALLY every cycle
// into its own dedicated raw-output register; the buffer-select decision
// (which of the two ping-pong buffers to actually use) happens downstream in
// a separate combinational mux driven by a registered qualifier, never by
// conditional logic in front of either buffer's own read address. This
// file's own project history (k007342.v circa line 883-891) documents
// Quartus M10K inference breaking twice from exactly the anti-pattern this
// avoids.
module direct_video_rotate (
    input clk,
    input ce_pix,   // native write-side pixel-rate enable (6MHz)
    input rst,
    // 2026-09-18: genlock fix for a confirmed real tearing bug (see
    // project_history/TASKS.md's 2026-09-18 entry -- an empirical
    // simulation test showed nearly every output frame mixing content from
    // two different native frames, because native's fixed V_TOTAL=262
    // frame period was never an integer multiple of any existing output
    // V_TOTAL_r's own frame period, so the double-buffer's "pick whichever
    // buffer isn't being written, once per output frame" guarantee didn't
    // actually hold -- the writer could start overwriting the buffer
    // currently on screen partway through its scan-out). out_clk is a
    // genuinely independent clock (~6.045801527 MHz, see pll_0002.v's own
    // port comment for the derivation) making V_TOTAL_r=264's own frame
    // period an EXACT integer multiple (1x) of native's real frame period
    // -- true genlock, not just a closer scanline-count guess. 2026-09-19:
    // Arcade (V_TOTAL_r=288) and PAL (V_TOTAL_r=312) now get their OWN
    // separately-tuned genlocked clocks the same way (pll_0002.v's
    // outclk_3/outclk_4), selected at runtime by Battlantis.sv's
    // altclkctrl-based dv_clk_mux from the same osd_hz_preset input this
    // module already uses for its V_TOTAL_r lookup below -- so the clock
    // SOURCE and the V_TOTAL_r VALUE switch together off one OSD
    // selection. All three presets verified tear-free in Verilator
    // (sim_scratch/dv_scale_test/sim_main_tear_multi.cpp), though real
    // hardware confirmation of the actual glitch-free clock switchover
    // (a real-silicon-only property Verilator's ideal clock model cannot
    // validate, same caveat as the original NTSC/Home genlock) is still
    // needed.
    input out_clk,

    // Write side: native raw raster, 256 active columns x 224 active rows.
    input        wr_en,        // pulse once per native active pixel
    input  [7:0] wr_col,       // 0-255 (native h_cnt within active window)
    input  [7:0] wr_row,       // 0-223 (native v_cnt within active window)
    input  [7:0] wr_r, wr_g, wr_b, // native full 8-bit color to capture
    input        wr_frame_end, // pulse once at native vblank boundary (swap)

    // 2026-10-01: un-retired the single ratio-locked osd_zoom control,
    // dropping the CRT Sizing/Width/Height preset-list pattern it had been
    // replaced by. User feedback: picking a named size from a list was an
    // unwelcome UX, and independent Width/Height adjustment -- while each
    // individually 7:8-locked at its own base -- lets a user drift the two
    // away from each other, which is exactly the class of distortion this
    // file's own history (the 2026-09-05 "text becoming gibberish"
    // regression) already identified as the real cost of independent-axis
    // sizing. osd_zoom scales BOTH axes together through a lookup table
    // that holds every step within a fraction of a percent of the true
    // native 224:256 ratio -- the aspect ratio cannot drift no matter what
    // a user picks. osd_h_trim/osd_v_trim (unchanged) move the picture
    // without resizing it.
    //
    // 2026-10-02: widened 5-bit/32-step (bidirectional, centered on a
    // default) to 6-bit/64-step, per user request to push the top end
    // closer to true native size with finer control. The old table's
    // smaller sizes are dropped entirely -- "Default" (osd_zoom=0) is now
    // the FLOOR of the range (172x197, the same picture this core has
    // shown since the Zoom control was introduced), and 1-63 dial upward
    // toward 203x232, the practical ceiling for this hardware's NTSC/Home
    // CRT Timing preset (264-line V_TOTAL) -- going further eats into real
    // vertical blanking margin for a diminishing, increasingly risky
    // return; the Arcade/PAL presets have more spare margin and inherit
    // extra headroom automatically from the same table since the
    // sync-safety clamp further down is already preset-aware. Since the
    // range is no longer centered, osd_zoom indexes the table directly --
    // no sentinel-offset math needed, unlike the old bidirectional design.
    input  [5:0] osd_zoom,
    input  [4:0] osd_h_trim,
    input  [4:0] osd_v_trim,
    // 2026-10-02: CRT H Stretch/V Stretch (an independent fine-tune ON TOP
    // of osd_zoom's base size) removed after real-hardware feedback found
    // it produces edge-clamp artifacts ("dead pixels") whenever it widens
    // the sampled field of view past the native 256x224 source -- the
    // active window size (h_active_r) never changed, only the sampling
    // ratio did, so "stretching" past native pushed the source index past
    // its valid 0-255/0-223 range and the existing clamp just repeated the
    // last valid edge pixel. Replaced by osd_h_crunch below, which fixes
    // this structurally by shrinking h_active_r itself (so it can never
    // need to sample outside the native source) instead of just changing
    // the ratio within a fixed-size window.
    //
    // osd_h_crunch: width-only squash, for fitting Horizontal mode's
    // naturally-oversized picture onto a given TV. Unlike osd_zoom (which
    // scales both axes together, aspect-locked), this touches ONLY the
    // h-axis (h_active_r + scale_num_h_r) -- v_active_r/scale_num_v_r are
    // completely untouched. This is a deliberate aspect-ratio distortion
    // (same idea as a real CRT's independent H-SIZE control), not a bug.
    // Always shrinks from whatever osd_zoom already selected; never widens
    // past it, so it structurally cannot hit the Stretch failure class
    // above -- every combination still samples strictly within the native
    // 256x224 source. Deliberately coarse: a flat 16-entry delta table
    // (crunch=0 is an exact no-op; 1-15 shave 2 h_active_r columns/step,
    // 30 columns/~17% max at osd_zoom's floor), applied as a fixed offset
    // on top of whichever osd_zoom table entry is active -- this is an
    // approximation (verified by exhaustive sweep to be within ~6.3% of
    // the exact native-width ratio at the far corner of the zoom/crunch
    // combination space, vs. Zoom's own ~0.2%), acceptable since this is
    // explicitly a "fit it on the screen" control, not a precision one.
    // Register headroom reverified for the combined worst case (scale_num
    // up to 1617, row_numer product up to 242,348 -- both comfortably
    // inside the already-widened 16-bit/20-bit registers from the Stretch
    // rebuild, nowhere near their ceilings).
    input  [3:0] osd_h_crunch,
    // Task #92 follow-up: which output frequency preset to run at --
    // 0=NTSC/Home, 1=Arcade, 2=PAL (encoding 3 unused). See the registered
    // V_TOTAL_r/VSYNC_START_r/VSYNC_END_r lookup table further down for the
    // full derivation of each preset's numbers.
    input  [1:0] osd_hz_preset,
    // 2026-09-18: this module had no flip/rotation-direction input at all --
    // "Flip Monitor" (Battlantis.sv's flip_monitor) was only ever wired
    // into the HDMI screen_rotate path, doing nothing on Direct Video's
    // rotated (Vertical-orientation) path, exactly the scenario a user
    // whose CRT is physically mounted in a fixed orientation needs. Adds
    // the second of the two possible 90-degree rotation directions (see
    // native_h/native_v below) -- a real correction, not a cosmetic toggle.
    input        osd_flip,

    // Output side: fully self-contained timing generator + rotated (and,
    // for some modes, scaled) pixel stream. H_total=384 @ ce_pix
    // (15,625 Hz, unchanged from native) in every mode. V_total, active
    // window size/position, and scaling ratio vary by selected CRT mode --
    // see the commented-out mode block below (default: Home CRT/NTSC,
    // Pixel Perfect, V_total=264, 196x224 active, scaled 7/8 from native).
    output           out_hsync,
    output           out_vsync,
    output           out_active,  // true within the centered active window
    output     [7:0] out_r, out_g, out_b // expanded back to 8 bits
);

    // 2026-09-18: rst arrives synchronous to clk_sys (Battlantis.sv's own
    // global reset); sampling it directly in the out_clk domain risks
    // metastability on deassertion. Standard 2-flop synchronizer, one per
    // clock domain that consumes it.
    reg out_rst_d1, out_rst;
    always @(posedge out_clk) begin
        out_rst_d1 <= rst;
        out_rst    <= out_rst_d1;
    end

    // ------------------------------------------------------------------
    // Output-side timing generator. Horizontal is ALWAYS unchanged from
    // native (H_TOTAL=384 @ 6MHz = 15,625 Hz exactly, matching PAL's
    // standard horizontal rate, already proven on real Direct Video
    // hardware) across every mode below -- only the active window
    // narrows/recenters/scales for the pillarbox. Everything else
    // (V_TOTAL, vsync position, active window size, and the scaling ratio)
    // changes between CRT modes.
    //
    // Pick ONE mode by leaving its block uncommented and commenting out the
    // others -- this mirrors Task #24's original compile-time Portrait/
    // Landscape toggle convention elsewhere in this project (different
    // physical setups need different constants, chosen once at build time,
    // not switched at runtime; this is deliberately NOT an OSD option).
    //
    // SCALE_NUM/SCALE_DEN (native:output ratio, applied to both axes) feed
    // a shared nearest-neighbor downscaler further below. SCALE_NUM=
    // SCALE_DEN=1 means no scaling (1:1, the historical/legacy behavior).
    // A mode that scales shows 100% of the native image, just smaller,
    // rather than cropping/discarding rows or columns off the edges --
    // this replaced an earlier crop-based NTSC mode for exactly that
    // reason (2026-09-04).
    // ------------------------------------------------------------------
    localparam H_TOTAL = 384;

    // --- MODE: Home CRT / NTSC, Pixel Perfect (ACTIVE DEFAULT) -----------
    // V_TOTAL=261 -> 15,625/261 = 59.8659 Hz -- the mathematically closest
    // achievable integer match to true NTSC (60000/1001 = 59.94006 Hz,
    // diff only -0.0741 Hz / 0.12%) given H_TOTAL=384 is fixed. Confirmed
    // 2026-09-04 by the user's own real hardware: their consumer CRT plays
    // natively at 59.94 Hz, so this is chasing a real, known target, not a
    // generic "NTSC-ish" guess. Checked every integer V_TOTAL from 259-264
    // directly: 261 wins (260 is +0.156 Hz off, 262 is -0.303 Hz off -- both
    // roughly 2-4x further from true NTSC than 261). Leaves 37 lines of
    // vertical blanking at V_ACTIVE=224 -- 3 fewer than the previous
    // V_TOTAL=264 choice, but still comfortably more than the 32-line
    // margin that caused real wrapping/overscan problems at V_TOTAL=288
    // earlier in this task's history. 264 (~59.19 Hz) was real-hardware-
    // confirmed (2026-09-04) to fix the earlier PAL mode's 50Hz flicker on
    // this same Sony Trinitron; 261 keeps that same fix while tightening
    // the frequency match further now that the TV's real native rate is
    // confirmed. Scales BOTH axes by 7/8 (256->224 height, 224->196 width)
    // instead of cropping, so no game content is discarded. Name matches
    // this project's own "Aspect ratio: Pixel Perfect" OSD naming
    // convention on the (separate, unaffected) HDMI path, reused here only
    // for a consistent name -- not wired into that OSD option.
    // 2026-09-04 follow-up: reverted to V_TOTAL=264 as the active default.
    // The 261 config above was only math-checked, never hardware-tested on
    // its own before this file's first real deploy with it -- and that
    // deploy showed a new failure mode (picture rendering into a small,
    // shrunk box instead of filling H_ACTIVE x V_ACTIVE), consistent with
    // this consumer CRT's fixed-frequency deflection/AGC not locking
    // cleanly to yet another untested vertical rate (same class of problem
    // documented below for V_TOTAL=288's oversized/wrapping failure, just
    // in the opposite direction). V_TOTAL=264 is the one combination in
    // this file's history with an actual confirmed-good real-hardware
    // result (fixed the earlier PAL mode's 50Hz flicker, no reported
    // size/geometry problem) -- standing on that until 261 (or anything
    // else) can be independently re-verified.
    // localparam V_TOTAL     = 261;
    // localparam VSYNC_START = 242; // = V_ACT_END (18+224), matches this
    //                                // mode's own convention of placing vsync
    //                                // immediately after the active window
    // localparam VSYNC_END   = 245;
    // localparam H_ACTIVE    = 196; // 224 * 7/8
    // localparam V_ACTIVE    = 224; // 256 * 7/8
    // localparam SCALE_NUM_H = 8; // renamed 2026-09-04 (scaler split H/V, see Arcade mode below)
    // localparam SCALE_DEN_H = 7;
    // localparam SCALE_NUM_V = 8;
    // localparam SCALE_DEN_V = 7;

    // --- MODE: Home CRT / NTSC, Original ----------------------------------
    // Same V_TOTAL=264 vertical timing as Pixel Perfect above (same real-
    // hardware flicker fix). Scales BOTH axes by 3/4 instead (256->192
    // height, 224->168 width) -- a bigger, more visible reduction than
    // Pixel Perfect's 7/8. Name matches this project's "Aspect ratio:
    // Original" OSD naming convention for the same reason (consistent
    // naming, not the same runtime option).
    // 2026-09-04 follow-up #2: user's direct real-hardware eyeball feedback
    // (not a new photo measurement) on this V_TOTAL=264 mode's own first
    // deploy: the picture is too large by about 5%, applied to BOTH height
    // and width uniformly (not one axis). Scale factor tightened from 3/4
    // (0.75 of native) towards a ~5% cut -- 0.75*0.95 = 0.7125 exactly.
    // 2026-09-04 follow-up #3: the first attempt at this (5/7 = 0.71429)
    // reintroduced a real TimeQuest setup violation, because SCALE_DEN=5
    // isn't a power of two and this scaler's divide stage (further down
    // this file) only stays cheap when it is -- see that stage's own
    // comment for the full root-cause. Landed on 45/32 = 0.71111 instead:
    // a 0.19% difference from 0.7125, and SCALE_DEN=32 is a clean power of
    // two, making the divide a free constant right-shift with zero timing
    // risk.
    // 2026-09-04 follow-up #4: user's next real-hardware look at that
    // 45/32 deploy: it over-corrected -- the requested 5% cut, once
    // rendered, read as too small, and the user's own read on WHY was that
    // the size change was making the (unchanged-in-absolute-terms)
    // position trims below look bigger than intended, since the same trim
    // is a larger fraction of a smaller window. So: revert the SIZE all
    // the way back to 3/4 (0.75) -- undoing the 5% cut entirely -- while
    // leaving H_CENTER_TRIM/V_CENTER_TRIM below untouched, on the
    // reasoning that going back to the bigger window should make that same
    // trim read as proportionally smaller again, and because those trims
    // auto-center around the middle of H_TOTAL/V_TOTAL regardless of
    // H_ACTIVE/V_ACTIVE (see the H_ACT_START/V_ACT_START formulas below),
    // growing the window keeps the top/bottom (and left/right) edges
    // symmetric around the same corrected center rather than shifting it.
    // Still can't use an exact 3/4 here (no power-of-two SCALE_DEN divides
    // evenly into 3), so used 171/128 = 0.74854 instead -- 0.19% off exact
    // 0.75 (same precision loss already accepted for 45/32 above), and it
    // happens to round to the IDENTICAL H_ACTIVE/V_ACTIVE as literal 3/4
    // (168x192), so this is visually indistinguishable from true 3/4 while
    // keeping SCALE_DEN=128 a power of two.
    // 2026-09-04 follow-up #5: user explicitly asked to try V_TOTAL=288
    // (54.25 Hz, the "Arcade" mode below) again, after being told directly
    // that this exact combination previously produced a confirmed oversized/
    // wrapping picture on this same consumer CRT, and that 288 sits further
    // from the TV's own native 59.94Hz than either NTSC mode -- user chose
    // to proceed anyway. Commenting this 264 block out rather than deleting
    // it; it's the one combination in this file's history with a fully
    // confirmed-good real-hardware result, so it's the fallback if 288
    // reproduces its earlier failure.
    // 2026-09-05 follow-up (ACTIVE again): 288 did reproduce a failure --
    // worse than the original oversizing, an INTERMITTENT vertical sync
    // lock loss (top of frame wrapping into the middle of the screen,
    // inconsistently recoverable by toggling orientation) -- see the
    // Arcade mode's own follow-up #9 comment below for the full account.
    // Reactivating this block as the default. This is genuinely just this
    // mode's own baseline (168x192, no distortion) -- the height-stretch,
    // bottom-edge, and width-squish work done on top of V_TOTAL=288 does
    // NOT carry over numerically, because this CRT's fixed-frequency
    // deflection responds differently (nonlinearly) to different vertical
    // rates -- that's the same reason 288 and the old 261 attempt each
    // produced their own distinct size/position bugs. Any further height/
    // width/position requests need to be re-tuned from THIS baseline using
    // real feedback at 264, not translated from the 288 numbers.
    // 2026-09-05 follow-up: user provided real photos of the game's own
    // test/convergence grid pattern on this stable V_TOTAL=264 baseline,
    // showing the top margin (empty space above the grid) visibly bigger
    // than the bottom margin -- asked for a measured (not eyeballed) fix,
    // both repositioning to equalize the margins and growing the active
    // window to fill as much of them as safely possible.
    //
    // Measured directly from the photo (Screenshot 2026-09-05 011357.png,
    // 936x635, vertical scan at horizontal center, OpenCV brightness
    // profile): screen top edge (bezel->glass) at y=52.2, grid top edge at
    // y=134.5, grid bottom edge at y=553.5, screen bottom edge (glass->
    // bezel) at y=607.5. Rather than assume V_TOTAL maps linearly onto the
    // full physical screen sweep (already shown unreliable on this fixed-
    // frequency CRT -- that assumption's own predictions were off by
    // roughly a factor of 1.4x on both margins here), calibrated instead
    // using the grid pattern's OWN known span: it's the game's full active
    // window, exactly V_ACTIVE=192 raster lines, measured at 419px ->
    // 2.182 px/line. This makes the pixel-to-line conversion self-
    // referential to the actual rendered image instead of an assumption
    // about the CRT's overall sweep behavior.
    //
    // Top margin: 82.3px = 37.7 lines. Bottom margin: 54.0px = 24.7 lines.
    // Imbalance = 13.0 lines -> shift up 6 lines (half the imbalance) to
    // equalize both sides. From the old V_ACT_START=28 (V_ACTIVE=192,
    // V_CENTER_TRIM=-8), shifting up 6 lines gives V_ACT_START=22.
    // Then grow to fill both margins as far as safely possible: the top's
    // only ceiling is V_ACT_START>=0 (22 lines of headroom from the
    // shifted position); the bottom's ceiling is keeping a real margin
    // before VSYNC_START=244 -- using the same 8-line safety margin
    // established for the earlier V_TOTAL=288 work, that's V_ACT_END<=236,
    // also exactly 22 lines of headroom from the shifted V_ACT_END=214.
    // Both sides support the identical 22-line growth, so grew
    // symmetrically: V_ACT_START=0, V_ACT_END=236, V_ACTIVE=236 (+44 from
    // 192), V_CENTER_TRIM=-14 (solved algebraically: 0 = (264-236)/2 +
    // V_CENTER_TRIM = 14 + V_CENTER_TRIM).
    //
    // 2026-09-05 follow-up: that 236 fill went a hair too far -- user's
    // next real-hardware look reported both top and bottom just barely
    // cut off, and asked for a 1-1.5% shrink. Used the 1.5% end (232, a
    // -4 line / -1.69% change from 236): with V_CENTER_TRIM unchanged at
    // -14, this comes out to an exactly symmetric 2-line trim off BOTH
    // edges (V_ACT_START 0->2, V_ACT_END 236->234), matching the
    // symmetric "just barely cut off on both sides" report -- not a
    // one-sided position correction like the earlier margin-imbalance fix.
    // 2026-09-05 follow-up: after the symmetric 232 trim, user reported the
    // TOP is now perfectly visible but the BOTTOM is still just off-screen
    // -- an asymmetric residual, so this fix is asymmetric too: keep
    // V_ACT_START=2 (the now-confirmed-correct top) exactly fixed, only
    // pull V_ACT_END up. Also requested a ~3% narrower width test
    // (168->163, user's own explicit number, not derived). Bundled into
    // one compile: H_ACTIVE 168->163 (SCALE_NUM_H 171->176, same
    // SCALE_DEN_H=128 shift), V_ACTIVE 232->228 (~1.7% off the bottom
    // only; SCALE_NUM_V 141->144 lands on 228, the closest achievable
    // value to the targeted 227 at this DEN), V_CENTER_TRIM solved to keep
    // V_ACT_START=2: (264-228)/2 + trim = 2 -> 18+trim=2 -> trim=-16.
    // New V_ACT_END = 2+228 = 230 (was 234).
    //
    // 2026-09-05 follow-up: after the scaler OOB fix (verified, real, and
    // deployed), user still reported the same defect -- but reframed it
    // more precisely as a SHIMMER in a triangular pattern, not static
    // corruption, and hypothesized a vertical-sync frequency mismatch
    // rather than a data bug. That fits the evidence better than the OOB
    // theory alone: a Verilator-vs-MAME comparison of the same screen (the
    // convergence/test grid, "green" in the user's own description) showed
    // MAME's reference rendering completely clean, and the shimmer
    // persisted even after the confirmed-and-verified OOB fix was
    // deployed -- a data-corruption bug wouldn't survive a real fix, but a
    // genuine analog beat-frequency interference between our output rate
    // and the CRT's own deflection timing would. V_TOTAL=264 computes to
    // 59.19 Hz; the user's CRT's own measured native rate is 59.94 Hz -- a
    // real 0.75 Hz mismatch. Testing V_TOTAL=261 instead (59.87 Hz, only
    // 0.07 Hz off -- the closest achievable match given H_TOTAL=384 is
    // fixed, see this file's very first mode block for the full frequency
    // derivation) to see if closing that gap removes the shimmer.
    // H_ACTIVE/V_ACTIVE/SCALE_NUM/DEN and H_CENTER_TRIM are carried over
    // unchanged from the 264 tuning above as a starting point ONLY, not
    // because they're expected to still be exactly right -- this project
    // has now seen twice that this CRT's geometry response doesn't
    // transfer cleanly between different V_TOTAL values (264 and 288 each
    // needed their own independently-measured trims), so position/size
    // will likely need fresh real-hardware re-tuning at 261 regardless of
    // whether this fixes the shimmer.
    //
    // 2026-09-05 follow-up #2: before this ever got deployed/checked, user
    // gave new explicit target sizes instead of carrying over the 264
    // tuning -- H_ACTIVE=160 ("seems like a safe number for most TVs") and
    // V_ACTIVE=220. Both user-specified numbers, not derived from any
    // measurement, same as H_ACTIVE=163's own precedent earlier. Solved
    // for the closest achievable SCALE_NUM at DEN=128 (power of two,
    // unchanged): H: round(128*224/160)=179 -> H_ACTIVE=round(224*128/179)
    // =160 exact. V: round(128*256/220)=149 -> V_ACTIVE=round(256*128/149)
    // =220 exact. H_CENTER_TRIM/V_CENTER_TRIM carried over unchanged
    // (still just a starting point at this new V_TOTAL, per the note
    // above). Safety margin re-checked for the new, smaller V_ACTIVE:
    // V_ACT_START=(261-220)/2+(-16)=4, V_ACT_END=224, 18 lines clear of
    // VSYNC_START=242 (more margin than before, since V_ACTIVE shrank).
    // 2026-09-05 follow-up #3: real-hardware result at 261 was informative
    // in an unexpected way -- the shimmer changed DIRECTION (not just
    // severity) versus 264. Both 264 (59.19Hz) and 261 (59.87Hz) sit BELOW
    // the user's measured 59.94Hz target, so a pure "distance from 59.94"
    // model wouldn't predict a sign flip -- this means the CRT's actual
    // internal lock frequency isn't exactly 59.94Hz on the nose (real
    // analog deflection oscillators have their own tolerance). A direction
    // flip is exactly the signature of crossing a beat-frequency zero
    // point, so the true crossover lies somewhere in the range already
    // tested. Testing V_TOTAL=260 next -- the first integer step that
    // goes ABOVE the nominal target (15625/260=60.0962Hz, +0.156Hz over
    // 59.94) instead of below -- to find out which side of the real
    // crossover this lands on. VSYNC_START/END follow this file's own
    // established convention of ~17 lines of back porch after vsync before
    // wrap (matches 264's 244-247/17-line gap and 261's 242-245/16-line
    // gap): VSYNC_END=260-17=243, VSYNC_START=240. Size/trims carried over
    // unchanged from 261 as a starting point only, per this file's now
    // well-established pattern of needing fresh re-tuning per V_TOTAL;
    // safety margin re-checked: V_ACT_START=(260-220)/2+(-16)=4,
    // V_ACT_END=224, 16 lines clear of VSYNC_START=240.
    // 2026-09-05 follow-up #6: user correction overturns the working
    // crossover model above -- shimmer is confirmed STILL PRESENT at 260
    // (60.10Hz, ABOVE the 59.94Hz nominal target), while V_TOTAL=288
    // (54.25Hz, the Arcade mode further down, tested this session for an
    // unrelated reason) showed NO shimmer at all. A pure "narrow zero-
    // crossing near 59.94Hz" model predicted the opposite (264/261/260
    // bracket the crossover; 288 is far outside that bracket and should be
    // WORSE, not better). Since 288 does carry its own separate, expected
    // problem instead (a rolling mains-hum bar, unrelated to shimmer --
    //54.25Hz isn't close to the 60Hz AC line, so PSU ripple doesn't freeze
    // in place), the two effects don't share one sweet spot: hum-bar wants
    // to be near 60Hz, but shimmer's true crossover is now known to sit
    // somewhere in the large unexplored 261-288 gap, not near 59.94Hz.
    // Bisecting that gap: V_TOTAL=274 (15,625/274=57.02Hz, roughly midway)
    // as the next data point, to find out which half of the gap the real
    // crossover is in before narrowing further. VSYNC_END/START follow
    // this file's own established 17-line-back-porch convention (VSYNC_END
    // = V_TOTAL-17, matching 264's 247 and 260's 243): VSYNC_END=257,
    // VSYNC_START=254 (3-line pulse, same as every other mode here).
    // Safety margin: re-ran the same exhaustive per-LUT-entry x 32-trim
    // clamp sweep used for the Task #92 table itself, now against
    // V_SAFE_MAX_END=VSYNC_START-4=250 -- zero violations, worst-case
    // margin 7 lines (at the largest V_ACTIVE=214 combined with the most
    // extreme negative v_trim) -- tighter than the H axis's 56-line
    // margin but still a real positive margin in every combination, not
    // just the default. Size/position are Task #92 OSD-adjustable now, so
    // no fresh compile-time re-tuning is needed here even though this
    // file's own established pattern says position will likely need
    // re-centering at this new V_TOTAL -- that can be done live via the
    // OSD's CRT Position controls instead of another compile.
    // 2026-09-05 follow-up #7: user confirmed shimmer at 274 (57.03Hz) is
    // "better" but still present -- consistent with the monotonic trend
    // continuing toward 288 (54.25Hz, confirmed shimmer-free but rolling
    // since it's too far from this consumer set's vertical-hold range for
    // it to lock without a manual vertical-hold adjustment, which this
    // particular Trinitron doesn't have). Bisecting the remaining 274-288
    // gap: V_TOTAL=284 (15,625/284=55.02Hz). VSYNC_END/START follow the
    // same 17-line-back-porch convention as every mode in this file:
    // VSYNC_END=284-17=267, VSYNC_START=264. Safety re-verified with the
    // same exhaustive per-LUT-entry x 32-trim sweep against
    // V_SAFE_MAX_END=VSYNC_START-4=260: zero violations, worst-case
    // margins 56 (H) / 12 (V) lines.
    // 2026-09-05 follow-up #8: Task #92 extended to cover V_TOTAL/VSYNC
    // itself, not just size/position -- osd_hz_preset selects between three
    // real-world-motivated frequencies instead of requiring a recompile per
    // Hz test (as every V_TOTAL change earlier this session did). Unlike
    // osd_zoom/trim, there's no "sentinel field 0 = default" convention
    // here -- all 3 encodings are equally real named presets, so the field
    // maps directly to an index (2 bits, encoding 3 unused/reserved,
    // defaults to preset 0 same as an out-of-range case always would).
    // Values, each independently confirmed on real hardware or matching a
    // named broadcast standard exactly (see this file's own mode-block
    // history above/below for each one's own derivation):
    //   0 = "NTSC/Home"  V_TOTAL=284 (55.02Hz) -- THIS user's own real
    //       Trinitron, confirmed shimmer-free -- also this preset's
    //       default (field value 0), since it's the one confirmed to work.
    //   1 = "Arcade"     V_TOTAL=288 (54.25Hz) -- the arcade board's own
    //       native rate; shimmer-free on this same TV but rolls (this
    //       specific set's vertical hold can't lock that far from 60Hz).
    //   2 = "PAL"        V_TOTAL=312 (50.08Hz) -- true PAL broadcast
    //       standard (H_TOTAL=384 already exactly matches PAL's own
    //       15,625Hz line rate with zero adjustment); untested by this
    //       project's own user (NTSC-region TV) but previously verified on
    //       real MiSTer hardware to lock and display correctly (only
    //       ordinary 50Hz-class flicker, inherent to any PAL-rate CRT, not
    //       a defect) -- the responsible choice given no real PAL set to
    //       test against, rather than guessing at a "detuned" PAL value
    //       (this user's own 55.02Hz offset from NTSC nominal is a property
    //       of THIS specific aging unit's deflection drift, not a
    //       transferable constant to a different, unrelated television).
    // Registered (not combinational) for the same reason h_active_r/
    // v_active_r above are: this feeds the same already-registered
    // H_ACT_START/END/V_ACT_START/END pipeline, so adding these as more
    // registered LUT outputs costs zero additional combinational depth on
    // that already-timing-sensitive path.
    // 2026-09-18: NTSC/Home changed from V_TOTAL=284 to V_TOTAL=264 --
    // this is the ONE value out_clk was specifically tuned to genlock (see
    // this module's own out_clk port comment). Arcade/PAL are unchanged in
    // scanline count, but now run on the same physical out_clk, so their
    // absolute Hz shifts by the same small amount this genlock required
    // (they are not themselves genlocked -- 288 and 312 are not integer
    // multiples of native's 262 at any single clock rate shared with 264).
    reg [8:0] V_TOTAL_r, VSYNC_START_r, VSYNC_END_r;
    always @(posedge out_clk) begin
        case (osd_hz_preset)
            2'd0: begin V_TOTAL_r = 9'd264; VSYNC_START_r = 9'd244; VSYNC_END_r = 9'd247; end // NTSC/Home (genlocked)
            2'd1: begin V_TOTAL_r = 9'd288; VSYNC_START_r = 9'd272; VSYNC_END_r = 9'd275; end // Arcade
            2'd2: begin V_TOTAL_r = 9'd312; VSYNC_START_r = 9'd284; VSYNC_END_r = 9'd287; end // PAL
            default: begin V_TOTAL_r = 9'd264; VSYNC_START_r = 9'd244; VSYNC_END_r = 9'd247; end
        endcase
    end
    // 2026-09-05 follow-up #4: user reported on-screen text/characters
    // becoming much harder to read, appearing as gibberish -- correctly
    // identified the cause as accumulated aspect-ratio distortion drifting
    // away from the game's TRUE native shape. Native Battlantis is 224x256
    // (post-rotation width x height), which reduces EXACTLY to 7:8 (no
    // rounding) -- this project's earlier intentional height-stretch/
    // width-squish requests (explicitly asked for, to better fill this
    // specific CRT) had pulled the ratio away from that, distorting small
    // character glyphs (drawn as native-resolution bitmaps) more than
    // large sprites, which is why it's the TEXT specifically that degrades
    // fastest under a ratio drift. Solved for the V_ACTIVE that restores
    // exact 7:8 at the user's current H_ACTIVE=160: V_ACTIVE = 160*(8/7) =
    // 182.86, rounds to 183. Achieved with SCALE_DEN_V=128 (unchanged
    // power-of-two shift) and SCALE_NUM_V=round(128*256/183)=179 ->
    // V_ACTIVE=round(256*128/179)=183 exact. Safety margin re-checked:
    // V_ACT_START=(260-183)/2+(-16)=22, V_ACT_END=205, 35 lines clear of
    // VSYNC_START=240 (ample -- the shrink freed up a lot of room).
    // H_ACTIVE/V_ACTIVE/SCALE_NUM_H/SCALE_NUM_V are driven by the runtime
    // osd_zoom field through the lookup table below. SCALE_DEN stays a
    // fixed compile-time power of two (128) for every table entry -- only
    // the numerator varies -- so the scaler's divide (further down)
    // remains a free constant shift regardless of which zoom step is
    // selected; there is no runtime divider anywhere in this design.
    // 2026-10-02: table rebuilt for the new floor-to-ceiling range (see
    // this module's port-list comment for the full rationale). All 64
    // entries still lock both axes to the exact native 224:256 (7:8)
    // ratio (max error 0.218%, same precision class as the prior 32-entry
    // table). osd_zoom indexes this table directly (0=floor=172x197,
    // 63=ceiling=203x232) -- no sentinel-offset indirection, since the
    // range is no longer centered. Safety margin re-verified for the new
    // ceiling: at V_ACTIVE=232, NTSC/Home's V_TOTAL=264 leaves 32 lines of
    // total vertical blanking (vs. 50 for the old table's ceiling of 214)
    // -- a real, deliberate reduction in margin, chosen over an even
    // tighter alternative (203x232 instead of the true digital-safety-
    // clamp limit of 210x240/24 lines) specifically because this file's
    // own history has already shown once that a margin which is safe by
    // the digital sync-overlap clamp isn't automatically safe on a real
    // CRT's analog vertical retrace (the V_TOTAL=288 "Arcade" mode's
    // intermittent lock-loss, see that mode's own comment above). Not yet
    // confirmed on real hardware at the new ceiling -- expect to possibly
    // need to back off a few steps if NTSC/Home doesn't lock cleanly
    // there. The Arcade/PAL CRT Timing presets have more spare blanking
    // margin at V_TOTAL=288/312 and inherit the extra headroom
    // automatically from the same already-preset-aware sync-safety clamp
    // further down -- no separate table needed for them.
    // 2026-10-02: 128->1024 (8x), originally for finer Stretch steps (since
    // removed, see osd_h_crunch's port comment above) -- kept at 1024 since
    // osd_h_crunch's own deltas were derived against this denominator, and
    // row_numer_r/col_numer_r (below) already have the headroom for it.
    localparam SCALE_DEN_H = 1024;
    localparam SCALE_DEN_V = 1024;
    wire [5:0] zoom_idx = osd_zoom;
    // 2026-10-02: osd_h_crunch's 16-entry delta table, precomputed and
    // exhaustively verified offline (same discipline as the Zoom/Stretch
    // tables) -- see this module's osd_h_crunch port comment for the full
    // derivation. crunch=0 is an exact no-op (both deltas 0); each step
    // shaves 2 columns off h_active_r and adds the scale_num_h_r delta
    // needed to keep mapping the full native source into that narrower
    // window (so this structurally cannot sample outside native bounds,
    // unlike the removed Stretch). h_crunch_ext is added directly into the
    // same 16'd### constants the zoom table already computes scale_num_h_r
    // from, same mechanism the removed h_stretch_ext used.
    reg [5:0]  h_crunch_active_delta;
    reg [15:0] h_crunch_ext;
    always @(*) begin
        case (osd_h_crunch)
            4'd0 : begin h_crunch_active_delta=6'd0;  h_crunch_ext=16'd0;   end
            4'd1 : begin h_crunch_active_delta=6'd2;  h_crunch_ext=16'd15;  end
            4'd2 : begin h_crunch_active_delta=6'd4;  h_crunch_ext=16'd31;  end
            4'd3 : begin h_crunch_active_delta=6'd6;  h_crunch_ext=16'd48;  end
            4'd4 : begin h_crunch_active_delta=6'd8;  h_crunch_ext=16'd65;  end
            4'd5 : begin h_crunch_active_delta=6'd10; h_crunch_ext=16'd82;  end
            4'd6 : begin h_crunch_active_delta=6'd12; h_crunch_ext=16'd100; end
            4'd7 : begin h_crunch_active_delta=6'd14; h_crunch_ext=16'd118; end
            4'd8 : begin h_crunch_active_delta=6'd16; h_crunch_ext=16'd136; end
            4'd9 : begin h_crunch_active_delta=6'd18; h_crunch_ext=16'd155; end
            4'd10: begin h_crunch_active_delta=6'd20; h_crunch_ext=16'd175; end
            4'd11: begin h_crunch_active_delta=6'd22; h_crunch_ext=16'd195; end
            4'd12: begin h_crunch_active_delta=6'd24; h_crunch_ext=16'd216; end
            4'd13: begin h_crunch_active_delta=6'd26; h_crunch_ext=16'd237; end
            4'd14: begin h_crunch_active_delta=6'd28; h_crunch_ext=16'd259; end
            4'd15: begin h_crunch_active_delta=6'd30; h_crunch_ext=16'd281; end
        endcase
    end
    reg [8:0] h_active_r, v_active_r;
    reg [15:0] scale_num_h_r, scale_num_v_r;
    always @(posedge out_clk) begin
        case (zoom_idx)
            6'd0 : begin h_active_r=9'd172; v_active_r=9'd197; scale_num_h_r=16'd1336 + h_crunch_ext; scale_num_v_r=16'd1328; end
            6'd1 : begin h_active_r=9'd172; v_active_r=9'd197; scale_num_h_r=16'd1336 + h_crunch_ext; scale_num_v_r=16'd1328; end
            6'd2 : begin h_active_r=9'd173; v_active_r=9'd198; scale_num_h_r=16'd1328 + h_crunch_ext; scale_num_v_r=16'd1320; end
            6'd3 : begin h_active_r=9'd173; v_active_r=9'd198; scale_num_h_r=16'd1328 + h_crunch_ext; scale_num_v_r=16'd1320; end
            6'd4 : begin h_active_r=9'd174; v_active_r=9'd199; scale_num_h_r=16'd1320 + h_crunch_ext; scale_num_v_r=16'd1320; end
            6'd5 : begin h_active_r=9'd174; v_active_r=9'd199; scale_num_h_r=16'd1320 + h_crunch_ext; scale_num_v_r=16'd1320; end
            6'd6 : begin h_active_r=9'd175; v_active_r=9'd200; scale_num_h_r=16'd1312 + h_crunch_ext; scale_num_v_r=16'd1312; end
            6'd7 : begin h_active_r=9'd175; v_active_r=9'd200; scale_num_h_r=16'd1312 + h_crunch_ext; scale_num_v_r=16'd1312; end
            6'd8 : begin h_active_r=9'd176; v_active_r=9'd201; scale_num_h_r=16'd1304 + h_crunch_ext; scale_num_v_r=16'd1304; end
            6'd9 : begin h_active_r=9'd176; v_active_r=9'd201; scale_num_h_r=16'd1304 + h_crunch_ext; scale_num_v_r=16'd1304; end
            6'd10: begin h_active_r=9'd177; v_active_r=9'd202; scale_num_h_r=16'd1296 + h_crunch_ext; scale_num_v_r=16'd1296; end
            6'd11: begin h_active_r=9'd177; v_active_r=9'd202; scale_num_h_r=16'd1296 + h_crunch_ext; scale_num_v_r=16'd1296; end
            6'd12: begin h_active_r=9'd178; v_active_r=9'd203; scale_num_h_r=16'd1288 + h_crunch_ext; scale_num_v_r=16'd1288; end
            6'd13: begin h_active_r=9'd178; v_active_r=9'd203; scale_num_h_r=16'd1288 + h_crunch_ext; scale_num_v_r=16'd1288; end
            6'd14: begin h_active_r=9'd179; v_active_r=9'd205; scale_num_h_r=16'd1280 + h_crunch_ext; scale_num_v_r=16'd1280; end
            6'd15: begin h_active_r=9'd179; v_active_r=9'd205; scale_num_h_r=16'd1280 + h_crunch_ext; scale_num_v_r=16'd1280; end
            6'd16: begin h_active_r=9'd180; v_active_r=9'd206; scale_num_h_r=16'd1272 + h_crunch_ext; scale_num_v_r=16'd1272; end
            6'd17: begin h_active_r=9'd180; v_active_r=9'd206; scale_num_h_r=16'd1272 + h_crunch_ext; scale_num_v_r=16'd1272; end
            6'd18: begin h_active_r=9'd181; v_active_r=9'd207; scale_num_h_r=16'd1264 + h_crunch_ext; scale_num_v_r=16'd1264; end
            6'd19: begin h_active_r=9'd181; v_active_r=9'd207; scale_num_h_r=16'd1264 + h_crunch_ext; scale_num_v_r=16'd1264; end
            6'd20: begin h_active_r=9'd182; v_active_r=9'd208; scale_num_h_r=16'd1264 + h_crunch_ext; scale_num_v_r=16'd1264; end
            6'd21: begin h_active_r=9'd182; v_active_r=9'd208; scale_num_h_r=16'd1264 + h_crunch_ext; scale_num_v_r=16'd1264; end
            6'd22: begin h_active_r=9'd183; v_active_r=9'd209; scale_num_h_r=16'd1256 + h_crunch_ext; scale_num_v_r=16'd1256; end
            6'd23: begin h_active_r=9'd183; v_active_r=9'd209; scale_num_h_r=16'd1256 + h_crunch_ext; scale_num_v_r=16'd1256; end
            6'd24: begin h_active_r=9'd184; v_active_r=9'd210; scale_num_h_r=16'd1248 + h_crunch_ext; scale_num_v_r=16'd1248; end
            6'd25: begin h_active_r=9'd184; v_active_r=9'd210; scale_num_h_r=16'd1248 + h_crunch_ext; scale_num_v_r=16'd1248; end
            6'd26: begin h_active_r=9'd185; v_active_r=9'd211; scale_num_h_r=16'd1240 + h_crunch_ext; scale_num_v_r=16'd1240; end
            6'd27: begin h_active_r=9'd185; v_active_r=9'd211; scale_num_h_r=16'd1240 + h_crunch_ext; scale_num_v_r=16'd1240; end
            6'd28: begin h_active_r=9'd186; v_active_r=9'd213; scale_num_h_r=16'd1232 + h_crunch_ext; scale_num_v_r=16'd1232; end
            6'd29: begin h_active_r=9'd186; v_active_r=9'd213; scale_num_h_r=16'd1232 + h_crunch_ext; scale_num_v_r=16'd1232; end
            6'd30: begin h_active_r=9'd187; v_active_r=9'd214; scale_num_h_r=16'd1224 + h_crunch_ext; scale_num_v_r=16'd1224; end
            6'd31: begin h_active_r=9'd187; v_active_r=9'd214; scale_num_h_r=16'd1224 + h_crunch_ext; scale_num_v_r=16'd1224; end
            6'd32: begin h_active_r=9'd188; v_active_r=9'd215; scale_num_h_r=16'd1224 + h_crunch_ext; scale_num_v_r=16'd1216; end
            6'd33: begin h_active_r=9'd188; v_active_r=9'd215; scale_num_h_r=16'd1224 + h_crunch_ext; scale_num_v_r=16'd1216; end
            6'd34: begin h_active_r=9'd189; v_active_r=9'd216; scale_num_h_r=16'd1216 + h_crunch_ext; scale_num_v_r=16'd1216; end
            6'd35: begin h_active_r=9'd189; v_active_r=9'd216; scale_num_h_r=16'd1216 + h_crunch_ext; scale_num_v_r=16'd1216; end
            6'd36: begin h_active_r=9'd190; v_active_r=9'd217; scale_num_h_r=16'd1208 + h_crunch_ext; scale_num_v_r=16'd1208; end
            6'd37: begin h_active_r=9'd190; v_active_r=9'd217; scale_num_h_r=16'd1208 + h_crunch_ext; scale_num_v_r=16'd1208; end
            6'd38: begin h_active_r=9'd191; v_active_r=9'd218; scale_num_h_r=16'd1200 + h_crunch_ext; scale_num_v_r=16'd1200; end
            6'd39: begin h_active_r=9'd191; v_active_r=9'd218; scale_num_h_r=16'd1200 + h_crunch_ext; scale_num_v_r=16'd1200; end
            6'd40: begin h_active_r=9'd192; v_active_r=9'd219; scale_num_h_r=16'd1192 + h_crunch_ext; scale_num_v_r=16'd1200; end
            6'd41: begin h_active_r=9'd192; v_active_r=9'd219; scale_num_h_r=16'd1192 + h_crunch_ext; scale_num_v_r=16'd1200; end
            6'd42: begin h_active_r=9'd193; v_active_r=9'd221; scale_num_h_r=16'd1192 + h_crunch_ext; scale_num_v_r=16'd1184; end
            6'd43: begin h_active_r=9'd193; v_active_r=9'd221; scale_num_h_r=16'd1192 + h_crunch_ext; scale_num_v_r=16'd1184; end
            6'd44: begin h_active_r=9'd194; v_active_r=9'd222; scale_num_h_r=16'd1184 + h_crunch_ext; scale_num_v_r=16'd1184; end
            6'd45: begin h_active_r=9'd194; v_active_r=9'd222; scale_num_h_r=16'd1184 + h_crunch_ext; scale_num_v_r=16'd1184; end
            6'd46: begin h_active_r=9'd195; v_active_r=9'd223; scale_num_h_r=16'd1176 + h_crunch_ext; scale_num_v_r=16'd1176; end
            6'd47: begin h_active_r=9'd195; v_active_r=9'd223; scale_num_h_r=16'd1176 + h_crunch_ext; scale_num_v_r=16'd1176; end
            6'd48: begin h_active_r=9'd196; v_active_r=9'd224; scale_num_h_r=16'd1168 + h_crunch_ext; scale_num_v_r=16'd1168; end
            6'd49: begin h_active_r=9'd196; v_active_r=9'd224; scale_num_h_r=16'd1168 + h_crunch_ext; scale_num_v_r=16'd1168; end
            6'd50: begin h_active_r=9'd197; v_active_r=9'd225; scale_num_h_r=16'd1168 + h_crunch_ext; scale_num_v_r=16'd1168; end
            6'd51: begin h_active_r=9'd197; v_active_r=9'd225; scale_num_h_r=16'd1168 + h_crunch_ext; scale_num_v_r=16'd1168; end
            6'd52: begin h_active_r=9'd198; v_active_r=9'd226; scale_num_h_r=16'd1160 + h_crunch_ext; scale_num_v_r=16'd1160; end
            6'd53: begin h_active_r=9'd198; v_active_r=9'd226; scale_num_h_r=16'd1160 + h_crunch_ext; scale_num_v_r=16'd1160; end
            6'd54: begin h_active_r=9'd199; v_active_r=9'd227; scale_num_h_r=16'd1152 + h_crunch_ext; scale_num_v_r=16'd1152; end
            6'd55: begin h_active_r=9'd199; v_active_r=9'd227; scale_num_h_r=16'd1152 + h_crunch_ext; scale_num_v_r=16'd1152; end
            6'd56: begin h_active_r=9'd200; v_active_r=9'd229; scale_num_h_r=16'd1144 + h_crunch_ext; scale_num_v_r=16'd1144; end
            6'd57: begin h_active_r=9'd200; v_active_r=9'd229; scale_num_h_r=16'd1144 + h_crunch_ext; scale_num_v_r=16'd1144; end
            6'd58: begin h_active_r=9'd201; v_active_r=9'd230; scale_num_h_r=16'd1144 + h_crunch_ext; scale_num_v_r=16'd1136; end
            6'd59: begin h_active_r=9'd201; v_active_r=9'd230; scale_num_h_r=16'd1144 + h_crunch_ext; scale_num_v_r=16'd1136; end
            6'd60: begin h_active_r=9'd202; v_active_r=9'd231; scale_num_h_r=16'd1136 + h_crunch_ext; scale_num_v_r=16'd1136; end
            6'd61: begin h_active_r=9'd202; v_active_r=9'd231; scale_num_h_r=16'd1136 + h_crunch_ext; scale_num_v_r=16'd1136; end
            6'd62: begin h_active_r=9'd203; v_active_r=9'd232; scale_num_h_r=16'd1128 + h_crunch_ext; scale_num_v_r=16'd1128; end
            6'd63: begin h_active_r=9'd203; v_active_r=9'd232; scale_num_h_r=16'd1128 + h_crunch_ext; scale_num_v_r=16'd1128; end
        endcase
        // Crunch narrows the active window itself (width-only) -- applied
        // here as a second blocking assignment in the same clocked stage
        // (sees the case statement's own just-set value in program order),
        // not a separate always block, so no new pipeline stage is added.
        h_active_r = h_active_r - {3'd0, h_crunch_active_delta};
    end

    // --- MODE: Home CRT / PAL ---------------------------------------------
    // V_TOTAL=312 -> 15,625/312 = ~50.08 Hz, essentially exact PAL vertical
    // rate, showing the FULL native image uncropped/unscaled (1:1). Was
    // the active default earlier on 2026-09-04; real hardware result on a
    // Sony Trinitron: fixed the earlier oversizing/wrapping problem (see
    // the Arcade mode below) and HDMI was confirmed unaffected, but
    // produced visible 50Hz-style flicker -- a known real phenomenon at
    // PAL's lower refresh rate on some CRT phosphors/chassis, not a logic
    // bug. Kept here for a genuine PAL-region display where 50Hz is the
    // norm and not perceived as flicker, or anyone who prefers the
    // full-size 1:1 image over either NTSC mode's smaller scaled one.
    // localparam V_TOTAL     = 312;
    // localparam VSYNC_START = 284;
    // localparam VSYNC_END   = 287;
    // localparam H_ACTIVE    = 224;
    // localparam V_ACTIVE    = 256;
    // localparam SCALE_NUM_H = 1; // renamed 2026-09-04 (scaler split H/V, see Arcade mode below)
    // localparam SCALE_DEN_H = 1;
    // localparam SCALE_NUM_V = 1;
    // localparam SCALE_DEN_V = 1;

    // --- MODE: Arcade (flexible/multisync 15kHz monitor) ------------------
    // V_TOTAL=288 -> 15,625/288 = ~54.25 Hz, full native image uncropped/
    // unscaled (1:1). Only 32 lines of vertical blanking -- tighter margin
    // than either mode above. 2026-09-04: deployed and tested on a real
    // Sony Trinitron 27" CONSUMER CRT and produced an oversized, wrapping
    // picture -- the classic symptom of a fixed-frequency consumer
    // deflection/AFC circuit failing to cleanly lock to a rate that sits
    // between the two real broadcast standards (50/59.94 Hz) it was
    // actually built and calibrated for. NOT recommended for a consumer TV
    // -- use one of the modes above for that. May still be a reasonable
    // choice for a genuine dedicated multisync/flexible-frequency 15kHz
    // ARCADE monitor chassis, which (unlike a fixed consumer set) is
    // typically designed to tolerate a wide range of vertical rates by
    // design -- untested on that kind of hardware, use with the same
    // caution as any unverified timing change to a real CRT.
    // 2026-09-04 follow-up #5 (ACTIVE): re-activated at the user's explicit
    // request. Using the SAME size/scale (168x192 via 171/128, ~3/4) and
    // the SAME H_CENTER_TRIM/V_CENTER_TRIM as the just-confirmed 264 mode,
    // instead of this mode's original 1:1/224x256 numbers -- the point of
    // this test is isolating whether V_TOTAL=288 itself still causes the
    // earlier oversizing/wrapping symptom, not re-testing a different size
    // at the same time. VSYNC_START/END (272/275) are unchanged from the
    // original 1:1 version of this mode -- they're a property of this
    // V_TOTAL's own vertical blanking layout, not of the active window
    // size, and 272 still leaves 40 lines of margin after the new smaller
    // V_ACT_END (see V_ACT_START/V_ACT_END below), so no collision risk.
    //
    // 2026-09-04 follow-up #6: user confirmed the WIDTH (168, via 171/128)
    // is now correct and asked to grow the HEIGHT alone by ~4-5 inches on
    // the real 21.6x16.2in (27in-class, 4:3) Sony Trinitron screen this
    // was measured on -- explicitly confirmed as an intentional aspect-
    // ratio distortion (height stretched independent of width), overriding
    // this feature's original no-distortion design goal at the user's
    // direct request. This is why SCALE_NUM/SCALE_DEN are split into
    // separate _H (width/column axis, unchanged) and _V (height/row axis,
    // now upscaling instead of downscaling) pairs below -- previously a
    // single shared ratio enforced identical scaling on both axes, which
    // is exactly what made preserving the true aspect ratio automatic; a
    // deliberate distortion needs two independent ratios instead, so this
    // is a real, structural change to the scaler (see its own comments
    // further down), not just a new pair of numbers.
    //
    // Conversion: V_TOTAL sweeps the full 16.2in screen height edge-to-edge
    // (same convention as H_TOTAL/full screen width), so 16.2in/288 lines =
    // 0.05625 in/line. Current V_ACTIVE=192 -> ~10.8in. The full requested
    // 4-5in growth (V_ACTIVE~263-281) was rejected: VSYNC_START=272 means
    // V_ACTIVE=272 lands the active window's bottom edge exactly ON the
    // sync pulse (zero margin) and 281 would run past it, corrupting the
    // picture outright, not just mis-sizing it -- V_TOTAL=288 only has 32
    // lines of blanking total to begin with. User chose to cap growth at
    // ~4in instead, keeping real margin.
    //
    // 2026-09-04 follow-up #7: the first attempt at the height stretch
    // (V_ACTIVE=260, keeping the existing symmetric V_CENTER_TRIM=-8) grew
    // BOTH edges outward equally from center -- but real-hardware feedback
    // showed that's wrong for this CRT: the new TOP position (V_ACT_START=6)
    // was correct, while the new BOTTOM position (V_ACT_END=266) ran past
    // the tube's real visible edge and got cut off. This CRT's usable area
    // isn't symmetric around this sweep's center, so a symmetric grow can't
    // work here -- the two edges need to move independently. Fix: keep the
    // now-confirmed-correct top (V_ACT_START=6) fixed, and pull the bottom
    // back to the LAST confirmed-correct bottom position, V_ACT_END=232
    // (from the pre-stretch V_ACTIVE=192 build: V_ACT_START was 40 there,
    // V_ACT_END=40+192=232). New height = 232-6 = 226 lines -- a real net
    // growth of 34 lines (~1.9in) over the original 192, achieved entirely
    // by extending upward from the old top, not by growing symmetrically.
    // Solved for V_CENTER_TRIM algebraically rather than trial-and-error:
    // V_ACT_START = (V_TOTAL-V_ACTIVE)/2 + V_CENTER_TRIM must equal 6 with
    // V_ACTIVE=226, so V_CENTER_TRIM = 6 - (288-226)/2 = 6-31 = -25.
    // Ratio: 226/256 native, using SCALE_DEN_V=128 (power of two, shift=8)
    // and SCALE_NUM_V=round(128*256/226)=145 -> V_ACTIVE=round(256*128/145)
    // =225.99, rounds to 226 exactly, 0.006% off the exact 226/256 target
    // (better precision than any earlier ratio in this file).
    // localparam V_TOTAL     = 288;
    // localparam VSYNC_START = 272;
    // localparam VSYNC_END   = 275;
    // 2026-09-04 follow-up #8: user confirmed the height (226, above) is
    // now correct and asked for a slight width-only squish to get back
    // toward a 4:3-shaped picture, explicitly without touching height in
    // any way -- V_ACTIVE/SCALE_NUM_V/SCALE_DEN_V above are untouched.
    // This is a modest first-pass nudge (~2.4% narrower, 168->164), not a
    // precise measurement -- same eyeball-then-iterate approach as the
    // earlier position trims, since a "slight" cosmetic width change
    // carries none of the hard failure risk the height/sync-margin work
    // did. H_CENTER_TRIM is untouched, so the window narrows symmetrically
    // around the same already-confirmed-correct horizontal center.
    // SCALE_DEN_H stays 128 (same free power-of-two shift); only
    // SCALE_NUM_H moved (171->176) to pull H_ACTIVE in slightly.
    //
    // 2026-09-05 follow-up #9 (DEACTIVATED): after all the geometry work
    // above, real-hardware use surfaced the actual root problem this
    // mode's own original 2026-09-04 warning predicted: intermittent
    // vertical sync LOCK failure, not just a fixed size/position error --
    // the picture would sometimes show the top of the frame wrapped into
    // the middle of the screen, and cycling the Direct Video
    // orientation mode (rotated/unrotated, toggled twice) would
    // sometimes but not always recover it. This is a genuine analog
    // deflection/AFC lock marginality on this fixed-frequency consumer
    // CRT, not a logic bug -- no amount of further position/size tuning
    // fixes an intermittent lock failure. Deactivated (commented out)
    // rather than deleted: this mode's math and geometry work are real
    // and may be exactly right for a genuine dedicated arcade monitor or
    // MiSTercade-driven CRT (multisync/flexible-frequency hardware that,
    // unlike a fixed consumer set, is designed to tolerate a wider range
    // of vertical rates) -- kept available for that use case, just not
    // the default for a consumer television. V_TOTAL=264 below (this
    // file's only mode with a stable, non-intermittent real-hardware
    // result) is the active default again.
    // localparam H_ACTIVE    = 164; // round(224 * 128/176)
    // localparam V_ACTIVE    = 226; // round(256 * 128/145); keeps top fixed, restores old bottom
    // localparam SCALE_NUM_H  = 176;
    // localparam SCALE_DEN_H  = 128;
    // localparam SCALE_NUM_V  = 145;
    // localparam SCALE_DEN_V  = 128;

    // Real-hardware horizontal centering correction, 2026-09-04: measured
    // directly from photos of the user's Sony Trinitron via corner-by-corner
    // pixel measurement (OpenCV), cross-validated across two independent
    // photos. CRT visible screen boundary measured at ~1085x815 px (photo
    // coordinates), center ~(983,768); the active window's own measured
    // center was ~(1175,810) -- a rightward shift of ~192px, or ~17.7% of
    // the screen's own width. Mapped onto this module's H_TOTAL=384 scan
    // (which sweeps the full physical screen width edge-to-edge regardless
    // of how much of it is active), that's ~68 of 384 positions. This trim
    // is independent of which mode/H_ACTIVE is selected above (it corrects
    // this specific CRT's own horizontal centering, not any one mode's
    // window size), so it's applied uniformly to the auto-centered formula
    // rather than baked into one mode's numbers.
    // 2026-09-04 follow-up #2: user's direct real-hardware eyeball feedback
    // says the picture needs to move right and up slightly from where the
    // V_TOTAL=264 revert (no vertical trim yet, same -68 horizontal trim as
    // the old 261 mode) put it. This is a qualitative nudge, not a new photo
    // measurement -- unlike H_CENTER_TRIM's original -68 (derived from actual
    // corner-to-corner pixel measurement), these two adjustments are an
    // interim eyeball-based estimate: +12 positions of H_TOTAL=384 (~3%) to
    // shift right (a SMALLER H_ACT_START starts the active window earlier in
    // the horizontal scan, i.e. further left, so moving right means making
    // H_CENTER_TRIM less negative), and a new V_CENTER_TRIM of -8 positions
    // of V_TOTAL=264 (~3%) to shift up (a SMALLER V_ACT_START starts the
    // active window earlier in the vertical scan, i.e. further up). If this
    // overshoots or undershoots, get fresh photos and re-measure precisely
    // the same way H_CENTER_TRIM originally was, rather than iterating by
    // eye again.
    localparam H_CENTER_TRIM = -56; // was -68; +12 to shift right
    // 2026-09-04 follow-up #7 (superseded 2026-09-05): V_CENTER_TRIM was
    // changed to -25 while V_TOTAL=288 was active, algebraically solved to
    // keep that mode's own V_ACT_START=6 fixed while V_ACTIVE dropped from
    // 260 to 226 (see the Arcade mode's own comment for that derivation --
    // it no longer applies now that 288 is deactivated). Reverted back to
    // -8, the value actually confirmed-good for THIS mode's own baseline
    // (V_TOTAL=264, 168x192) before the 288 detour -- this trim is
    // specific to whichever V_TOTAL/V_ACTIVE combo is active and doesn't
    // carry over between modes on this CRT.
    // 2026-09-05 follow-up: changed from -8 to -14 as part of the measured
    // margin-equalization + fill-in fix -- see the mode block above for
    // the full photo-measurement derivation. Solved algebraically to land
    // V_ACT_START exactly at 0 with the new V_ACTIVE=236.
    // 2026-09-05 follow-up #2: changed from -14 to -16, solved to keep
    // V_ACT_START pinned at 2 (unchanged -- top confirmed correct) while
    // V_ACTIVE dropped further to 228 for the bottom-only trim -- see the
    // mode block above.
    // Task #92: H_CENTER_TRIM/V_CENTER_TRIM are now BASE values with a
    // runtime OSD offset (osd_h_trim/osd_v_trim) added on top -- field 0
    // reproduces this exact baseline unchanged. H_ACT_START/END
    // and V_ACT_START/END are no longer localparams (H_ACTIVE/V_ACTIVE
    // are runtime values now, from the zoom table above) -- they're wires
    // with a DEFENSIVE CLAMP: since a user can now pick any of the 32x32x32
    // possible field combinations at runtime (not just values I've
    // personally checked one at a time like every earlier change in this
    // file), the clamp guarantees the active window can never overlap
    // either sync pulse, regardless of what's selected. Exhaustively
    // verified in Python before writing this (all 32,768 combinations,
    // zero violations, worst-case margins 82 lines before hsync@320 and
    // 11 lines before this mode's own VSYNC_START) -- see project history
    // for the verification script. The clamp pulls the WINDOW POSITION
    // back rather than shrinking its size when a combination would
    // otherwise overflow, so the requested zoom is always honored exactly;
    // only position can be silently limited at the extremes.
    // 2026-10-02: -56 -> -41. User reported needing CRT H Position maxed
    // at +15 to visually center the image on their real CRT -- at the old
    // baseline that only reaches an effective -41 (-56+15), meaning +15 was
    // already the user's own confirmed-correct centering point, just
    // buried at the far end of the OSD range instead of at Default. Moving
    // the baseline there instead makes Default the correctly-centered
    // point and gives the OSD's own +/-15 range back for real fine-
    // adjustment, rather than having most of it permanently consumed just
    // reaching center.
    localparam signed [7:0] H_CENTER_TRIM_BASE = -8'sd41;
    localparam signed [7:0] V_CENTER_TRIM_BASE = -8'sd16;
    localparam signed [9:0] H_SAFE_MAX_END = 10'sd300; // margin before hsync pulse @320
    // V_SAFE_MAX_END is now a wire (was a localparam) since VSYNC_START_r
    // is a runtime register, not a compile-time constant -- it still feeds
    // the same already-registered H_ACT_START/END/V_ACT_START/END pipeline
    // below, so this costs no additional combinational depth on the
    // pixel-critical path, same reasoning as h_active_r/V_TOTAL_r above.
    wire signed [9:0] V_SAFE_MAX_END = $signed({1'b0, VSYNC_START_r[8:0]}) - 10'sd4; // margin before this mode's vsync pulse
    wire signed [5:0] h_pos_offset = (osd_h_trim == 5'd0) ? 6'sd0 : ($signed({1'b0, osd_h_trim}) - 6'sd16);
    wire signed [5:0] v_pos_offset = (osd_v_trim == 5'd0) ? 6'sd0 : ($signed({1'b0, osd_v_trim}) - 6'sd16);
    wire signed [7:0] h_center_trim_s = H_CENTER_TRIM_BASE + h_pos_offset;
    wire signed [7:0] v_center_trim_s = V_CENTER_TRIM_BASE + v_pos_offset;

    wire [8:0] h_diff = H_TOTAL[8:0] - h_active_r;
    wire signed [9:0] h_act_start_raw = $signed({2'b0, h_diff}) / 10'sd2 + {{2{h_center_trim_s[7]}}, h_center_trim_s};
    wire signed [9:0] h_act_end_raw   = h_act_start_raw + $signed({1'b0, h_active_r});
    wire signed [9:0] h_act_start_c1  = (h_act_end_raw > H_SAFE_MAX_END) ? (H_SAFE_MAX_END - $signed({1'b0, h_active_r})) : h_act_start_raw;
    wire signed [9:0] h_act_start_c2  = (h_act_start_c1 < 10'sd0) ? 10'sd0 : h_act_start_c1;

    wire [8:0] v_diff = V_TOTAL_r[8:0] - v_active_r;
    wire signed [9:0] v_act_start_raw = $signed({2'b0, v_diff}) / 10'sd2 + {{2{v_center_trim_s[7]}}, v_center_trim_s};
    wire signed [9:0] v_act_end_raw   = v_act_start_raw + $signed({1'b0, v_active_r});
    wire signed [9:0] v_act_start_c1  = (v_act_end_raw > V_SAFE_MAX_END) ? (V_SAFE_MAX_END - $signed({1'b0, v_active_r})) : v_act_start_raw;
    wire signed [9:0] v_act_start_c2  = (v_act_start_c1 < 10'sd0) ? 10'sd0 : v_act_start_c1;

    // Registered (same reasoning as h_active_r/v_active_r above): H_ACT_START/
    // END and V_ACT_START/END are the values out_active_now/out_col_idx/
    // out_row_idx actually consume every pixel, so THESE specifically must
    // never be a multi-step combinational chain in that path -- this is the
    // exact class of change this file's own history says already broke
    // 48MHz timing closure once (see the note above the zoom lookup table).
    // One more cycle of latency between an OSD change and it taking visual
    // effect is completely imperceptible; kept the original names (now reg
    // instead of wire) so nothing downstream needed to change.
    reg [8:0] H_ACT_START, H_ACT_END, V_ACT_START, V_ACT_END;
    always @(posedge out_clk) begin
        H_ACT_START <= h_act_start_c2[8:0];
        H_ACT_END   <= h_act_start_c2[8:0] + h_active_r;
        V_ACT_START <= v_act_start_c2[8:0];
        V_ACT_END   <= v_act_start_c2[8:0] + v_active_r;
    end

    reg [8:0] out_h_cnt = 0; // 0-383
    reg [8:0] out_v_cnt = 0; // 0-(V_TOTAL-1)

    // 2026-09-18: moved to out_clk, its own independent, genlocked clock --
    // out_clk already runs at exactly the target output pixel rate, so
    // unlike the old shared-clk_sys version, no ce_pix-style divider enable
    // is needed here; every out_clk edge is a real output pixel.
    always @(posedge out_clk) begin
        if (out_rst) begin
            out_h_cnt <= 0;
            out_v_cnt <= 0;
        end else begin
            if (out_h_cnt == H_TOTAL - 1) begin
                out_h_cnt <= 0;
                out_v_cnt <= (out_v_cnt == V_TOTAL_r - 1) ? 9'd0 : out_v_cnt + 9'd1;
            end else begin
                out_h_cnt <= out_h_cnt + 9'd1;
            end
        end
    end

    wire out_hsync_now  = (out_h_cnt >= 320 && out_h_cnt < 352);
    // vsync pulse: 3 lines, placed roughly mid-blanking regardless of which
    // mode above is active -- VSYNC_START/END come from the selected mode's
    // constants, not hardcoded here.
    wire out_vsync_now  = (out_v_cnt >= VSYNC_START_r && out_v_cnt < VSYNC_END_r);
    // Fixed 2026-09-04: this used to compare against a bare V_ACTIVE (i.e.
    // implicitly V_ACT_START=0), which no longer matches modes whose active
    // window is centered within V_TOTAL -- now uses the real V_ACT_START/
    // V_ACT_END bounds for whichever mode is selected above.
    wire out_active_now = (out_h_cnt >= H_ACT_START && out_h_cnt < H_ACT_END) &&
                           (out_v_cnt >= V_ACT_START && out_v_cnt < V_ACT_END);

    // Active-window-relative indices (0..H_ACTIVE-1 / 0..V_ACTIVE-1) while
    // out_active_now is true. 2026-09-05 correction: this used to claim
    // they're "harmless/unused" outside the active window -- disproven by
    // simulation (Verilator run, see project history). They keep growing
    // through blanking (and can underflow before H_ACT_START/V_ACT_START),
    // which the downstream scaler pipeline is NOT gated against -- see the
    // clamp fix on scaled_row_r/scaled_col_r further down, which is what
    // actually makes this safe now.
    wire [8:0] out_col_idx = out_h_cnt - H_ACT_START[8:0];
    wire [8:0] out_row_idx = out_v_cnt - V_ACT_START[8:0];

    // Pipeline latency, 2026-09-04 follow-up: the read path below now takes
    // 3 cycles from out_h_cnt/out_v_cnt to raw_dout_bufX_Y being valid (was
    // 1 cycle) -- the nn_scale scaler's multiply-then-divide was a genuine
    // FPGA timing-closure risk left combinational in a single cycle (two
    // real TimeQuest setup violations traced to exactly this path: -2.454ns
    // and -1.283ns on separate compiles), so it's now split across two
    // registered pipeline stages of its own (see nn_scale's replacement
    // below), pushing total BRAM read latency from 1 to 3 cycles. hsync/
    // vsync/active must delay by the same 3 cycles to land on the same
    // edge as the pixel data they describe -- same discipline this core
    // already uses elsewhere for pixel-pipeline latency (see
    // active_area_sr's shift-register delay), just a longer chain now.
    // 2026-09-05 follow-up: extended from 3 to 4 stages to match the
    // scaler's clamp now being its own pipeline stage (see below) -- total
    // BRAM read latency is 4 cycles from out_h_cnt/out_v_cnt to
    // raw_dout_bufX_Y, was 3.
    reg out_hsync_d1, out_vsync_d1, out_active_d1;
    reg out_hsync_d2, out_vsync_d2, out_active_d2;
    reg out_hsync_d3, out_vsync_d3, out_active_d3;
    reg out_hsync_d4, out_vsync_d4, out_active_d4;
    always @(posedge out_clk) begin
        out_hsync_d1  <= out_hsync_now;
        out_vsync_d1  <= out_vsync_now;
        out_active_d1 <= out_active_now;
        out_hsync_d2  <= out_hsync_d1;
        out_vsync_d2  <= out_vsync_d1;
        out_active_d2 <= out_active_d1;
        out_hsync_d3  <= out_hsync_d2;
        out_vsync_d3  <= out_vsync_d2;
        out_active_d3 <= out_active_d2;
        out_hsync_d4  <= out_hsync_d3;
        out_vsync_d4  <= out_vsync_d3;
        out_active_d4 <= out_active_d3;
    end
    assign out_hsync  = out_hsync_d4;
    assign out_vsync  = out_vsync_d4;
    assign out_active = out_active_d4;

    // ------------------------------------------------------------------
    // Nearest-neighbor scaler: maps an active-window-relative output index
    // k (0..COUNT-1) onto the full native 0..(NATIVE_COUNT-1) range using
    // the mode's SCALE_NUM:SCALE_DEN ratio (native:output, e.g. 8:7),
    // sampling at the CENTER of each output cell -- the standard image-
    // scaling formula: scaled = floor((k + 0.5) * NUM / DEN), done here in
    // integer arithmetic as floor((2k+1)*NUM / (2*DEN)). Center-sampling
    // matters, not just style: a naive floor(k*NUM/DEN) formula falls
    // short of the top end whenever NUM/DEN doesn't divide evenly -- for
    // the 8:7 ratio it would leave native row 255 completely unreachable
    // (max k=223 gives floor(223*8/7)=254, never 255). The center-sampling
    // form reaches both ends exactly (k=0 -> 0, k=223 -> 255 for 8:7;
    // k=0 -> 0, k=191 -> 255 for 4:3) and reduces to the exact identity
    // (scaled=k) when SCALE_NUM=SCALE_DEN=1, so the 1:1 modes (PAL,
    // Arcade) get zero behavioral change from a direct passthrough. Also
    // works unmodified for an UPSCALING ratio (NUM/DEN < 1, i.e. DEN>NUM,
    // e.g. the height axis below) -- it just repeats some native samples
    // across multiple output positions instead of dropping any.
    //
    // 2026-09-04 follow-up #6: split into independent row (_V, height) and
    // col (_H, width) ratios/shifts -- the row axis is now an intentional
    // aspect-ratio-distorting upscale at the user's explicit request (see
    // the Arcade mode's own comment above), while the col axis stays
    // exactly as before. Previously both axes shared one SCALE_NUM/DEN and
    // one DIV_SHIFT, which is what guaranteed no distortion; that
    // guarantee no longer holds by design, so don't assume it elsewhere in
    // this file.
    // ------------------------------------------------------------------
    // Pipelined across two registered stages, 2026-09-04: doing the
    // multiply and the divide combinationally in a single cycle (the
    // original design) caused two separate real Quartus TimeQuest setup
    // violations on this exact path (-2.454ns, then -1.283ns after an
    // unrelated change elsewhere shifted placement) -- a multiply followed
    // by an integer divide is genuinely deep FPGA logic (long carry
    // chains), not something to leave combinational and hope fits. Stage 1
    // registers the multiply's product (row/col in parallel); stage 2
    // registers the divide's quotient (the final scaled index). This adds
    // 2 cycles of latency to the read path (BRAM read is now 3 cycles
    // total from out_h_cnt/out_v_cnt to raw_dout_bufX_Y, was 1) -- every
    // consumer of that timing (hsync/vsync/active above, read_sel below)
    // has been extended to match.
    //
    // 2026-09-04 follow-up #3: even 2-stage-pipelined, a genuine runtime
    // integer divide (Quartus infers a generic "auto_generated divider"
    // megafunction whenever SCALE_DEN isn't a power of two) is expensive
    // enough on this device that changing SCALE_DEN from 7 to 5 alone
    // reopened a real TimeQuest violation on this exact
    // row_numer_r->scaled_row_r path (-2.315ns this time) -- the divisor's
    // bit pattern, not just the pipeline depth, drives the logic depth of
    // this style of divider. Root-caused properly instead of re-chasing
    // pipeline depth again: constrained SCALE_DEN to always be a power of
    // two, so "divide by SCALE_DEN*2" is a compile-time-constant right
    // shift -- literally free wiring, not a synthesized divider circuit,
    // with zero timing risk regardless of what SCALE_NUM/SCALE_DEN end up
    // being for any future mode. This also fixes a latent truncation bug
    // the old code had: it zero-extended only SCALE_NUM[3:0]/SCALE_DEN[3:0]
    // (4 bits, max value 15), which would have silently corrupted any
    // ratio using a numerator/denominator above 15 (e.g. the 45 used
    // below) -- now the full localparam value is used untruncated.
    localparam DIV_SHIFT_V = $clog2(SCALE_DEN_V * 2); // SCALE_DEN_V*2 MUST be a power of 2
    localparam DIV_SHIFT_H = $clog2(SCALE_DEN_H * 2); // SCALE_DEN_H*2 MUST be a power of 2
    // 2026-10-01: restored the "*2+1" center-sampling numerator (commit
    // 7cfe61a) to match the restored zoom table's own calibration -- it
    // was built for round((2*idx+1)*step/512), not the left-edge
    // round(idx*step/256) form the interim CRT-Sizing/Rack-'Em-Up-ported
    // LUT used. Mixing the old table's step values with the new formula
    // would silently mis-scale the image (right magnitude, wrong rounding
    // convention) despite compiling cleanly -- the table and this formula
    // were validated together and must travel together.
    // 2026-10-02: widened 16->20 bits. The reverted Stretch attempt
    // (commit aa9f090) doubled SCALE_DEN_H/V for finer steps and doubled
    // every table numerator to match, but left this register at 16 bits --
    // the un-stretched design was ALREADY right at the 16-bit ceiling by
    // design (worst case ~65283 of 65536, confirmed by inspection), so
    // doubling the numerator pushed the real worst case to ~131,000+,
    // silently wrapping a 16-bit reg before the downstream clamp ever saw
    // an out-of-range value -- this is the actual, demonstrated root cause
    // of that regression's 4-way-mirror symptom, not a pipeline-timing
    // issue (an earlier theory considered and now superseded). This
    // redesign uses SCALE_DEN=1024 (8x, for finer Stretch granularity than
    // even that attempt had) and folds Stretch into THIS SAME registered
    // stage (see scale_num_h_r/v_r's case statement below) rather than a
    // separate one, so no new pipeline depth is introduced either. 20 bits
    // holds the real worst case (552,739, exhaustively checked across all
    // 64 zoom-table entries x the full +/-63 stretch range) with ~47%
    // headroom to spare -- not another razor-thin fit.
    reg [19:0] row_numer_r, col_numer_r;
    always @(posedge out_clk) begin
        row_numer_r <= (({7'd0, out_row_idx} * 20'd2) + 20'd1) * scale_num_v_r;
        col_numer_r <= (({7'd0, out_col_idx} * 20'd2) + 20'd1) * scale_num_h_r;
    end

    // 2026-09-05 fix: a real bug, confirmed via Verilator simulation (not
    // just arithmetic) -- out_col_idx/out_row_idx (above) are combinational
    // off the raw out_h_cnt/out_v_cnt counters and were never actually
    // restricted to the active window despite this section's own now-
    // disproven comment claiming they're "harmless/unused" outside it: the
    // scaler pipeline is NOT gated by out_active_now, so it keeps computing
    // through blanking using an out_col_idx that grows past H_ACTIVE-1 (and
    // out_row_idx past V_ACTIVE-1), producing scaled_col_r/scaled_row_r
    // values beyond their intended 0-223 / 0-255 ranges. Because
    // native_v = 8'd223 - scaled_col_r is a subtraction, an out-of-range
    // scaled_col_r UNDERFLOWS (wraps to near-255 in unsigned arithmetic)
    // rather than failing safely, producing a wildly out-of-bounds BRAM
    // read address. Simulation confirmed this reaches real displayed
    // pixels (11,220 out-of-bounds reads in a 20M-cycle run, gated on the
    // active signal), matching a real-hardware report of a triangular
    // garbage artifact on the attract screen. Fixed by clamping both
    // scaled values to their valid native ranges right after the shift --
    // this is the mathematically correct behavior for a nearest-neighbor
    // scaler anyway (an index that would round past the native edge should
    // saturate to the edge pixel, not wrap), not a workaround, and it makes
    // this permanently safe regardless of future SCALE_NUM/DEN retuning.
    // 2026-09-05 follow-up: the clamp above, added combinationally in the
    // same cycle as the shift, cut this compile's worst-case setup slack
    // to +0.017ns -- technically still passing, but on the SAME path
    // this file has already hit two real timing violations on (see the
    // history above), and that thin a margin isn't a safe place to leave
    // a real-hardware core. Split the clamp into its OWN registered stage
    // instead of stacking it onto the shift's cycle -- this is the exact
    // same fix philosophy already used twice above for this scaler
    // (pipeline deeper rather than accept marginal combinational depth),
    // and it costs only 1 more cycle of latency (3->4 total to
    // raw_dout_bufX_Y), which the hsync/vsync/active and read_sel delay
    // chains below are extended to match. Correctness (the clamp itself)
    // is unchanged from the Verilator-verified version -- only its timing
    // is restructured.
    // 2026-10-02: widened 9->10 bits alongside row_numer_r/col_numer_r above
    // -- worst case post-shift is 269 (row) / 236 (col), exhaustively
    // checked across every zoom-table entry x the full Stretch range, so a
    // 10-bit register (0-1023) has wide margin below its own ceiling. This
    // means the value reaching the clamp below is always the TRUE computed
    // value, never one that silently wrapped first.
    reg [9:0] scaled_row_raw_r, scaled_col_raw_r;
    always @(posedge out_clk) begin
        scaled_row_raw_r <= row_numer_r >> DIV_SHIFT_V; // 0-255, or beyond during blanking
        scaled_col_raw_r <= col_numer_r >> DIV_SHIFT_H; // 0-223, or beyond during blanking
    end

    reg [8:0] scaled_row_r, scaled_col_r;
    always @(posedge out_clk) begin
        scaled_row_r <= (scaled_row_raw_r > 9'd255) ? 9'd255 : scaled_row_raw_r; // 0-255
        scaled_col_r <= (scaled_col_raw_r > 9'd223) ? 9'd223 : scaled_col_raw_r; // 0-223
    end

    // ------------------------------------------------------------------
    // Confirmed-correct 90-degree rotation address (candidate 0 from
    // rtl/direct_video_portrait_buffer.v, verified against sys/arcade_video.v
    // screen_rotate's rotate_ccw=0 ground truth with exact-match evidence):
    //   native_column = scaled_row (0-255), native_row = 223 - scaled_col (0-223)
    // Same formula as the original 1:1 design; only the source indices
    // changed (the pipelined scaled_row_r/scaled_col_r above, instead of
    // the raw out_row/out_col) -- scaling and rotation are two separate,
    // composed stages, not one merged calculation. This part stays
    // combinational -- a subtract and a multiply-by-256/add is cheap, not
    // the thing that was ever failing timing.
    // ------------------------------------------------------------------
    // 2026-09-18: osd_flip selects the OTHER 90-degree rotation direction --
    // composing the base rotation above with a further 180-degree point
    // flip (invert both axes) yields exactly the opposite CW/CCW rotation,
    // without needing a separate direction control. Base: native_h=
    // scaled_row_r, native_v=223-scaled_col_r. Flipped: invert each term
    // that was inverted before (native_h picks up the 255-x inversion it
    // didn't have; native_v drops the 223-x inversion it did have).
    wire [7:0] native_h = osd_flip ? (8'd255 - scaled_row_r[7:0]) : scaled_row_r[7:0];
    wire [7:0] native_v = osd_flip ? scaled_col_r[7:0] : (8'd223 - scaled_col_r[7:0]);

    wire [16:0] wr_addr = {9'd0, wr_row} * 256 + {9'd0, wr_col};
    wire [16:0] rd_addr = {9'd0, native_v} * 256 + {9'd0, native_h};

    // ------------------------------------------------------------------
    // Double-buffered 12bpp (4 bits/channel) storage. write_sel selects
    // which physical buffer is currently being captured into; the other is
    // always the one being displayed. Truncation (top 4 bits of each 8-bit
    // channel) on write, nibble-replication expansion back to 8 bits on
    // read -- a plain, well-understood precision reduction, not a palette
    // lookup, so it carries none of the stale-color-during-a-fade risk a
    // palette-index buffer would have.
    // ------------------------------------------------------------------
    reg write_sel = 0; // 0: buf0 is being written (buf1 is stable/displayed)

    (* ramstyle = "M10K" *) reg [3:0] buf0_r [0:(256*224)-1];
    (* ramstyle = "M10K" *) reg [3:0] buf0_g [0:(256*224)-1];
    (* ramstyle = "M10K" *) reg [3:0] buf0_b [0:(256*224)-1];
    (* ramstyle = "M10K" *) reg [3:0] buf1_r [0:(256*224)-1];
    (* ramstyle = "M10K" *) reg [3:0] buf1_g [0:(256*224)-1];
    (* ramstyle = "M10K" *) reg [3:0] buf1_b [0:(256*224)-1];

    wire wr_buf0 = wr_en && (write_sel == 1'b0);
    wire wr_buf1 = wr_en && (write_sel == 1'b1);

    reg [3:0] raw_dout_buf0_r, raw_dout_buf0_g, raw_dout_buf0_b;
    reg [3:0] raw_dout_buf1_r, raw_dout_buf1_g, raw_dout_buf1_b;

    // 2026-09-18: read and write ports split into separate always blocks on
    // separate clocks (clk for write, the new independent out_clk for
    // read) -- Cyclone V M10K blocks natively support true dual-clock
    // simple-dual-port operation, and Quartus infers exactly that from
    // this pattern (one always block per clock driving the same array).
    // Each buffer's read address is still a pure slice (rd_addr), touched
    // by nothing conditional -- read completely unconditionally every
    // out_clk cycle, exactly like k007342.v's tile_cache_way0/way1.
    always @(posedge clk) if (wr_buf0) buf0_r[wr_addr] <= wr_r[7:4];
    always @(posedge clk) if (wr_buf0) buf0_g[wr_addr] <= wr_g[7:4];
    always @(posedge clk) if (wr_buf0) buf0_b[wr_addr] <= wr_b[7:4];
    always @(posedge clk) if (wr_buf1) buf1_r[wr_addr] <= wr_r[7:4];
    always @(posedge clk) if (wr_buf1) buf1_g[wr_addr] <= wr_g[7:4];
    always @(posedge clk) if (wr_buf1) buf1_b[wr_addr] <= wr_b[7:4];

    always @(posedge out_clk) raw_dout_buf0_r <= buf0_r[rd_addr];
    always @(posedge out_clk) raw_dout_buf0_g <= buf0_g[rd_addr];
    always @(posedge out_clk) raw_dout_buf0_b <= buf0_b[rd_addr];
    always @(posedge out_clk) raw_dout_buf1_r <= buf1_r[rd_addr];
    always @(posedge out_clk) raw_dout_buf1_g <= buf1_g[rd_addr];
    always @(posedge out_clk) raw_dout_buf1_b <= buf1_b[rd_addr];

    // 2026-09-18, corrected same day: write_sel toggles unconditionally at
    // every completed native frame. An earlier version of this section
    // gated the toggle behind a same-looking "is the target buffer still
    // locked for display" check (comparing against read_sel synchronized
    // back into this domain) -- proven wrong by a dedicated dual-clock
    // simulation re-run of the original tearing test (sim_main_tear2.cpp):
    // it made write_sel get permanently stuck after the first frame,
    // because read_sel is *defined* as a function of write_sel_sync (see
    // below), so within a couple of sync cycles the gate was always
    // comparing write_sel's prospective target against a value that had,
    // by construction, already become equal to it -- a self-referencing
    // condition that can never open once the pipeline settles, not a rare
    // edge case. See project_history/TASKS.md's 2026-09-18 genlock-attempt
    // entry for the full trace that found this.
    //
    // Un-gating trades that permanent lockup for a narrower, purely
    // theoretical residual risk: with out_clk genlocked to native at
    // V_TOTAL_r=264, the two clocks are frequency-matched but (in real
    // silicon, not this exact-ratio simulation) not phase-locked, so a
    // specific unlucky relative phase between a write toggle and a read
    // sample could in principle let the writer begin a new frame into the
    // buffer a read cycle is still mid-scan of. A real fix for that would
    // need a genuine cross-domain rendezvous (edge-counted handshake) or a
    // third buffer, not a level comparison -- deliberately deferred as a
    // known, narrow, not-yet-observed residual risk rather than adding
    // that complexity now.
    always @(posedge clk) begin
        if (rst) begin
            write_sel <= 1'b0;
        end else if (wr_frame_end) begin
            write_sel <= ~write_sel;
        end
    end

    // 2026-09-18: write_sel synchronized INTO the out_clk domain -- a
    // standard 2-flop synchronizer, needed because write_sel and the
    // read_sel latch below are genuinely different clock domains
    // (previously both were clk, so a single same-domain delay register
    // sufficed; a real CDC needs two stages, not one).
    reg write_sel_sync_d1, write_sel_sync;
    always @(posedge out_clk) begin
        write_sel_sync_d1 <= write_sel;
        write_sel_sync    <= write_sel_sync_d1;
    end

    // Which buffer the READ side uses must stay fixed for an entire OUTPUT
    // frame (264+ lines), not follow write_sel directly -- write_sel
    // toggles on the shorter NATIVE frame boundary (262 lines), so a read
    // that tracked it continuously would switch buffers mid-output-frame,
    // defeating the whole reason double-buffering was chosen over a single
    // buffer (this exact bug was caught by simulation: a naive continuous
    // write_sel-tracking mux showed the buffer selection changing thousands
    // of times within a single output frame). Latch read_sel ONCE, only at
    // the output generator's own frame boundary, from whichever buffer is
    // NOT being written at that instant (per the synchronized write_sel_sync)
    // -- it then stays stable for the entire next output frame regardless
    // of how many native frames complete during it.
    // 2026-09-18, corrected same day: this was `read_sel <= ~write_sel_sync`
    // -- an inverted assignment that, combined with the mux below
    // (read_sel_d4=1 selects buf0, =0 selects buf1), made the display
    // always show whichever buffer the writer is CURRENTLY filling instead
    // of the stable, just-completed one. Found via sim_main_tear2.cpp's
    // dual-clock re-run: it showed near-100% of output frames mixing two
    // adjacent native frame IDs, with a hierarchical-signal trace
    // confirming read_sel tracked write_sel's live target throughout. The
    // correct pairing needs no inversion: write_sel=0 (writing buf0) must
    // pair with read_sel=0 (mux shows buf1, the stable one) -- i.e.
    // read_sel and write_sel share the same value in the safe steady
    // state. See project_history/TASKS.md's 2026-09-18 genlock-attempt
    // entry.
    // 2026-09-18, second correction the same day: this was
    // `(out_h_cnt == H_TOTAL-1) && (out_v_cnt == V_TOTAL_r-1)` -- latching
    // read_sel on the very LAST cycle before the frame wraps, i.e. as late
    // as possible. That's the wrong side of the boundary: write_sel toggles
    // at native's OWN wrap (wr_frame_end, native v_cnt==0), which -- being
    // genlocked to the same wall-clock instant as this output wrap -- lands
    // only a few hundred out_clk cycles AFTER this latch point, not before
    // it. So read_sel was consistently grabbing write_sel_sync's value from
    // JUST BEFORE write_sel's own most recent toggle, one full toggle
    // stale, every single frame -- not a rare phase coincidence (confirmed
    // by sweeping the relative phase between clk and out_clk across a full
    // period in sim_main_tear2.cpp; it failed identically at every offset,
    // which is exactly what a structural one-toggle staleness looks like,
    // not what a genuine race would look like). A hierarchical-signal trace
    // caught it directly: write_sel==1 (writer actively filling buf1) at
    // the same instant read_sel_d4==0 (display showing buf1 too) --
    // reader and writer on the identical physical buffer. Moving the latch
    // to a few lines AFTER the wrap instead of the last line BEFORE it
    // gives write_sel's toggle time to settle first; re-verified via the
    // same test with zero mismatched frames across every tested clk/out_clk
    // phase offset. See project_history/TASKS.md's 2026-09-18 entry.
    wire out_frame_start = (out_h_cnt == H_TOTAL - 1) && (out_v_cnt == 9'd2);
    reg read_sel;
    always @(posedge out_clk) begin
        if (out_rst) read_sel <= 1'b0; // read buf1 first (matches write_sel's rst value of 0 -- see mux above)
        else if (out_frame_start) read_sel <= write_sel_sync;
    end

    // Registered to land on the same edge the raw dout registers land on
    // -- same discipline as tile_hit_way0_d1/tile_hit_way1_d1. Extended to
    // 4 stages (2026-09-05, was 3) to match the scaler pipeline's own
    // 4-cycle read latency (the clamp fix added a pipeline stage -- see
    // its own comment above) -- read_sel only changes once per output
    // frame (at out_frame_start), so an extra cycle of delay here doesn't
    // change its meaning, but it must still land on the correct edge
    // relative to raw_dout_bufX_Y, or a handful of pixels right at the
    // frame-boundary corner could briefly read from the wrong buffer.
    reg read_sel_d1, read_sel_d2, read_sel_d3, read_sel_d4;
    always @(posedge out_clk) begin
        read_sel_d1 <= read_sel;
        read_sel_d2 <= read_sel_d1;
        read_sel_d3 <= read_sel_d2;
        read_sel_d4 <= read_sel_d3;
    end

    // Read the buffer NOT currently being written (the stable, fully-
    // captured previous frame).
    reg [3:0] rd_r4, rd_g4, rd_b4;
    always @* begin
        if (read_sel_d4) begin
            rd_r4 = raw_dout_buf0_r;
            rd_g4 = raw_dout_buf0_g;
            rd_b4 = raw_dout_buf0_b;
        end else begin
            rd_r4 = raw_dout_buf1_r;
            rd_g4 = raw_dout_buf1_g;
            rd_b4 = raw_dout_buf1_b;
        end
    end

    assign out_r = {rd_r4, rd_r4};
    assign out_g = {rd_g4, rd_g4};
    assign out_b = {rd_b4, rd_b4};

endmodule
