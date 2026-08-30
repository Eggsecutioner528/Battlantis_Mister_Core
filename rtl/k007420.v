module k007420 (
    input  wire        clk,
    input  wire        reset,

    input  wire        spritebank,

    // Sprite Y-wrap (2026-08-16): real K007342 register 0x02 bit 7,
    // forwarded here (see rtl/k007342.v's sprite_wrap_y comment for the
    // full reasoning). When set, a sprite positioned such that it would
    // normally be off the visible 0-255 row range also gets tried at a
    // position one full screen height (256px) away, so it doesn't pop
    // in/out abruptly at the top/bottom scroll edge -- matching MAME's
    // k007420_mame.cpp `if (m_wrap_y) { ... sy+dy ... }` second draw call.
    // Simplification: MAME's dy sign depends on m_flipscreen, which this
    // core doesn't yet forward dynamically (see task #16) -- assumes
    // non-flipped (dy=-256) for now, correct for normal upright play.
    input  wire        wrap_y,

    // CPU Interface (512B memory space)
    input  wire [8:0]  cpu_addr,
    input  wire [7:0]  cpu_din,
    output wire [7:0]  cpu_dout,
    input  wire        cpu_we,

    // Video Output
    input  wire        ce_pix,
    input  wire [8:0]  h_cnt,
    input  wire [8:0]  v_cnt,
    
    // IOCTL ROM Download (for Sprite Graphics)
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    
    // Output Pixels
    output wire [7:0]  sprite_color,
    output wire        sprite_active,

    // SDRAM Sprite ROM Interface (Port 3)
    output reg         sprite_sdram_req,
    output wire [24:0] sprite_sdram_addr,
    input  wire [7:0]  sprite_sdram_dout,
    input  wire        sprite_sdram_ready,

    // Goes high once the top-level's local SDRAM loopback self-test has
    // finished and handed Port 3's req/addr lines over to this module (see
    // Battlantis.sv's `test_done ? sprite_sdram_req : test_p3_req` mux).
    // Before that point, Port 3's shared ready/dout lines are answering the
    // self-test's OWN dummy reads (0x11/0x22/0x33/0x44) -- not anything this
    // module asked for. Gating diagnostics on this signal makes them
    // reflect only this module's own real Port 3 traffic.
    input  wire        sprite_traffic_active,

    // Diagnostic outputs
    output wire [15:0] diag_sdram_req_count,
    output wire [15:0] diag_sdram_ready_count,
    output wire [17:0] max_sdram_addr_out,
    output wire        frame_has_nonzero_out,
    // Session-long (not per-frame-reset) high-water mark of the highest BRAM
    // address (0x0000-0xFFFF) that has ever produced a real, visible,
    // on-screen pixel (2026-08-13). Same trigger condition as last_visible
    // below (state==15, cur_pixel!=0, on-screen) so it only counts addresses
    // that genuinely mattered for something the player actually saw, not
    // every byte the cache happens to hold. Built to answer a specific
    // question before attempting any BRAM reallocation: how much of the
    // current flat 64KB window (0x0000-0x0FFFF) do the sprites that already
    // work (Player, Fly Man, Baron, Shade, Gustaff, Goblin, Spined Devil,
    // etc.) actually use? If the real high-water mark sits well below
    // 0xFFFF, that's reclaimable space for a second slot (e.g. covering
    // Ogre's wall-climb tiles or portrait addresses) without expanding the
    // cache or touching the M10K budget at all -- the same "slot"
    // restructuring technique Tests 78/79 used successfully in this
    // project's own history, just re-derived with real, current addresses
    // instead of reused stale ones from an earlier, different memory map.
    output wire [15:0] max_bram_addr_used_out,

    // Session-long last real SDRAM fetch that was NOT flagged 32x32 (see
    // small_sdram_* definition below for the full reasoning) -- built to
    // catch Ogre/Goblin's real fetch attempts without being masked by a
    // different, confirmed-not-Ogre 32x32 sprite that kept winning every
    // other diagnostic's "single winner per frame" slot.
    output wire [17:0] small_sdram_addr_out,
    output wire [6:0]  small_sdram_idx_out,
    output wire [7:0]  small_sdram_code_lsb_out,
    output wire [7:0]  small_sdram_attr_out,
    output wire [7:0]  small_sdram_flags_out,
    output wire        small_sdram_nonzero_out,

    // Raw OAM bytes (code/attr/flags) and OAM slot index for whichever
    // sprite produced the deepest real SDRAM fetch THIS FRAME (same latch
    // trigger as max_sdram_addr_out, captured at the same instant) -- lets us
    // see what data the CPU is actually feeding a specific still-invisible
    // sprite (e.g. the tally-screen portraits) instead of guessing blind.
    output wire [6:0]  max_addr_sprite_idx_out,
    output wire [7:0]  max_addr_code_lsb_out,
    output wire [7:0]  max_addr_attr_out,
    output wire [7:0]  max_addr_flags_out,

    // Last real SDRAM fetch THIS FRAME, unconditionally overwritten on every
    // completion (2026-08-12) -- unlike max_sdram_addr_out (tracks the
    // DEEPEST address reached anywhere on screen, which may belong to any
    // sprite), this tracks whichever real fetch happens LAST each frame.
    // Since the sprite engine scans sprite_idx from 63 down to 0 and lower
    // index wins draw priority, the last real fetch each frame is the
    // LOWEST-index active sprite -- the one most likely to actually be
    // visible on screen (e.g. the one drawn on top of everything else).
    // Built specifically to test a static, single-object screen (the
    // service-mode OBJ COLOR test) where max_sdram_addr's deepest-fetch
    // tracking and the actual visible sprite may not be the same thing.
    output wire [17:0] last_fetch_addr_out,
    output wire        last_fetch_nonzero_out,
    output wire [6:0]  last_fetch_sprite_idx_out,
    output wire [7:0]  last_fetch_code_lsb_out,
    output wire [7:0]  last_fetch_attr_out,
    output wire [7:0]  last_fetch_flags_out,

    // Last real VISIBLE draw THIS FRAME (2026-08-13, revised from an
    // earlier state==13-triggered "last BRAM fetch" version that came back
    // uninformative -- see the full comment at its definition below). Only
    // latches when a pixel is actually drawn on screen, not just fetched --
    // built to identify what OAM slot the service-mode OBJ COLOR test
    // sprite actually uses and whether it's BRAM- or SDRAM-routed.
    output wire [17:0] last_bram_addr_out,
    output wire [6:0]  last_bram_sprite_idx_out,
    output wire [7:0]  last_bram_code_lsb_out,
    output wire [7:0]  last_bram_attr_out,
    output wire [7:0]  last_bram_flags_out,
    output wire        last_bram_was_sdram_out,
    output wire [9:0]  last_bram_zoom_out,
    output wire        zoom_ever_nonstandard_out,

    // Zoom-wrap duplication detector (2026-08-16) -- see the dedicated
    // comment at its definition below. Tests task #19's theory 1: does
    // sprite_wrap_y ever fire (true_y_diff != true_y_diff_direct) for a
    // sprite that is actively mid-zoom (not 1:1) while a real, visible
    // pixel is being drawn? Sticky-latches the FIRST such occurrence
    // (does not clear per-frame) so a brief event can still be read back
    // after the fact. Replaces the four-corner tile-index diagnostic,
    // whose specific question (shield corner tile-index bug) is
    // superseded by the stronger shared zoom-transition theory.
    output wire        zoom_wrap_hit_out,
    output wire [6:0]  zoom_wrap_sprite_idx_out,
    output wire [9:0]  zoom_wrap_zoom_raw_out,
    output wire [9:0]  zoom_wrap_spr_y_out,
    output wire [7:0]  zoom_wrap_draw_x_out,
    output wire [8:0]  zoom_wrap_v_cnt_out,
    output wire [12:0] zoom_wrap_tile_idx_out,

    // Direct readback of sprite_rom_bram[3] (2026-08-11) -- same underlying
    // source byte as sprite_sdram_addr 0x20003 (the first entry in
    // Battlantis.sv's post-download SDRAM write-verification sweep, which
    // came back wrong). BRAM is written via a completely separate, simple
    // path (`if (ioctl_wr) sprite_rom_bram[...] <= ioctl_dout;`, no
    // arbiter, no SDRAM state machine) -- if THIS reads correctly while the
    // SDRAM copy of the exact same source byte doesn't, that isolates the
    // bug to the SDRAM write path specifically, not the source data itself.
    output reg [7:0]   bram_debug_out
);

    // Highest calc_rom_addr for which a real (post-self-test) SDRAM fetch has
    // completed THIS FRAME ONLY (reset every v_cnt wraparound). calc_rom_addr
    // is only fed into the SDRAM path (state 14) when it's >= 0x10000 (the
    // 64KB BRAM cache boundary), so any nonzero value here proves the sprite
    // engine is genuinely reaching into the upper/SDRAM-only region during
    // THIS specific screen -- and how far into the 256KB sprite ROM (max
    // 0x3FFFF) it gets. A per-session running max (no per-frame reset) was
    // tried first and was useless for isolating a specific static screen's
    // behavior: once any deep-ROM sprite (a boss, etc.) had been seen earlier
    // in the same play session, the latch stayed pinned near the top of the
    // range regardless of what the CURRENTLY-displayed screen was requesting.
    // If specific known-missing portraits (Gustaff/Gargoyle) live past
    // whatever this tops out at while their tally screen is on-screen, their
    // fetch is never being issued at all this frame (an OAM/tile-index
    // problem upstream of SDRAM), not a data-return problem.
    reg [17:0] max_sdram_addr;
    reg        last_v_cnt_0;
    reg [6:0]  max_addr_sprite_idx;
    reg [7:0]  max_addr_code_lsb;
    reg [7:0]  max_addr_attr;
    reg [7:0]  max_addr_flags;
    always @(posedge clk) begin
        last_v_cnt_0 <= (v_cnt == 9'd0);
        if (reset || !sprite_traffic_active) begin
            max_sdram_addr <= 18'd0;
            max_addr_sprite_idx <= 7'd0;
            max_addr_code_lsb <= 8'd0;
            max_addr_attr <= 8'd0;
            max_addr_flags <= 8'd0;
        end else if (v_cnt == 9'd0 && !last_v_cnt_0) begin
            max_sdram_addr <= 18'd0; // new frame: start tracking fresh
            max_addr_sprite_idx <= 7'd0;
            max_addr_code_lsb <= 8'd0;
            max_addr_attr <= 8'd0;
            max_addr_flags <= 8'd0;
        end else if (state == 14 && sprite_sdram_ready && calc_rom_addr > max_sdram_addr) begin
            max_sdram_addr <= calc_rom_addr;
            max_addr_sprite_idx <= sprite_idx;
            max_addr_code_lsb <= spr_code_lsb;
            max_addr_attr <= spr_attr;
            max_addr_flags <= spr_flags;
        end
    end
    assign max_sdram_addr_out = max_sdram_addr;
    assign max_addr_sprite_idx_out = max_addr_sprite_idx;
    assign max_addr_code_lsb_out = max_addr_code_lsb;
    assign max_addr_attr_out = max_addr_attr;
    assign max_addr_flags_out = max_addr_flags;

    // Session-long (not per-frame) last real SDRAM fetch that was NOT
    // flagged 32x32 (2026-08-13). Built because every attempt to catch Ogre
    // (and Goblin, same symptom per the user) via max_sdram_addr/last_visible
    // kept getting masked by a recurring 32x32-flagged sprite (`spr_flags ==
    // 8'h40`, addresses ~0x16000-0x1E000) that the user confirmed is NOT
    // Ogre -- Ogre and Goblin's wall-climb/running forms are small (their
    // sprite sheet frames are visually 16x16-scale, not 32x32-massive).
    // Explicitly excludes anything flagged 32x32 (checked via the real size
    // mask `spr_flags & 8'h70 == 8'h40`, matching MAME's own size switch --
    // NOT an exact-value check against 0x40, which a first attempt at this
    // used and which incorrectly let flag values like 0x41/0x42/0x44 leak
    // through, since those still have the 32x32 size nibble set in bits
    // 4-6, just with different flip/zoom-high bits) rather than requiring
    // exactly 16x16, to stay inclusive of whatever the real size code turns
    // out to be (8x8/16x8/8x16/16x16) without another guessing round. Does
    // NOT require a visible/non-transparent pixel to trigger (unlike
    // last_visible) -- Ogre has been reported fully invisible while
    // climbing, and a fetch can complete and be transparent while still
    // being the fetch we need to see. Double-buffered the same way Test 190
    // fixed last_visible's scanline race: a live accumulator that never
    // clears (session-long), snapshotted into `_stable` shadow registers
    // once per frame so the on-screen display is always a settled reading,
    // never mid-update.
    reg [17:0] small_sdram_addr, small_sdram_addr_stable;
    reg [6:0]  small_sdram_idx, small_sdram_idx_stable;
    reg [7:0]  small_sdram_code_lsb, small_sdram_code_lsb_stable;
    reg [7:0]  small_sdram_attr, small_sdram_attr_stable;
    reg [7:0]  small_sdram_flags, small_sdram_flags_stable;
    reg        small_sdram_nonzero, small_sdram_nonzero_stable;
    always @(posedge clk) begin
        if (reset) begin
            small_sdram_addr <= 18'd0;
            small_sdram_idx <= 7'd0;
            small_sdram_code_lsb <= 8'd0;
            small_sdram_attr <= 8'd0;
            small_sdram_flags <= 8'd0;
            small_sdram_nonzero <= 1'b0;
            small_sdram_addr_stable <= 18'd0;
            small_sdram_idx_stable <= 7'd0;
            small_sdram_code_lsb_stable <= 8'd0;
            small_sdram_attr_stable <= 8'd0;
            small_sdram_flags_stable <= 8'd0;
            small_sdram_nonzero_stable <= 1'b0;
        end else if (v_cnt == 9'd0 && !last_v_cnt_0) begin
            small_sdram_addr_stable <= small_sdram_addr;
            small_sdram_idx_stable <= small_sdram_idx;
            small_sdram_code_lsb_stable <= small_sdram_code_lsb;
            small_sdram_attr_stable <= small_sdram_attr;
            small_sdram_flags_stable <= small_sdram_flags;
            small_sdram_nonzero_stable <= small_sdram_nonzero;
        end else if (state == 14 && sprite_sdram_ready && (spr_flags & 8'h70) != 8'h40) begin
            small_sdram_addr <= calc_rom_addr;
            small_sdram_idx <= sprite_idx;
            small_sdram_code_lsb <= spr_code_lsb;
            small_sdram_attr <= spr_attr;
            small_sdram_flags <= spr_flags;
            small_sdram_nonzero <= (sprite_sdram_dout != 8'h00);
        end
    end
    assign small_sdram_addr_out = small_sdram_addr_stable;
    assign small_sdram_idx_out = small_sdram_idx_stable;
    assign small_sdram_code_lsb_out = small_sdram_code_lsb_stable;
    assign small_sdram_attr_out = small_sdram_attr_stable;
    assign small_sdram_flags_out = small_sdram_flags_stable;
    assign small_sdram_nonzero_out = small_sdram_nonzero_stable;

    reg [17:0] last_fetch_addr;
    reg        last_fetch_nonzero;
    reg [6:0]  last_fetch_sprite_idx;
    reg [7:0]  last_fetch_code_lsb;
    reg [7:0]  last_fetch_attr;
    reg [7:0]  last_fetch_flags;
    always @(posedge clk) begin
        if (reset || !sprite_traffic_active) begin
            last_fetch_addr <= 18'd0;
            last_fetch_nonzero <= 1'b0;
            last_fetch_sprite_idx <= 7'd0;
            last_fetch_code_lsb <= 8'd0;
            last_fetch_attr <= 8'd0;
            last_fetch_flags <= 8'd0;
        end else if (v_cnt == 9'd0 && !last_v_cnt_0) begin
            last_fetch_addr <= 18'd0;
            last_fetch_nonzero <= 1'b0;
            last_fetch_sprite_idx <= 7'd0;
            last_fetch_code_lsb <= 8'd0;
            last_fetch_attr <= 8'd0;
            last_fetch_flags <= 8'd0;
        end else if (state == 14 && sprite_sdram_ready) begin
            last_fetch_addr <= calc_rom_addr;
            last_fetch_nonzero <= (sprite_sdram_dout != 8'h00);
            last_fetch_sprite_idx <= sprite_idx;
            last_fetch_code_lsb <= spr_code_lsb;
            last_fetch_attr <= spr_attr;
            last_fetch_flags <= spr_flags;
        end
    end
    assign last_fetch_addr_out = last_fetch_addr;
    assign last_fetch_nonzero_out = last_fetch_nonzero;
    assign last_fetch_sprite_idx_out = last_fetch_sprite_idx;
    assign last_fetch_code_lsb_out = last_fetch_code_lsb;
    assign last_fetch_attr_out = last_fetch_attr;
    assign last_fetch_flags_out = last_fetch_flags;

    // Test 188 (last_bram_*, state==13-triggered) came back all-zero on the
    // service-mode COLOR TEST screen -- not a wiring bug, but the same blind
    // spot last_fetch_* already has on the SDRAM side (see its own comment
    // above): "last fetch of the frame" is dominated by whichever OAM slot
    // happens to be scanned last (sprite_idx==0), which on a mostly-idle
    // test screen is just an unused/blank entry, not the two visible test
    // sprites. Replaced (2026-08-13) with a pixel-gated version: only latch
    // when a pixel is ACTUALLY drawn on screen (`cur_pixel != 4'd0 &&
    // cur_draw_x` in visible range) -- the exact same condition state 15
    // already evaluates every cycle to drive `draw_we` for real rendering,
    // reused here rather than introducing new comparison logic (the prime
    // suspect for Test 185's corruption regression was a brand-new
    // screen-region comparator; this adds none). Idle/blank OAM slots never
    // produce a non-transparent pixel, so they can no longer win. Also
    // records whether the winning draw was BRAM- or SDRAM-routed, using
    // calc_rom_addr (still held stable from state 12) against the same
    // 0x10000 boundary state 12 itself uses to pick the route -- answers
    // both open questions (which OAM slot, and which path) in one latch.
    //
    // 2026-08-13 (Test 190, Gemini): Tests 188/189 both still read all-zero
    // on the COLOR TEST screen. Verified via pixel-exact bounding-box
    // measurement that the visible test sprites sit at v_cnt 160-191, while
    // this diagnostic's own on-screen display rows (Battlantis.sv, v_cnt
    // 96-136) are scanned out EARLIER in the same frame's raster order.
    // Since the live accumulator below is cleared at every v_cnt==0 and only
    // updated when the triggering draw happens (v_cnt 160-191, later this
    // same frame), the display rows are always reading THIS frame's
    // just-cleared zero -- the real value only exists in the register AFTER
    // its own display window has already been scanned out, so it's never
    // visible on screen, no matter how many frames pass. This is a general
    // hazard for any per-frame-reset value display whose own screen
    // position is above the event it's tracking, not specific to this one
    // diagnostic -- worth remembering for earlier readings too (Tests 184
    // and 188 both used this same live-accumulator-plus-per-frame-reset
    // pattern with display rows at v_cnt 56-96/96-136, so any tracked
    // sprite drawn below THAT row on screen would have shown the same
    // false all-zero). Fixed here via double-buffering: snapshot the live
    // accumulator into `_stable` shadow registers once per frame, at the
    // same v_cnt==0 edge that clears the live copy for the new frame --
    // the shadow registers hold a complete, fully-settled reading of the
    // PREVIOUS frame and are never touched mid-frame, so they're immune to
    // the display row's own screen position. The *_out ports below now
    // expose the shadow copies instead of the live ones.
    reg [17:0] last_visible_addr, last_visible_addr_stable;
    reg [6:0]  last_visible_sprite_idx, last_visible_sprite_idx_stable;
    reg [7:0]  last_visible_code_lsb, last_visible_code_lsb_stable;
    reg [7:0]  last_visible_attr, last_visible_attr_stable;
    reg [7:0]  last_visible_flags, last_visible_flags_stable;
    reg        last_visible_was_sdram, last_visible_was_sdram_stable;
    // Zoom debug (2026-08-15): is the visible seam on multi-tile sprites
    // (e.g. the Red Dragon boss) actually exercising a non-1:1 zoom_raw at
    // all? The tile-boundary rounding fix only changes behavior away from
    // zoom_raw==128 -- if the seam persists at exactly 128, it has a
    // different root cause entirely. Sticky OR-of-deviation-from-128 plus
    // the raw value itself, captured at the same proven trigger as the
    // other last_visible_* fields above.
    reg [9:0]  last_visible_zoom, last_visible_zoom_stable;
    reg        zoom_ever_nonstandard;
    always @(posedge clk) begin
        if (reset || !sprite_traffic_active) begin
            last_visible_addr <= 18'd0;
            last_visible_sprite_idx <= 7'd0;
            last_visible_code_lsb <= 8'd0;
            last_visible_attr <= 8'd0;
            last_visible_flags <= 8'd0;
            last_visible_was_sdram <= 1'b0;
            last_visible_addr_stable <= 18'd0;
            last_visible_sprite_idx_stable <= 7'd0;
            last_visible_code_lsb_stable <= 8'd0;
            last_visible_attr_stable <= 8'd0;
            last_visible_flags_stable <= 8'd0;
            last_visible_was_sdram_stable <= 1'b0;
            last_visible_zoom <= 10'd0;
            last_visible_zoom_stable <= 10'd0;
        end else if (v_cnt == 9'd0 && !last_v_cnt_0) begin
            // Snapshot the just-completed frame's final live values BEFORE
            // clearing the live accumulator for the new frame.
            last_visible_addr_stable <= last_visible_addr;
            last_visible_sprite_idx_stable <= last_visible_sprite_idx;
            last_visible_code_lsb_stable <= last_visible_code_lsb;
            last_visible_attr_stable <= last_visible_attr;
            last_visible_flags_stable <= last_visible_flags;
            last_visible_was_sdram_stable <= last_visible_was_sdram;
            last_visible_zoom_stable <= last_visible_zoom;
            last_visible_addr <= 18'd0;
            last_visible_sprite_idx <= 7'd0;
            last_visible_code_lsb <= 8'd0;
            last_visible_attr <= 8'd0;
            last_visible_flags <= 8'd0;
            last_visible_was_sdram <= 1'b0;
            last_visible_zoom <= 10'd0;
        end else if (state == 15 && cur_pixel != 4'd0 && cur_draw_x >= 10'sd0 && cur_draw_x < 10'sd256) begin
            last_visible_addr <= calc_rom_addr;
            last_visible_sprite_idx <= sprite_idx;
            last_visible_code_lsb <= spr_code_lsb;
            last_visible_attr <= spr_attr;
            last_visible_flags <= spr_flags;
            last_visible_was_sdram <= (calc_rom_addr >= 18'h10000);
            last_visible_zoom <= zoom_raw;
        end
        if (reset) begin
            zoom_ever_nonstandard <= 1'b0;
        end else if (state == 15 && cur_pixel != 4'd0 && cur_draw_x >= 10'sd0 && cur_draw_x < 10'sd256
                     && (width_tiles_x != 3'd1 || height_tiles_y != 3'd1) && zoom_raw != 10'd128) begin
            zoom_ever_nonstandard <= 1'b1;
        end
    end
    assign last_bram_addr_out = last_visible_addr_stable;
    assign last_bram_sprite_idx_out = last_visible_sprite_idx_stable;
    assign last_bram_code_lsb_out = last_visible_code_lsb_stable;
    assign last_bram_attr_out = last_visible_attr_stable;
    assign last_bram_flags_out = last_visible_flags_stable;
    assign last_bram_was_sdram_out = last_visible_was_sdram_stable;
    assign last_bram_zoom_out = last_visible_zoom_stable;
    assign zoom_ever_nonstandard_out = zoom_ever_nonstandard;

    // Four-corner tile index comparison (2026-08-15, 3rd iteration):
    // the 2nd iteration's top-row-vs-bottom-row check proved the RTL's
    // sub-tile index math is not duplicating tiles in general (57 valid
    // live samples, never equal, differences always matched correct
    // math). But direct reference-footage comparison then confirmed the
    // visual bug IS real and specifically localized to the LEFT side of a
    // bordered multi-tile sprite (top-left and bottom-left corners show
    // an extra black blob bulge; top-right/bottom-right and the general
    // frame shape match reference). That's a narrower, more specific
    // target than "top row vs bottom row" -- this iteration latches all
    // FOUR corner tile indices (top-left, top-right, bottom-left,
    // bottom-right) of a multi-tile sprite, each independently, tagged
    // with sprite_idx so a cross-corner comparison is only trusted when
    // all four readings came from the literal same OAM entry this frame.
    // If left-side corners differ from right-side corners in a way that
    // doesn't match the expected symmetric pattern, that points at the
    // x_tile bit handling in final_8x8_index specifically, not y_tile.
    // Zoom-wrap duplication detector TEMPORARILY DISABLED (2026-08-16) for
    // boot-hang bisection (task #15) -- logic removed, outputs tied to
    // safe constants, so Battlantis.sv's instantiation doesn't need to
    // change. Restore from git history once the hang is isolated, if this
    // wasn't the cause.
    assign zoom_wrap_hit_out = 1'b0;
    assign zoom_wrap_sprite_idx_out = 7'd0;
    assign zoom_wrap_zoom_raw_out = 10'd0;
    assign zoom_wrap_spr_y_out = 10'd0;
    assign zoom_wrap_draw_x_out = 8'd0;
    assign zoom_wrap_v_cnt_out = 9'd0;
    assign zoom_wrap_tile_idx_out = 13'd0;

    reg [15:0] max_bram_addr_used;
    always @(posedge clk) begin
        if (reset) begin
            max_bram_addr_used <= 16'd0;
        end else if (state == 15 && cur_pixel != 4'd0 && cur_draw_x >= 10'sd0 && cur_draw_x < 10'sd256
                     && calc_rom_addr < 18'h10000 && calc_rom_addr[15:0] > max_bram_addr_used) begin
            max_bram_addr_used <= calc_rom_addr[15:0];
        end
    end
    assign max_bram_addr_used_out = max_bram_addr_used;

    // Per-frame companion to max_sdram_addr: did ANY real SDRAM fetch that
    // completed THIS FRAME return non-zero data? Distinguishes the two
    // remaining explanations once max_sdram_addr proved requests genuinely
    // do reach deep upper-ROM addresses even on screens where the expected
    // sprite never renders (e.g. the Goblin/Ogre/Baron tally screen): if this
    // stays RED, every deep fetch this frame really is coming back all-zero
    // (transparent) -- an addressing/alignment problem specific to whatever
    // these fetches are actually targeting. If this is GREEN, real non-zero
    // pixel data IS coming back but isn't ending up on screen -- a
    // draw-priority/visibility bug downstream of the fetch, not SDRAM itself.
    reg frame_has_nonzero;
    always @(posedge clk) begin
        if (reset || !sprite_traffic_active) begin
            frame_has_nonzero <= 1'b0;
        end else if (v_cnt == 9'd0 && !last_v_cnt_0) begin
            frame_has_nonzero <= 1'b0;
        end else if (state == 14 && sprite_sdram_ready && sprite_sdram_dout != 8'h00) begin
            frame_has_nonzero <= 1'b1;
        end
    end
    assign frame_has_nonzero_out = frame_has_nonzero;

    assign sprite_sdram_addr = 25'h20000 + {7'd0, calc_rom_addr};
    assign diag_sdram_req_count = diag_req_count;
    assign diag_sdram_ready_count = diag_ready_count;

    // ==============================================================================
    // SPRITE RAM (512 Bytes True Dual-Port BRAM)
    // ==============================================================================
    (* ramstyle = "M10K" *) reg [7:0] oam [0:511];
    // 2026-08-29, task #83 follow-up: `oam` is read directly by the sprite
    // render machine (oam_dout below) with no valid-bit gating at all --
    // unlike k007342.v's vram, which got this same fix, this had no
    // defined power-on content, so FPGA block RAM's fixed (not random,
    // unlike real discrete SRAM) uninitialized bit pattern read as sprite
    // attribute/position/tile-code bytes, drawing garbage sprites (using
    // otherwise-correctly-loaded real tile data from sprite_rom_bram,
    // which is why the garbage looked like genuine sprite content rather
    // than random noise) for the brief window before the CPU's boot code
    // writes real OAM content. Same fix as k007342.v's vram: an explicit
    // all-zero initial value costs no additional M10K blocks, only
    // changes their power-on content.
    initial begin
        integer oam_init_i;
        for (oam_init_i = 0; oam_init_i < 512; oam_init_i = oam_init_i + 1) oam[oam_init_i] = 8'h00;
    end

    // Port A: CPU Read/Write Interface
    reg [7:0] cpu_dout_reg;
    always @(posedge clk) begin
        if (cpu_we) begin
            oam[cpu_addr] <= cpu_din;
        end
        cpu_dout_reg <= oam[cpu_addr];
    end
    assign cpu_dout = cpu_dout_reg;

    // Port B: Sprite Render Machine Read-Only Interface
    reg [7:0] oam_dout;
    always @(posedge clk) begin
        oam_dout <= oam[oam_addr];
    end

    // ==============================================================================
    // TILE BOUNDARY ROMs (2026-08-16, replaces the old flat zoom_unit_step
    // reciprocal ROM) -- four 1024x13-bit tables, one per tile-boundary
    // index n=1..4, each precomputed as floor((1024*n + zoom_raw/2) /
    // zoom_raw) for zoom_raw 0-1023 (0 for zoom_raw==0, the unused-slot
    // case, which state 5 already skips before this is ever needed).
    // ==============================================================================
    // Real hardware (k007420_mame.cpp) computes each tile's destination
    // boundary individually: `zoom = 0x10000*128/zoom_raw` (a truncated
    // reciprocal) then `boundary(n) = (zoom*n + 4096) >> 13`. The OLD flat
    // approach here (a single zoom_unit_step = floor(1024/zoom_raw),
    // multiplied by n) is NOT the same value in general -- for most single,
    // isolated sprites the drift is sub-pixel and invisible, but for
    // MULTI-PIECE composites (e.g. the Red Dragon boss, built from several
    // adjacent 32x32 OAM entries meant to tile together edge-to-edge) the
    // CPU positions each piece assuming real hardware's rounding, so any
    // accumulated difference from our flat approximation opens a visible
    // gap between pieces -- confirmed on real hardware as both horizontal
    // bands (vertical tile-stacking gaps) and a vertical seam (the
    // gap between a sprite and its horizontally-flipped mirror pair).
    // `floor((1024*n + zoom_raw/2) / zoom_raw)` is algebraically exact to
    // MAME's real double-truncated formula for every zoom_raw (verified by
    // hand for several values before generating these tables) because
    // 8388608 (MAME's 0x10000*128) is an exact multiple of 8192 (MAME's
    // right-shift-13 divisor) -- 8388608/8192 = 1024 exactly, so the two
    // truncation steps collapse into this single division cleanly.
    // Read address/timing identical to the old zoom_recip_rom: issued at
    // state==19 (one cycle before evaluation state 5 needs it) using
    // {spr_flags[1:0], oam_dout} (the raw zoom byte about to be latched
    // into spr_zoom that same cycle), landing in the registered outputs
    // one cycle later.
    (* ramstyle = "M10K" *) reg [12:0] tile_bound1_rom [0:1023];
    (* ramstyle = "M10K" *) reg [12:0] tile_bound2_rom [0:1023];
    (* ramstyle = "M10K" *) reg [12:0] tile_bound3_rom [0:1023];
    (* ramstyle = "M10K" *) reg [12:0] tile_bound4_rom [0:1023];
    initial $readmemh("rtl/tile_bound1.hex", tile_bound1_rom);
    initial $readmemh("rtl/tile_bound2.hex", tile_bound2_rom);
    initial $readmemh("rtl/tile_bound3.hex", tile_bound3_rom);
    initial $readmemh("rtl/tile_bound4.hex", tile_bound4_rom);
    reg [12:0] tile_bound1, tile_bound2, tile_bound3, tile_bound4;
    always @(posedge clk) begin
        if (state == 19) begin
            tile_bound1 <= tile_bound1_rom[{spr_flags[1:0], oam_dout}];
            tile_bound2 <= tile_bound2_rom[{spr_flags[1:0], oam_dout}];
            tile_bound3 <= tile_bound3_rom[{spr_flags[1:0], oam_dout}];
            tile_bound4 <= tile_bound4_rom[{spr_flags[1:0], oam_dout}];
        end
    end

    // ==============================================================================
    // LINE BUFFERS (Two 256x8-bit rams for ping-pong)
    // ==============================================================================
    reg [7:0] line_buf_0 [0:255];
    reg [7:0] line_buf_1 [0:255];
    
    wire buf_sel = v_cnt[0]; // Ping-pong every scanline
    
    // Clear logic — clears the OFF-SCREEN buffer at the start of each scanline (h_cnt = 0)
    reg [8:0] clear_idx;
    reg last_h_cnt_0_clear;
    always @(posedge clk) begin
        last_h_cnt_0_clear <= (h_cnt == 0);
        if (reset || (h_cnt == 0 && !last_h_cnt_0_clear)) begin
            clear_idx <= 0;
        end else if (clear_idx < 256) begin
            clear_idx <= clear_idx + 1'd1;
        end
    end
    
    wire clear_we = (clear_idx < 256);
    wire [7:0] clear_addr = clear_idx[7:0];
    
    // Draw logic (from state machine)
    reg draw_we;
    reg [7:0] draw_addr;
    reg [7:0] draw_data;
    
    wire lb_we_0 = (buf_sel == 1'b0) ? (clear_we ? 1'b1 : draw_we) : 1'b0;
    wire [7:0] lb_write_addr_0 = clear_we ? clear_addr : draw_addr;
    wire [7:0] lb_write_data_0 = clear_we ? 8'd0 : draw_data;
    
    wire lb_we_1 = (buf_sel == 1'b1) ? (clear_we ? 1'b1 : draw_we) : 1'b0;
    wire [7:0] lb_write_addr_1 = clear_we ? clear_addr : draw_addr;
    wire [7:0] lb_write_data_1 = clear_we ? 8'd0 : draw_data;
    
    always @(posedge clk) begin
        if (lb_we_0) line_buf_0[lb_write_addr_0] <= lb_write_data_0;
        if (lb_we_1) line_buf_1[lb_write_addr_1] <= lb_write_data_1;
    end
    
    // Read from line buffers
    reg [7:0] lb_read_data_0;
    reg [7:0] lb_read_data_1;
    always @(posedge clk) begin
        lb_read_data_0 <= line_buf_0[h_cnt[7:0]];
        lb_read_data_1 <= line_buf_1[h_cnt[7:0]];
    end
    
    wire [7:0] active_pixel = buf_sel ? lb_read_data_0 : lb_read_data_1;
    assign sprite_color = active_pixel;
    assign sprite_active = (active_pixel != 0) && (h_cnt < 256);

    // ==============================================================================
    // SPRITE RENDER STATE MACHINE
    // ==============================================================================
    reg [4:0] state;
    reg signed [9:0] spr_y;
    reg [7:0] spr_x, spr_code_lsb, spr_attr, spr_flags, spr_zoom;
    reg [6:0] pix_x;
    reg [4:0] pix_y;
    reg [8:0] oam_addr;
    
    // 2026-08-16: wrap point matches Battlantis.sv's v_cnt counter, which
    // now wraps at 263 (V-total = 264, fixed to match MAME's real raster --
    // was 261/V-total=262). This was missed in the original V-total fix and
    // left stale, causing a real mismatch between this module's idea of
    // "last line" and the actual counter's.
    // TEMPORARY DIAGNOSTIC REVERT (2026-08-16, boot-hang bisection) -- back
    // to 261, matching Battlantis.sv's own temporarily-reverted V-total.
    wire [8:0] eval_v = (v_cnt == 9'd261) ? 9'd0 : (v_cnt + 9'd1);
    wire signed [9:0] true_y_diff_direct = $signed({1'b0, eval_v}) - spr_y;
    // Sprite Y-wrap (see the wrap_y port comment above): spr_y = 256 -
    // raw_y ranges [1,256], so a sprite meant to sit just past the bottom
    // edge naturally computes a true_y_diff_direct that only falls in the
    // visible range during vertical blanking rows (never actually drawn)
    // -- exactly the case this feature exists to handle. If the direct
    // position is off the visible 0-255 range and wrap_y is enabled, retry
    // 256px earlier (matches MAME's non-flipped dy=-256); only one of the
    // two positions can ever be on-screen at once for a given sprite.
    wire true_y_diff_direct_offscreen = (true_y_diff_direct < 10'sd0) || (true_y_diff_direct >= 10'sd256);
    wire signed [9:0] true_y_diff = (wrap_y && true_y_diff_direct_offscreen) ? (true_y_diff_direct - 10'sd256) : true_y_diff_direct;

    wire flip_x = spr_flags[2];
    wire flip_y = spr_flags[3];

    // Sprite size code (spr_flags[6:4]) selects the bounding box: Battlantis uses
    // 16x16 for most enemies/player, but also 32x32 for bosses (Red Dragon, Emperor
    // Asmodeus, Stage 3/6 bosses) and 8x8/8x16/16x8 elsewhere. Hardcoding max=15
    // here previously clamped 32x32 sprites to a 16x16 box, cutting off their
    // bottom/right half. Bounds must track the same size code used by final_8x8_index below.
    //
    // 2026-08-13 (Gemini + Claude): all 5 of MAME's real size codes (000/001/
    // 010/011/100) are now enumerated explicitly, rather than lumping 000
    // (16x16) into an implicit "everything else" default alongside the 3
    // genuinely-reserved/unused codes (101/110/111). MAME's own switch
    // handles the same 5 real cases explicitly and falls back to 8x8 ONLY
    // for the 3 reserved ones (k007420_mame.cpp, `m_ram[offs+4]&0x70`
    // default case: width=height=1). The previous version's single shared
    // default (15) meant any reserved code got treated exactly like 16x16
    // -- a real, verified discrepancy that would render a sprite in a box
    // ~4x the area MAME/real hardware uses (correct tile/animation, wrong
    // size) -- caught while investigating Grimlock's bullet rendering
    // oversized after Test 197 first let it render at all. Gemini's first
    // draft of this fix would have simply changed the shared default to 8x8,
    // which -- caught before applying -- would have shrunk every ordinary
    // 16x16 sprite in the game (16x16 was never explicitly enumerated, so it
    // would have fallen into that same default). This version explicitly
    // enumerates 000 and 001/010 (whichever a given ternary doesn't already
    // cover) at their correct MAME values, so only the 3 truly-reserved codes
    // reach the new 8x8 fallback.
    wire [4:0] max_y = (spr_flags[6:4] == 3'b100) ? 5'd31 :  // 32x32
                       (spr_flags[6:4] == 3'b011) ? 5'd7  :  // 8x8
                       (spr_flags[6:4] == 3'b010) ? 5'd7  :  // 16x8
                       (spr_flags[6:4] == 3'b001) ? 5'd15 :  // 8x16
                       (spr_flags[6:4] == 3'b000) ? 5'd15 :  // 16x16
                                                     5'd7;    // reserved 101/110/111 -> MAME default (8x8)
    wire [4:0] max_x = (spr_flags[6:4] == 3'b100) ? 5'd31 :  // 32x32
                       (spr_flags[6:4] == 3'b011) ? 5'd7  :  // 8x8
                       (spr_flags[6:4] == 3'b001) ? 5'd7  :  // 8x16
                       (spr_flags[6:4] == 3'b010) ? 5'd15 :  // 16x8
                       (spr_flags[6:4] == 3'b000) ? 5'd15 :  // 16x16
                                                     5'd7;    // reserved 101/110/111 -> MAME default (8x8)
    
    // 13-bit base 8x8 tile index based exactly on MAME's battlnts_state::sprite_callback:
    // code |= ((color & 0xc0) << 2) | m_spritebank; code = (code << 2) | ((color & 0x30) >> 4);
    wire [12:0] base_8x8_index = {spritebank, spr_attr[7:6], spr_code_lsb, spr_attr[5:4]};

    // Native MAME Konami K007420 Zoom Logic (full 10-bit register):
    // zoom_raw = ram[offs+5] | ((ram[offs+4] & 0x03) << 8);  0x080 (128) = 1:1 scale,
    // < 0x80 enlarges, > 0x80 reduces. spr_flags is OAM byte 4, spr_zoom is OAM byte 5,
    // matching MAME's byte layout exactly.
    wire [9:0] zoom_raw = {spr_flags[1:0], spr_zoom};

    // MAME's real sprites_draw() (k007420_mame.cpp) does NOT scale a multi-
    // tile sprite as one continuous texture -- it loops over each 8x8
    // source tile independently, computing THAT tile's own destination
    // start position and width in whole destination pixels (`sx = ox +
    // ((zoom*x + (1<<12)) >> 13)`, `zw = next_sx - sx`), then stretches
    // just that one 8x8 tile to fit its own zw-pixel footprint via
    // zoom_transpen. Each tile's internal stretch restarts its own
    // rounding fresh at source x=0 -- tile boundaries in destination space
    // always land exactly where the previous tile's footprint ends, by
    // construction.
    //
    // An earlier version of this file instead computed ONE continuous
    // inverse-scale mapping across the sprite's full width/height
    // (dest*zoom_raw>>7), deriving which tile a pixel belonged to as a
    // side effect of that single formula. This only agrees with MAME's
    // independent per-tile rounding when zoom_raw==128 (1:1, no scaling)
    // -- at any other zoom factor the two approaches drift apart across a
    // multi-tile sprite's boundaries, producing a visible seam (a
    // duplicated or skipped source column) exactly where two tiles meet.
    // Confirmed via a real screenshot: a vertical seam running along the
    // horizontal center of a 32x32 boss sprite, exactly the boundary
    // between its 2nd and 3rd tile columns (2026-08-15, user report +
    // visual confirmation -- previously misread as a "shadow" artifact).
    //
    // That fix (a single flat zoom_unit_step multiplied by tile index) was
    // itself only an approximation of MAME's real per-tile rounding, close
    // enough to fix a single sprite's own internal tile seam but not exact
    // enough for multi-sprite composites (the Red Dragon boss and similar
    // multi-piece bosses) where the CPU positions each separate OAM piece
    // assuming real hardware's exact rounding -- see the 2026-08-16
    // tile_bound1-4 ROM declarations above (search "TILE BOUNDARY ROMs")
    // for the corrected, MAME-exact per-boundary computation that replaced
    // it. tile_bound1/2/3/4 are now registered directly from those ROMs,
    // read/latched on the same state==19/one-cycle-later timing as before.

    // How many 8x8 tiles wide/tall this sprite's size code covers (1, 2, or
    // 4 -- Battlantis never uses 3). Bounds the boundary search below to the
    // sprite's real tile count.
    wire [2:0] width_tiles_x  = (max_x >= 5'd31) ? 3'd4 : (max_x >= 5'd15) ? 3'd2 : 3'd1;
    wire [2:0] height_tiles_y = (max_y >= 5'd31) ? 3'd4 : (max_y >= 5'd15) ? 3'd2 : 3'd1;

    // Y axis: which source tile row true_y_diff (destination-relative Y)
    // falls into, that tile's own destination-space start, and the LOCAL
    // per-pixel source mapping within just that tile (restarting at 0, per
    // MAME's independent per-tile stretch).
    wire [12:0] true_y_diff_w = true_y_diff[9] ? 13'd0 : {4'd0, true_y_diff[8:0]};
    wire [1:0] y_tile_new =
        (height_tiles_y == 3'd1) ? 2'd0 :
        (true_y_diff_w < tile_bound1) ? 2'd0 :
        (height_tiles_y == 3'd2 || true_y_diff_w < tile_bound2) ? 2'd1 :
        (true_y_diff_w < tile_bound3) ? 2'd2 : 2'd3;
    wire [12:0] y_tile_dest_start =
        (y_tile_new == 2'd0) ? 13'd0 :
        (y_tile_new == 2'd1) ? tile_bound1 :
        (y_tile_new == 2'd2) ? tile_bound2 : tile_bound3;
    // local_dx is provably < this tile's own boundary gap (<=1024, 11 bits)
    // by construction (y_tile_new is chosen so true_y_diff_w sits within
    // [dest_start, next boundary)) -- narrowed from the 13-bit subtraction
    // operands so the
    // multiply below only needs an 11x10 multiplier, not 13x10, shortening
    // this section's combinational path (an initial wider-than-necessary
    // version left -0.42ns of unmet setup slack).
    wire [12:0] y_local_dx_full = true_y_diff_w - y_tile_dest_start;
    wire [10:0] y_local_dx = y_local_dx_full[10:0];
    wire [20:0] y_local_mul = y_local_dx * zoom_raw;
    wire [13:0] y_local_full = y_local_mul[20:7];
    wire [4:0]  y_local_src = (y_local_full > 14'd7) ? 5'd7 : y_local_full[4:0];
    wire [4:0]  tex_y_raw = {y_tile_new, y_local_src[2:0]};
    wire [4:0]  tex_y     = (tex_y_raw > max_y) ? max_y : tex_y_raw;
    wire [4:0]  actual_y  = flip_y ? (max_y - tex_y) : tex_y;

    // X axis: same technique as Y above.
    wire [12:0] pix_x_w = {6'd0, pix_x};
    wire [1:0] x_tile_new =
        (width_tiles_x == 3'd1) ? 2'd0 :
        (pix_x_w < tile_bound1) ? 2'd0 :
        (width_tiles_x == 3'd2 || pix_x_w < tile_bound2) ? 2'd1 :
        (pix_x_w < tile_bound3) ? 2'd2 : 2'd3;
    wire [12:0] x_tile_dest_start =
        (x_tile_new == 2'd0) ? 13'd0 :
        (x_tile_new == 2'd1) ? tile_bound1 :
        (x_tile_new == 2'd2) ? tile_bound2 : tile_bound3;
    wire [12:0] x_local_dx_full = pix_x_w - x_tile_dest_start;
    wire [10:0] x_local_dx = x_local_dx_full[10:0]; // see y_local_dx's comment above
    wire [20:0] x_local_mul = x_local_dx * zoom_raw;
    wire [13:0] x_local_full = x_local_mul[20:7];
    wire [4:0]  x_local_src = (x_local_full > 14'd7) ? 5'd7 : x_local_full[4:0];
    wire [4:0]  tex_x_raw = {x_tile_new, x_local_src[2:0]};
    wire [4:0]  tex_x     = (tex_x_raw > max_x) ? max_x : tex_x_raw;
    wire [4:0]  actual_x  = flip_x ? (max_x - tex_x) : tex_x;

    // Destination-space loop/window bounds: stop stepping once we've walked
    // past the sprite's total destination-space footprint (computed the
    // same tile-boundary way, extended one more tile past the last real
    // boundary already computed).
    wire [12:0] x_total_dest_width =
        (width_tiles_x == 3'd1) ? tile_bound1 :
        (width_tiles_x == 3'd2) ? tile_bound2 : tile_bound4;
    wire [12:0] y_total_dest_height =
        (height_tiles_y == 3'd1) ? tile_bound1 :
        (height_tiles_y == 3'd2) ? tile_bound2 : tile_bound4;
    wire sprite_y_in_bounds = (true_y_diff >= 10'sd0) && (true_y_diff_w < y_total_dest_height);
    wire sprite_x_past_edge = (pix_x_w >= x_total_dest_width);
    
    reg [7:0] latched_rom_byte;
    // Tracks the ROM byte address (2 pixels/byte) currently held in latched_rom_byte.
    // calc_rom_addr already IS the byte address (actual_x[2:1] divides by 2; the nibble
    // select is actual_x[0], applied separately below) — so a fetch is only needed when
    // calc_rom_addr differs from what's already latched, not on a fixed pix_x parity.
    // This matters once zoom_raw != 128: a shrunk sprite can jump more than one byte
    // between consecutive destination pixels, and an enlarged sprite can hold the same
    // byte for several consecutive destination pixels — neither lines up with pix_x's LSB.
    reg [17:0] last_byte_addr;
    reg        last_byte_valid; // explicit flag: last_byte_addr is only meaningful when set
    wire [3:0] cur_pixel = actual_x[0] ? latched_rom_byte[3:0] : latched_rom_byte[7:4];
    wire [1:0] x_tile = actual_x[4:3];
    wire [1:0] y_tile = actual_y[4:3];

    // 13-bit base 8x8 tile index based exactly on MAME's battlnts_state::sprite_callback:
    // code |= ((color & 0xc0) << 2) | m_spritebank; code = (code << 2) | ((color & 0x30) >> 4);
    reg [12:0] final_8x8_index;
    always @(*) begin
        case (spr_flags[6:4])
            3'b000: final_8x8_index = (base_8x8_index & 13'h1FFC) + {11'd0, y_tile[0], x_tile[0]};
            3'b001: final_8x8_index = (base_8x8_index & 13'h1FFD) + {11'd0, y_tile[0], 1'b0}; // 8x16 (y contributes to bit1, matches MAME yoffset={0,2,8,10})
            3'b010: final_8x8_index = (base_8x8_index & 13'h1FFE) + {12'd0, x_tile[0]}; // 16x8 (Match MAME mask ~1)
            3'b011: final_8x8_index = base_8x8_index;
            3'b100: final_8x8_index = (base_8x8_index & 13'h1FF0) + {9'd0, y_tile[1], x_tile[1], y_tile[0], x_tile[0]};
            default: final_8x8_index = (base_8x8_index & 13'h1FFC) + {11'd0, y_tile[0], x_tile[0]};
        endcase
    end

    // Signed X position (spr_flags[7] is X MSB: 1 = sprite offset by -256 pixels per MAME ox = spr_x - 256 spec)
    wire signed [9:0] signed_spr_x = spr_flags[7] ? ($signed({1'b0, spr_x}) - 10'sd256) : $signed({2'b00, spr_x});
    wire signed [11:0] cur_draw_x_full = signed_spr_x + $signed({5'd0, pix_x});
    wire signed [9:0] cur_draw_x = cur_draw_x_full[9:0];
    
    // Multiply by 32 bytes per 8x8 tile, then add Y offset (4 bytes per line) and X offset (1 byte per 2 pixels)
    wire [17:0] calc_rom_addr = {final_8x8_index, 5'd0} + {13'd0, actual_y[2:0], 2'd0} + {15'd0, actual_x[2:1]};
    
    reg last_h_cnt_0;
    reg [6:0] sprite_idx; // 63 down to 0
    // 64KB Main Sprite ROM BRAM Cache (0x00000 - 0x0FFFF relative / 0x20000 - 0x2FFFF SDRAM IOCTL).
    // FULL 256KB STATIC SPRITE ROM (2026-08-14, Test 222 -- supersedes the
    // 64KB-cache-plus-6-slots-plus-SDRAM-overflow design below this comment
    // in the project's history). Freed up by the companion background-tile
    // migration to a small SDRAM-backed cache (project_history/debugging_log.md,
    // section 19+): background no longer needs the full 256KB tile_rom, and
    // that ~192KB swaps directly to sprites, which now hold their entire ROM
    // statically -- eliminating SDRAM Port 3 sprite traffic (and the
    // per-sprite BRAM-slot patchwork it required) entirely, not just for the
    // specific addresses Tests 78-201 had individually confirmed and
    // reallocated. This also sidesteps Test 202's separate, earlier finding
    // that sprite SDRAM access is unreliable even in complete isolation (not
    // just under Port2+Port3 contention) -- rather than trying to make that
    // access pattern trustworthy, this avoids it altogether.
    (* ramstyle = "M10K" *) reg [7:0] sprite_rom_bram [0:262143];
    reg [17:0] sprite_bram_addr;
    reg [7:0]  sprite_bram_dout;

    always @(posedge clk) begin
        if (ioctl_wr && ioctl_addr >= 25'h20000 && ioctl_addr < 25'h60000) begin
            // BUG FIX (2026-08-14, caught by user's screen report): must subtract
            // the 0x20000 sprite-ROM base BEFORE truncating to 18 bits, not just
            // truncate the raw absolute ioctl_addr -- the truncation-only version
            // wrote bytes from the ROM's second half (absolute 0x40000-0x5FFFF)
            // to the SAME array indices as the first half (they share the same
            // low 18 bits once 0x40000 wraps past the 18-bit window), silently
            // overwriting real data with the wrong half's bytes, while relative
            // reads (calc_rom_addr, correctly 0-based) for the first half never
            // got their real data written at all -- exactly the "wrong sprite
            // shown" symptom reported on real hardware.
            sprite_rom_bram[ioctl_addr - 25'h20000] <= ioctl_dout;
        end
        sprite_bram_dout <= sprite_rom_bram[sprite_bram_addr];
    end

    // Latch 25'h20003 byte on the write-path instead of reading it with an extra
    // BRAM port (which broke simple dual-port inference and forced Quartus to
    // implement the 512Kb array using general logic/registers, hanging the
    // fitter for a very long time).
    // NOT gated on `reset` (= sys_reset | ioctl_download at the top level) --
    // that signal stays HIGH for the entire download, including the exact
    // moment ioctl_addr==25'h20003 is written, so a reset branch here would
    // permanently mask the latch and it would read 0x00 forever regardless of
    // the real data (same class of bug already avoided by download_xor_checksum
    // in Battlantis.sv, which resets on sys_reset only for the same reason).
    always @(posedge clk) begin
        if (ioctl_wr && ioctl_addr == 25'h20003) begin
            bram_debug_out <= ioctl_dout;
        end
    end

    reg [7:0] raw_y;
    
    reg [15:0] diag_req_count;
    reg [15:0] diag_ready_count;
    reg [7:0] sdram_timeout;
    reg sdram_ready_latched;

    always @(posedge clk) begin
        last_h_cnt_0 <= (h_cnt == 0);
        draw_we <= 0;
        
        if (reset) begin
            state <= 16;
            sprite_sdram_req <= 1'b0;
            sdram_ready_latched <= 1'b0;
            sprite_idx <= 7'd63;
            diag_req_count <= 0;
            diag_ready_count <= 0;
            sdram_timeout <= 0;
            raw_y <= 8'd0;
            last_byte_valid <= 1'b0; // no byte latched yet, forces first fetch
        end else if (h_cnt == 0 && !last_h_cnt_0) begin
            state <= 0;
            sprite_idx <= 7'd63;
            sprite_sdram_req <= 1'b0;
        end else begin
            case (state)
                0: begin // Wait for line buffer clear
                    if (clear_idx >= 256) begin
                        state <= 1;
                    end
                end
                
                1: begin // Fetch Sprite Y
                    if (sprite_idx[6]) begin
                        state <= 16; // Done (Idle)
                    end else begin
                        oam_addr <= {sprite_idx[5:0], 3'd0};
                        state <= 2;
                    end
                end
                
                2: state <= 3;
                
                3: begin
                    raw_y <= oam_dout;
                    spr_y <= 10'sd256 - $signed({2'b00, oam_dout}); // MAME exact spec: oy = 256 - m_ram[offs+0]
                    oam_addr <= {sprite_idx[5:0], 3'd1};
                    state <= 4;
                end
                
                4: state <= 6;
                
                6: state <= 7;
                
                7: begin
                    spr_code_lsb <= oam_dout;
                    oam_addr <= {sprite_idx[5:0], 3'd2};
                    state <= 8;
                end
                
                8: state <= 9;
                
                9: begin
                    spr_attr <= oam_dout;
                    oam_addr <= {sprite_idx[5:0], 3'd3};
                    state <= 10;
                end
                
                10: state <= 11;
                
                11: begin
                    spr_x <= oam_dout;
                    oam_addr <= {sprite_idx[5:0], 3'd4};
                    state <= 17;
                end
                
                17: state <= 18;
                
                18: begin
                    spr_flags <= oam_dout;
                    oam_addr <= {sprite_idx[5:0], 3'd5};
                    state <= 20;
                end
                
                20: state <= 19;
                
                19: begin
                    spr_zoom <= oam_dout;
                    state <= 5;
                end
                
                5: begin // Evaluation State: all 6 OAM attributes are fully loaded!
                    pix_x <= 0;
                    // Removed the (spr_code_lsb != 0 || spr_attr != 0) clause (2026-08-13,
                    // Gemini + Claude collaboration): MAME's real sprites_draw() (see
                    // k007420_mame.cpp) has no code==0/color==0 skip -- it only skips on
                    // zoom==0. The clause was also redundant on its own terms: an unused
                    // OAM slot already has raw_y==0 AND zoom==0, both already checked here,
                    // so it added no real protection -- it only ever incorrectly rejected a
                    // genuine, positioned, correctly-zoomed sprite that happens to use tile
                    // 0 with attribute 0. Suspected cause of the Stage 11 player-invisible
                    // bug (visible for one frame right after reset, then vanishes) and a
                    // plausible contributor to the tally-screen portrait bug.
                    if (raw_y != 8'd0 && zoom_raw != 10'd0 && sprite_y_in_bounds) begin
                        last_byte_valid <= 1'b0; // new sprite: invalidate cache, force a real fetch at pix_x=0
                        state <= 12; // Active scanline: proceed to rendering
                    end else begin
                        sprite_idx <= sprite_idx - 1'd1;
                        state <= 1; // Out of bounds or disabled: skip cleanly
                    end
                end
                
                12: begin
                    // Simplified (2026-08-14, Test 222): the entire 256KB sprite ROM is
                    // now BRAM-resident (see the array declaration above), so this is
                    // always a same-cycle-address-set, next-cycle-data-ready BRAM read --
                    // no more per-address slot routing or SDRAM fallback needed.
                    if (last_byte_valid && calc_rom_addr == last_byte_addr) begin
                        // Same ROM byte as already latched (zoom held us on the same source
                        // pixel pair, or we're revisiting the same nibble) — no fetch needed.
                        state <= 15;
                    end else begin
                        sprite_bram_addr <= calc_rom_addr;
                        last_byte_addr <= calc_rom_addr;
                        last_byte_valid <= 1'b1;
                        state <= 13;
                    end
                end
                
                13: begin
                    // 2026-08-16 (task #20): this used to capture
                    // latched_rom_byte <= sprite_bram_dout directly here,
                    // but that's one cycle too early. sprite_bram_addr only
                    // became calc_rom_addr at the state-12-to-13 transition
                    // edge; the dedicated BRAM-read block (`sprite_bram_dout
                    // <= sprite_rom_bram[sprite_bram_addr]`, elsewhere in
                    // this file) only issues the read USING that address
                    // during this state-13 cycle, so its result isn't valid
                    // until the edge leaving state 13 -- capturing
                    // sprite_bram_dout here grabs the stale output left over
                    // from 2 fetches ago, not calc_rom_addr's actual data.
                    // Confirmed by hand-tracing the two registered stages
                    // (address register, then BRAM output register) and
                    // independently by Gemini during a zoom-shadow
                    // investigation -- see debugging_log.md entry 22/23.
                    // Fix: just wait here, capture one cycle later in state
                    // 21 instead, once sprite_bram_dout has actually caught
                    // up to the requested address.
                    state <= 21;
                end
                
                14: begin
                    sprite_sdram_req <= 1'b0;
                    sdram_timeout <= sdram_timeout + 1'd1;
                    
                    if (sprite_sdram_ready) begin
                        latched_rom_byte <= sprite_sdram_dout;
                        sdram_ready_latched <= 1'b1;
                        diag_req_count <= diag_req_count + 1'd1;
                        diag_ready_count <= diag_ready_count + 1'd1;
                        state <= 15;
                    end else if (sdram_ready_latched) begin
                        state <= 15;
                    end else if (sdram_timeout >= 8'd255) begin
                        latched_rom_byte <= 8'h00; // Default to transparent only on extreme timeout (never drop valid SDRAM data)
                        state <= 15;
                    end
                end

                21: begin
                    // 2026-08-16 (task #20): the actual capture, one cycle later
                    // than the old (buggy) state-13 capture -- see the comment on
                    // state 13 above for the full reasoning. sprite_bram_dout is
                    // now genuinely the BRAM's output for calc_rom_addr.
                    latched_rom_byte <= sprite_bram_dout;
                    state <= 15;
                end

                15: begin
                    if (cur_pixel != 4'd0 && cur_draw_x >= 10'sd0 && cur_draw_x < 10'sd256) begin
                        // Normal sprite pixel.
                        // Since we scan from sprite 63 down to 0, later iterations
                        // (lower index) have higher priority. We ALWAYS overwrite
                        // whatever is in the line buffer (background or lower-priority sprite).
                        draw_addr <= cur_draw_x[7:0];
                        // MAME's sprite_callback zeroes the runtime `color` param, but
                        // GFXDECODE_ENTRY("sprites", ..., 4*16, 1) hardcodes color_base=64
                        // (colors 64-79 = palette bank 4). Actual index = color_base +
                        // color*granularity = 64 + 0*16 = 64, i.e. bank 4, not bank 0 --
                        // keeps sprites out of the tilemap's bank-0 (background) colors.
                        draw_data <= {4'd4, cur_pixel};
                        draw_we   <= 1;
                    end
                    
                    pix_x <= pix_x + 1'd1;
                    if (sprite_x_past_edge || pix_x == 7'd127 || cur_draw_x >= 10'sd255) begin
                        sprite_idx <= sprite_idx - 1'd1;
                        state <= 1;
                    end else begin
                        state <= 12;
                    end
                end
                
                16: begin
                    // Idle
                end
            endcase
        end
    end

endmodule