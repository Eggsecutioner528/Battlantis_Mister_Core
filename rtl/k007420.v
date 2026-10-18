module k007420 #(
    parameter SPRITE_Y_ADJ = 0,
    parameter USE_PROM = 1   // 1: sprite pens go through the colour PROM (Blades of Steel); 0: raw pixel, no PROM (Battlantis, Rack 'Em Up)
) (
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

    // 2026-09-12 (Round 13, Blades of Steel bring-up): the sprite palette
    // bank nibble was hardcoded to 4'd4 (colors 64-79), matching
    // Battlantis's own real GFXDECODE_ENTRY(color_base=64) exactly -- not
    // an arbitrary choice for that game. bladestl's own real
    // GFXDECODE_ENTRY uses color_base=32 instead (colors 32-47), so this
    // is a genuine per-game hardware difference, not a bug in the
    // Battlantis value. Exposed as an explicit port rather than hardcoded
    // a second time, defaulting to 4'd4 so Battlantis/Rack 'Em Up's own
    // instantiations (which don't connect it) keep their exact original
    // behavior unchanged.
    input  wire [3:0]  sprite_color_base,

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
    output wire        sprite_sdram_req,
    output wire [24:0] sprite_sdram_addr,
    input  wire [7:0]  sprite_sdram_dout,
    input  wire        sprite_sdram_ready,
    input  wire [7:0]  sprite_sdram_dout2,   // the other byte of the 16 bit word the last Port 3 read returned (address ^ 1)

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

    // 2026-09-09: sprite_sdram_req/addr are now driven by the tagged cache's
    // own fill engine (see the "SPRITE ROM CACHE" section below), not by the
    // render FSM's calc_rom_addr directly and not by the old free-running
    // SIM_SPRITE_SDRAM_PROBE diagnostic prober (retired here the same way
    // Battlantis's own k007420.v already retired it -- that prober actively
    // hijacked this port's real request line, which this project's own
    // filelist.f was accidentally still enabling for simulation builds).
    assign sprite_sdram_addr = fill_sdram_addr_reg;
    assign sprite_sdram_req  = fill_req_reg;
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

    // ==============================================================================
    // SPRITE COLOR-LOOKUP PROM (797a07.16i, 256 bytes)
    // ==============================================================================
    // Round 15: real hardware doesn't feed the sprite tile ROM's raw 4-bit
    // pixel value straight into the palette RAM. bladestl's own MAME driver
    // (design_notes/bladestl_mame.cpp) builds an indirect palette table
    // where sprite pens 0x20-0x11f (16 colors x 16 pixel values) each look
    // up a byte in this PROM: `ctabentry = (color_prom[color*16+pixel] &
    // 0x0f) | 0x20`. This PROM is only 256 bytes, completely static, and
    // already streams past as part of the normal ROM download (the .mra
    // loads it at 0x160000-0x1600FF, right after every other ROM) -- so
    // rather than adding a whole new SDRAM read port/arbiter client just to
    // fetch 256 fixed bytes (real risk to the already-fragile Port 3 sprite
    // cache, see task #88's still-open ~11% failure rate), this simply
    // snoops those 256 bytes directly off the existing ioctl_wr/ioctl_addr/
    // ioctl_dout download stream, exactly the same same-module, no-cell-
    // boundary-crossing pattern BladesOfSteel.sv's own main-ROM sanity tap
    // already uses. By the time rendering starts (well after ioctl_download
    // completes), the table is fully populated with zero added latency,
    // matching the real PROM's own zero-latency hardware lookup.
    reg [3:0] sprite_color_prom [0:255];
    always @(posedge clk) begin
        if (ioctl_wr && ioctl_addr[24:8] == 17'h1600)
            sprite_color_prom[ioctl_addr[7:0]] <= ioctl_dout[3:0];
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

    // Harmonize sprite output pipeline latency with k007342's registered pixel_color output.
    // k007342 latches pixel_color on `if (ce_pix)` (1-pixel latency relative to h_cnt).
    // Registering sprite_color and sprite_active on `if (ce_pix)` aligns sprites and background tiles
    // with 0 sub-pixel or 1-pixel horizontal discrepancy, eliminating cutscene sprite/tile shifting.
    reg [7:0] sprite_color_reg;
    reg       sprite_active_reg;
    always @(posedge clk) begin
        if (reset) begin
            sprite_color_reg  <= 8'd0;
            sprite_active_reg <= 1'b0;
        end else if (ce_pix) begin
            sprite_color_reg  <= active_pixel;
            sprite_active_reg <= (active_pixel != 0) && (h_cnt < 256);
        end
    end

    assign sprite_color  = sprite_color_reg;
    assign sprite_active = sprite_active_reg;

    // ==============================================================================
    // SPRITE RENDER STATE MACHINE
    // ==============================================================================
    reg [4:0] state;
    reg signed [9:0] spr_y;
    reg [7:0] spr_x, spr_code_lsb, spr_attr, spr_flags, spr_zoom;
    reg [6:0] pix_x;
    reg [4:0] pix_y;
    reg [8:0] oam_addr;
    
    // V-total = 264 lines (0-263), matching MAME screen.set_raw spec
    // Sprite line adjust (SPRITE_Y_ADJ, 0 or 1). 2026-10-10 GPU frame diffs against MAME: Rack 'Em Up draws every sprite one scanline LATE with 0
    // (title logo, pool player cutscene and table scene improve from 1.5 to 4.2 percent mismatch to 0.7 percent with 1), while Battlantis demo
    // gameplay matches MAME to 0.15 percent with 0 and gets worse with 1. The cause of the per game difference is not found yet, so it is a
    // per game setting. V total is 264 lines (0 to 263).
    wire [8:0] eval_v_base = (v_cnt == 9'd263) ? 9'd0 : (v_cnt + 9'd1);
    wire [8:0] eval_v = (SPRITE_Y_ADJ != 0) ? ((eval_v_base == 9'd263) ? 9'd0 : (eval_v_base + 9'd1)) : eval_v_base;
    wire signed [9:0] true_y_diff_direct = $signed({1'b0, eval_v}) - spr_y;
    // Sprite Y-wrap (see the wrap_y port comment above): spr_y = 256 -
    // raw_y ranges [1,256], so a sprite meant to sit just past the bottom
    // edge naturally computes a true_y_diff_direct that only falls in the
    // visible range during vertical blanking rows (never actually drawn)
    // -- exactly the case this feature exists to handle. If the direct
    // position is off the visible 0-255 range and wrap_y is enabled, retry
    // 256px earlier (matches MAME's non-flipped dy=-256); only one of the
    // two positions can ever be on-screen at once for a given sprite.
    wire signed [9:0] true_y_diff = (wrap_y && (true_y_diff_direct < 10'sd0)) ? (true_y_diff_direct + 10'sd256) : true_y_diff_direct;

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
    // Round 15: real hardware's indirect sprite palette (see the
    // sprite_color_prom declaration/comment above) remaps the raw pixel
    // nibble through a 256-byte PROM indexed by {color, pixel}, not the raw
    // nibble itself. spr_attr[3:0] is bladestl's sprite_callback's `color`
    // (MAME: `color = 0 + (color & 0x0f)`), held stable for this whole
    // sprite's draw. The transparency check below still tests the RAW
    // cur_pixel (0 = transparent), matching MAME's own gfx decode order:
    // the indirect lookup only decides which of the sprite's 16 hardware
    // palette entries a non-transparent pixel uses, not whether it's drawn.
    wire [3:0] cur_pixel_remapped = sprite_color_prom[{spr_attr[3:0], cur_pixel}];
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
    //
    // ==========================================================================
    // SPRITE ROM CACHE (2026-09-09, ported from Battlantis's rtl/k007420.v)
    // ==========================================================================
    // This replaces the old always-resident 64KB BRAM mirror (which only
    // covered addresses < 0x10000 and left everything above it served by a
    // raw, uncached, one-request-at-a-time real-time SDRAM fetch in the
    // render FSM below). That old design had a real, confirmed bug: a large
    // or newly-demanding graphic needing many upper-range bytes within a
    // single scanline (e.g. the attract-mode "RACK'EM UP" logo's zoom-in,
    // which needs progressively more distinct tiles as it grows) would
    // consume the single real-time fetch slot for the whole scanline,
    // starving OTHER sprites (the player, the balls) of their own turn to
    // fetch -- they'd render blank/missing for however many scanlines the
    // logo's fetch demand stayed high, then reappear once it settled.
    // Confirmed directly: a Verilator capture of real attract-mode boot (no
    // coin inserted) showed the player and the rack of balls progressively
    // vanish frame-by-frame exactly while the logo was zooming in, then
    // fully reappear the frame the zoom finished.
    //
    // This tagged, on-demand 64KB cache (identical design to Battlantis's
    // own Round 196-197 sprite cache redesign, including the Round-197
    // M10K-inference fix and the 2026-09-09 miss-queue fix for simultaneous
    // multi-tile misses) fixes this the same way it was fixed there: once a
    // tile is fetched from SDRAM once, it stays cached, so repeat scanline
    // re-fetches of the SAME logo tiles (which happens every single
    // scanline under the old design, even for completely unchanged data)
    // hit the fast on-chip cache instead of re-issuing a live SDRAM
    // round-trip -- freeing up real SDRAM bandwidth for whatever few tiles
    // are genuinely new that frame, which the miss queue then lets multiple
    // of land in one pass instead of one per future re-scan.
`ifdef SPRITE_2WAY
    // ------------------------------------------------------------------------------------------------------------------------------------------
    // TWO WAY SET ASSOCIATIVE SPRITE CACHE (+define+SPRITE_2WAY=1)
    // The direct mapped cache (the other branch of this ifdef) uses the low 11 bits of the 13 bit tile number as the slot and the top 2 bits as the tag, so
    // two tiles that differ only in the top bits (the same sprite code in another bank / colour set) always fight for one slot and evict each other every
    // time both are on a line. A simulation with one slot per tile (no conflicts at all) removes nearly every missing sprite row seen in stage 2 (the wave
    // of enemies and the boss), so those conflict misses are the real cause. This version keeps the same 2048 tiles / 64 KB but as 1024 sets of 2 ways:
    // two colliding tiles can now both stay cached, and the least recently used way of a set is the one replaced. Each way is its own 32 KB M10K array
    // read in parallel; the tag compare of both ways picks which one the output takes.
    // ------------------------------------------------------------------------------------------------------------------------------------------
    localparam SETW = 10;
    localparam SETS = 1 << SETW;
    localparam TAGW = 13 - SETW;
    (* ramstyle = "M10K" *) reg [7:0] sprite_cache0 [0:SETS*32-1];   // way 0: {set, offset[4:0]}
    (* ramstyle = "M10K" *) reg [7:0] sprite_cache1 [0:SETS*32-1];   // way 1
    reg [TAGW-1:0] sprite_tag0 [0:SETS-1];
    reg [TAGW-1:0] sprite_tag1 [0:SETS-1];
    reg            sprite_valid0 [0:SETS-1];
    reg            sprite_valid1 [0:SETS-1];
    reg            sprite_lru [0:SETS-1];     // the way to replace next in this set (least recently used)

    reg [17:0] sprite_bram_addr; // set by the render FSM (state 12 below); name kept for minimal diff
    reg [7:0]  sprite_bram_dout; // the cache's tag-checked, registered output

    wire [12:0]      sprite_cache_key = sprite_bram_addr[17:5];
    wire [SETW-1:0]  c_set = sprite_cache_key[SETW-1:0];
    wire [TAGW-1:0]  c_tag = sprite_cache_key[12:SETW];
    wire c_hit0 = sprite_valid0[c_set] && (sprite_tag0[c_set] == c_tag);
    wire c_hit1 = sprite_valid1[c_set] && (sprite_tag1[c_set] == c_tag);
    wire c_hit  = c_hit0 || c_hit1;

    reg [17:0] tap_addr;
    reg        tap_valid;
    wire       tap_claims_hit = c_hit;

    localparam FILL_IDLE    = 2'd0;
    localparam FILL_REQUEST = 2'd1;
    localparam FILL_WAIT    = 2'd2;
    localparam FILL_WR2     = 2'd3;   // second byte of the word just read

    reg [1:0]       fill_state;
    reg [SETW-1:0]  fill_set;
    reg [TAGW-1:0]  fill_tag;
    reg             fill_way;
    reg [4:0]       fill_offset;
    reg [24:0]      fill_sdram_addr_reg;
    reg             fill_req_reg;
    reg [17:0]      last_checked_addr;
    reg             last_checked_valid;

    localparam MISS_Q_DEPTH = 8;
    reg [TAGW-1:0]  miss_q_tag   [0:MISS_Q_DEPTH-1];
    reg [SETW-1:0]  miss_q_set   [0:MISS_Q_DEPTH-1];
    reg             miss_q_valid [0:MISS_Q_DEPTH-1];

    reg miss_already_pending;
    integer mqi_chk;
    always @* begin
        miss_already_pending = (fill_state != FILL_IDLE && fill_set == c_set && fill_tag == c_tag);
        for (mqi_chk = 0; mqi_chk < MISS_Q_DEPTH; mqi_chk = mqi_chk + 1)
            if (miss_q_valid[mqi_chk] && miss_q_set[mqi_chk] == c_set && miss_q_tag[mqi_chk] == c_tag)
                miss_already_pending = 1'b1;
    end

    reg [2:0] miss_q_free_slot;
    reg       miss_q_has_free;
    integer mqi_free;
    always @* begin
        miss_q_free_slot = 3'd0;
        miss_q_has_free  = 1'b0;
        for (mqi_free = MISS_Q_DEPTH - 1; mqi_free >= 0; mqi_free = mqi_free - 1)
            if (!miss_q_valid[mqi_free]) begin
                miss_q_free_slot = mqi_free[2:0];
                miss_q_has_free  = 1'b1;
            end
    end

    reg [2:0] miss_q_next_slot;
    reg       miss_q_has_next;
    integer mqi_next;
    always @* begin
        miss_q_next_slot = 3'd0;
        miss_q_has_next  = 1'b0;
        for (mqi_next = MISS_Q_DEPTH - 1; mqi_next >= 0; mqi_next = mqi_next - 1)
            if (miss_q_valid[mqi_next]) begin
                miss_q_next_slot = mqi_next[2:0];
                miss_q_has_next  = 1'b1;
            end
    end

    // Which way takes a new tile of set s: an empty way first, otherwise the least recently used one. "finishing" is the fill that completes in this very
    // cycle (its way is about to become valid and most recently used, but the arrays still show the old state).
    function pick_way;
        input [SETW-1:0] s;
        input            finishing;
        reg occ0, occ1, lru_eff;
        begin
            occ0    = sprite_valid0[s] || (finishing && fill_set == s && !fill_way);
            occ1    = sprite_valid1[s] || (finishing && fill_set == s &&  fill_way);
            lru_eff = (finishing && fill_set == s) ? !fill_way : sprite_lru[s];
            if (!occ0)      pick_way = 1'b0;
            else if (!occ1) pick_way = 1'b1;
            else            pick_way = lru_eff;
        end
    endfunction

    // The first byte of every 16 bit word is written when the SDRAM read completes, the second a cycle later (see the direct mapped version).
    reg  [7:0] fill_byte1;
    wire       sprite_cache_write_en = ((fill_state == FILL_WAIT) && sprite_sdram_ready) || (fill_state == FILL_WR2);
    wire [4:0] write_off             = {fill_offset[4:1], (fill_state == FILL_WR2)};
    wire [7:0] sprite_cache_write_data = (fill_state == FILL_WR2) ? fill_byte1 : sprite_sdram_dout;
    reg  [7:0] raw0, raw1;
`ifdef SIM_PERFECT_SPRITES
    reg [7:0] perfect_rom [0:262143];
    always @(posedge clk) begin
        if (ioctl_wr && ioctl_addr >= 25'h20000 && ioctl_addr < 25'h60000)
            perfect_rom[ioctl_addr - 25'h20000] <= ioctl_dout;
        raw0 <= perfect_rom[sprite_bram_addr];
        raw1 <= 8'h00;
    end
`else
    always @(posedge clk) begin
        if (sprite_cache_write_en && !fill_way) sprite_cache0[{fill_set, write_off}] <= sprite_cache_write_data;
        if (sprite_cache_write_en &&  fill_way) sprite_cache1[{fill_set, write_off}] <= sprite_cache_write_data;
        raw0 <= sprite_cache0[{c_set, sprite_bram_addr[4:0]}];
        raw1 <= sprite_cache1[{c_set, sprite_bram_addr[4:0]}];
    end
`endif

    reg       sprite_forward_hit_d1;
    reg [7:0] sprite_forward_data_d1;
    reg       sprite_cache_hit_d1, sprite_way_d1;
    always @(posedge clk) begin
        sprite_forward_hit_d1  <= sprite_cache_write_en && (fill_set == c_set) && (fill_tag == c_tag) && (write_off == sprite_bram_addr[4:0]);
        sprite_forward_data_d1 <= sprite_cache_write_data;
`ifdef SIM_PERFECT_SPRITES
        sprite_cache_hit_d1    <= 1'b1;
        sprite_way_d1          <= 1'b0;
`else
        sprite_cache_hit_d1    <= c_hit;
        sprite_way_d1          <= c_hit1;
`endif
    end

    always @* begin
        if (sprite_forward_hit_d1)       sprite_bram_dout = sprite_forward_data_d1;
        else if (sprite_cache_hit_d1)    sprite_bram_dout = sprite_way_d1 ? raw1 : raw0;
        else                             sprite_bram_dout = 8'h00;
    end

    integer sci;
    always @(posedge clk) begin
        if (reset) begin
            fill_state <= FILL_IDLE;
            fill_req_reg <= 1'b0;
            last_checked_valid <= 1'b0;
            for (sci = 0; sci < SETS; sci = sci + 1) begin
                sprite_valid0[sci] = 1'b0;
                sprite_valid1[sci] = 1'b0;
                sprite_lru[sci]    = 1'b0;
            end
            for (sci = 0; sci < MISS_Q_DEPTH; sci = sci + 1) miss_q_valid[sci] = 1'b0;
        end else begin
            if (tap_valid && (!last_checked_valid || tap_addr != last_checked_addr)) begin
                last_checked_addr  <= tap_addr;
                last_checked_valid <= 1'b1;
                if (c_hit) begin
                    sprite_lru[c_set] <= c_hit0;           // the way just used is the most recent: the other one is replaced next
                end else if (!miss_already_pending) begin
                    if (fill_state == FILL_IDLE) begin
                        fill_set    <= c_set;
                        fill_tag    <= c_tag;
                        fill_way    <= pick_way(c_set, 1'b0);
                        fill_offset <= 5'd0;
                        fill_state  <= FILL_REQUEST;
                        if (!pick_way(c_set, 1'b0)) sprite_valid0[c_set] <= 1'b0; else sprite_valid1[c_set] <= 1'b0;
                    end else if (miss_q_has_free) begin
                        miss_q_tag[miss_q_free_slot]   <= c_tag;
                        miss_q_set[miss_q_free_slot]   <= c_set;
                        miss_q_valid[miss_q_free_slot] <= 1'b1;
                    end
                end
            end

            case (fill_state)
                FILL_IDLE: ;
                FILL_REQUEST: begin
                    fill_sdram_addr_reg <= 25'h20000 + {7'd0, fill_tag, fill_set, fill_offset};
                    fill_req_reg <= 1'b1;
                    fill_state <= FILL_WAIT;
                end
                FILL_WAIT: begin
                    if (sprite_sdram_ready) begin
                        fill_req_reg <= 1'b0;
                        fill_byte1   <= sprite_sdram_dout2;
                        fill_state   <= FILL_WR2;
                    end
                end
                FILL_WR2: begin
                    if (fill_offset == 5'd30) begin
                        if (!fill_way) begin sprite_tag0[fill_set] <= fill_tag; sprite_valid0[fill_set] <= 1'b1; end
                        else           begin sprite_tag1[fill_set] <= fill_tag; sprite_valid1[fill_set] <= 1'b1; end
                        sprite_lru[fill_set] <= !fill_way;
                        if (miss_q_has_next) begin
                            fill_set    <= miss_q_set[miss_q_next_slot];
                            fill_tag    <= miss_q_tag[miss_q_next_slot];
                            fill_way    <= pick_way(miss_q_set[miss_q_next_slot], 1'b1);
                            fill_offset <= 5'd0;
                            fill_state  <= FILL_REQUEST;
                            if (!pick_way(miss_q_set[miss_q_next_slot], 1'b1)) sprite_valid0[miss_q_set[miss_q_next_slot]] <= 1'b0;
                            else                                               sprite_valid1[miss_q_set[miss_q_next_slot]] <= 1'b0;
                            miss_q_valid[miss_q_next_slot] <= 1'b0;
                        end else begin
                            fill_state <= FILL_IDLE;
                        end
                    end else begin
                        fill_offset <= fill_offset + 5'd2;
                        fill_state  <= FILL_REQUEST;
                    end
                end
                default: fill_state <= FILL_IDLE;
            endcase
        end
    end
`else
`ifdef SIM_FULL_CACHE
    // Simulation only: one slot per tile of the whole sprite ROM (8192), so two tiles can never evict each other. If the missing sprite rows seen in
    // stage 2 (a wave of enemies plus the boss) disappear with this, the cause is conflict misses of the 2048 slot direct mapped cache.
    localparam CIDX_W = 13;
`else
    localparam CIDX_W = 11;
`endif
    localparam SPRITE_CACHE_ENTRIES = 1 << CIDX_W;
    (* ramstyle = "M10K" *) reg [7:0] sprite_cache [0:SPRITE_CACHE_ENTRIES*32-1]; // 64KB: {index, offset[4:0]}
    reg [1:0]  sprite_cache_tag [0:SPRITE_CACHE_ENTRIES-1];
    reg        sprite_cache_valid [0:SPRITE_CACHE_ENTRIES-1];

    reg [17:0] sprite_bram_addr; // set by the render FSM (state 12 below); name kept for minimal diff
    reg [7:0]  sprite_bram_dout; // the cache's tag-checked, registered output

    // calc_rom_addr's 18 bits split into a 13-bit tile index + 5-bit
    // byte-within-tile offset; the tile index splits again into an 11-bit
    // physical cache index plus a 2-bit tag.
    wire [12:0] sprite_cache_key      = sprite_bram_addr[17:5];
`ifdef SIM_FULL_CACHE
    wire [CIDX_W-1:0] sprite_cache_index    = sprite_cache_key[12:0];
    wire [1:0]  sprite_cache_tag_want = 2'b00;
`else
    wire [CIDX_W-1:0] sprite_cache_index    = sprite_cache_key[10:0];
    wire [1:0]  sprite_cache_tag_want = sprite_cache_key[12:11];
`endif

    // Miss-detection tap: latched once per genuinely-new fetch, alongside
    // sprite_bram_addr itself in state 12's non-dedup branch below.
    reg [17:0] tap_addr;
    reg        tap_valid;
    wire        tap_claims_hit  = sprite_cache_valid[sprite_cache_index] && (sprite_cache_tag[sprite_cache_index] == sprite_cache_tag_want);

    localparam FILL_IDLE    = 2'd0;
    localparam FILL_REQUEST = 2'd1;
    localparam FILL_WAIT    = 2'd2;
    localparam FILL_WR2     = 2'd3;   // second byte of the word just read

    reg [1:0]  fill_state;
    reg [CIDX_W-1:0] fill_index;
    reg [1:0]  fill_tag;
    reg [4:0]  fill_offset;
    reg [24:0] fill_sdram_addr_reg;
    reg        fill_req_reg;
    reg [17:0] last_checked_addr;
    reg        last_checked_valid;

    // A large sprite (32x32, 16 separate 8x8 sub-tiles) or a scaling-up
    // graphic like the title logo can generate several simultaneous cache
    // misses, but the fill engine below only ever tracks ONE outstanding
    // fill. Misses that arrive while a fill is already in flight are queued
    // here instead of dropped, and serviced back-to-back once the current
    // fill completes.
    localparam MISS_Q_DEPTH = 8;
    reg [1:0]  miss_q_tag   [0:MISS_Q_DEPTH-1];
    reg [CIDX_W-1:0] miss_q_idx   [0:MISS_Q_DEPTH-1];
    reg        miss_q_valid [0:MISS_Q_DEPTH-1];

    // Is this exact {index,tag} already being filled or already queued?
    reg miss_already_pending;
    integer mqi_chk;
    always @* begin
        miss_already_pending = (fill_state != FILL_IDLE &&
                                 fill_index == sprite_cache_index &&
                                 fill_tag   == sprite_cache_tag_want);
        for (mqi_chk = 0; mqi_chk < MISS_Q_DEPTH; mqi_chk = mqi_chk + 1)
            if (miss_q_valid[mqi_chk] &&
                miss_q_idx[mqi_chk] == sprite_cache_index &&
                miss_q_tag[mqi_chk] == sprite_cache_tag_want)
                miss_already_pending = 1'b1;
    end

    // First empty queue slot, for enqueueing a new miss.
    reg [2:0] miss_q_free_slot;
    reg       miss_q_has_free;
    integer mqi_free;
    always @* begin
        miss_q_free_slot = 3'd0;
        miss_q_has_free  = 1'b0;
        for (mqi_free = MISS_Q_DEPTH - 1; mqi_free >= 0; mqi_free = mqi_free - 1)
            if (!miss_q_valid[mqi_free]) begin
                miss_q_free_slot = mqi_free[2:0];
                miss_q_has_free  = 1'b1;
            end
    end

    // First occupied queue slot, for dequeueing once the current fill ends.
    reg [2:0] miss_q_next_slot;
    reg       miss_q_has_next;
    integer mqi_next;
    always @* begin
        miss_q_next_slot = 3'd0;
        miss_q_has_next  = 1'b0;
        for (mqi_next = MISS_Q_DEPTH - 1; mqi_next >= 0; mqi_next = mqi_next - 1)
            if (miss_q_valid[mqi_next]) begin
                miss_q_next_slot = mqi_next[2:0];
                miss_q_has_next  = 1'b1;
            end
    end

    // Canonical Quartus simple-dual-port-RAM template: the array is read
    // UNCONDITIONALLY every cycle into its own dedicated output register,
    // with nothing else sharing that always block. Hit/forward/miss
    // decision logic lives in a separate combinational mux stage below.
    // A fill reads the sprite ROM one 16 bit word (two bytes) at a time: the SDRAM controller already returns both bytes of the word, the arbiter now
    // hands the second one out too (sprite_sdram_dout2), so a 32 byte tile takes 16 reads instead of 32. fill_offset always counts even addresses; the
    // first byte is written in FILL_WAIT when the read completes, the second one a cycle later in FILL_WR2.
    reg  [7:0]  fill_byte1;
    wire        sprite_cache_write_en   = ((fill_state == FILL_WAIT) && sprite_sdram_ready) || (fill_state == FILL_WR2);
    wire [CIDX_W+4:0] sprite_cache_write_addr = {fill_index, fill_offset[4:1], (fill_state == FILL_WR2)};
    wire [7:0]  sprite_cache_write_data = (fill_state == FILL_WR2) ? fill_byte1 : sprite_sdram_dout;
    wire [CIDX_W+4:0] sprite_cache_read_addr  = {sprite_cache_index, sprite_bram_addr[4:0]};
    reg  [7:0]  sprite_cache_raw_dout;
`ifdef SIM_PERFECT_SPRITES
    // Simulation only (+define+SIM_PERFECT_SPRITES=1): the whole sprite ROM is kept on chip and every read hits, so the picture does not depend on
    // SDRAM timing at all. This is the ground truth the lateness tests compare the real cache against.
    reg [7:0] perfect_rom [0:262143];
    always @(posedge clk) begin
        if (ioctl_wr && ioctl_addr >= 25'h20000 && ioctl_addr < 25'h60000)
            perfect_rom[ioctl_addr - 25'h20000] <= ioctl_dout;
        sprite_cache_raw_dout <= perfect_rom[sprite_bram_addr];
    end
`else
    always @(posedge clk) begin
        if (sprite_cache_write_en)
            sprite_cache[sprite_cache_write_addr] <= sprite_cache_write_data;
        sprite_cache_raw_dout <= sprite_cache[sprite_cache_read_addr];
    end
`endif

    // Registered qualifiers for the mux below -- each updates on the same
    // edge sprite_cache_raw_dout does.
    reg        sprite_forward_hit_d1;
    reg [7:0]  sprite_forward_data_d1;
    reg        sprite_cache_hit_d1;
    always @(posedge clk) begin
        sprite_forward_hit_d1  <= sprite_cache_write_en && (sprite_cache_write_addr == sprite_cache_read_addr) &&
                                   (fill_tag == sprite_cache_tag_want);
        sprite_forward_data_d1 <= sprite_cache_write_data;
`ifdef SIM_PERFECT_SPRITES
        sprite_cache_hit_d1    <= 1'b1;
`else
        sprite_cache_hit_d1    <= sprite_cache_valid[sprite_cache_index] && (sprite_cache_tag[sprite_cache_index] == sprite_cache_tag_want);
`endif
    end

    always @* begin
        if (sprite_forward_hit_d1)
            sprite_bram_dout = sprite_forward_data_d1;
        else if (sprite_cache_hit_d1)
            sprite_bram_dout = sprite_cache_raw_dout;
        else
            sprite_bram_dout = 8'h00; // safe blank on miss -- self-corrects once the async fill below lands
    end

    integer sci;
    always @(posedge clk) begin
        if (reset) begin
            fill_state <= FILL_IDLE;
            fill_req_reg <= 1'b0;
            last_checked_valid <= 1'b0;
            for (sci = 0; sci < SPRITE_CACHE_ENTRIES; sci = sci + 1) sprite_cache_valid[sci] = 1'b0;
            for (sci = 0; sci < MISS_Q_DEPTH; sci = sci + 1) miss_q_valid[sci] = 1'b0;
        end else begin
            if (tap_valid && (!last_checked_valid || tap_addr != last_checked_addr)) begin
                last_checked_addr  <= tap_addr;
                last_checked_valid <= 1'b1;
                if (!tap_claims_hit && !miss_already_pending) begin
                    if (fill_state == FILL_IDLE) begin
                        fill_index  <= sprite_cache_index;
                        fill_tag    <= sprite_cache_tag_want;
                        fill_offset <= 5'd0;
                        fill_state  <= FILL_REQUEST;
                        sprite_cache_valid[sprite_cache_index] <= 1'b0;
                    end else if (miss_q_has_free) begin
                        miss_q_tag[miss_q_free_slot]   <= sprite_cache_tag_want;
                        miss_q_idx[miss_q_free_slot]   <= sprite_cache_index;
                        miss_q_valid[miss_q_free_slot] <= 1'b1;
                    end
                end
            end

            case (fill_state)
                FILL_IDLE: ; // waiting for the trigger above
                FILL_REQUEST: begin
`ifdef SIM_FULL_CACHE
                    fill_sdram_addr_reg <= 25'h20000 + {7'd0, fill_index, fill_offset};
`else
                    fill_sdram_addr_reg <= 25'h20000 + {7'd0, fill_tag, fill_index, fill_offset};
`endif
                    fill_req_reg <= 1'b1;
                    fill_state <= FILL_WAIT;
                end
                FILL_WAIT: begin
                    if (sprite_sdram_ready) begin
                        fill_req_reg <= 1'b0;
                        fill_byte1   <= sprite_sdram_dout2;
                        fill_state   <= FILL_WR2;
                    end
                end
                FILL_WR2: begin
                    if (fill_offset == 5'd30) begin
                        sprite_cache_tag[fill_index]   <= fill_tag;
                        sprite_cache_valid[fill_index] <= 1'b1;
                        if (miss_q_has_next) begin
                            fill_index  <= miss_q_idx[miss_q_next_slot];
                            fill_tag    <= miss_q_tag[miss_q_next_slot];
                            fill_offset <= 5'd0;
                            fill_state  <= FILL_REQUEST;
                            sprite_cache_valid[miss_q_idx[miss_q_next_slot]] <= 1'b0;
                            miss_q_valid[miss_q_next_slot] <= 1'b0;
                        end else begin
                            fill_state <= FILL_IDLE;
                        end
                    end else begin
                        fill_offset <= fill_offset + 5'd2;
                        fill_state  <= FILL_REQUEST;
                    end
                end
                default: fill_state <= FILL_IDLE;
            endcase
        end
    end

`endif

    // Latch 25'h20003 byte on the write-path instead of reading it with an extra
    // BRAM port (which broke simple dual-port inference and forced Quartus to
    // implement the 512Kb array using general logic/registers, hanging the
    // fitter for a very long time).
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
    reg sprite_sdram_req_reg;

    always @(posedge clk) begin
        last_h_cnt_0 <= (h_cnt == 0);
        draw_we <= 0;
        
        if (reset) begin
            state <= 16;
            sdram_ready_latched <= 1'b0;
            sprite_sdram_req_reg <= 1'b0;
            sprite_idx <= 7'd63;
            diag_req_count <= 0;
            diag_ready_count <= 0;
            sdram_timeout <= 0;
            raw_y <= 8'd0;
            last_byte_valid <= 1'b0; // no byte latched yet, forces first fetch
        end else if (h_cnt == 0 && !last_h_cnt_0) begin
            state <= 0;
            sprite_idx <= 7'd63;
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
                    // Round 53: the raw_y != 0 test is gone. MAME skips a sprite only when its zoom is 0; a sprite whose Y byte is 0 sits at
                    // oy = 256, i.e. just below the bottom edge, and with the Y wrap enabled (K007342 register 2 bit 7, always on in Blades
                    // of Steel) its copy at oy - 256 = 0 covers the first lines of the picture. The title logo letters and every sprite
                    // crossing that edge disappeared (verified against a MAME algorithm reference over 215 states). The wrap arithmetic in
                    // true_y_diff already handles spr_y = 256.
                    if (zoom_raw != 10'd0 && sprite_y_in_bounds) begin
                        last_byte_valid <= 1'b0; // new sprite: invalidate cache, force a real fetch at pix_x=0
                        state <= 12; // Active scanline: proceed to rendering
                    end else begin
                        sprite_idx <= sprite_idx - 1'd1;
                        state <= 1; // Out of bounds or disabled: skip cleanly
                    end
                end
                
                12: begin
                    // 2026-09-09: sprite_bram_addr now indexes the tagged
                    // SPRITE ROM CACHE (see its own section above) across the
                    // WHOLE address range, not just a fast-path/SDRAM-path
                    // branch split on a fixed 0x10000 boundary -- a MISS
                    // returns a safe blank (0x00) for this cycle while the
                    // cache's own fill state machine races to load the real
                    // data for next time (ported from Battlantis's own
                    // Round 196-197 redesign; see that file's identical
                    // comment for the full history).
                    if (last_byte_valid && calc_rom_addr == last_byte_addr) begin
                        // Same ROM byte as already latched (zoom held us on the same source
                        // pixel pair, or we're revisiting the same nibble) — no fetch needed.
                        state <= 15;
                    end else begin
                        sprite_bram_addr <= calc_rom_addr;
                        last_byte_addr <= calc_rom_addr;
                        last_byte_valid <= 1'b1;
                        tap_addr <= calc_rom_addr;
                        tap_valid <= 1'b1;
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
                    sprite_sdram_req_reg <= 1'b0;
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
                    // Round 53: sprite_x_past_edge is true for the first pixel BEYOND the sprite (pix_x == width); that pixel used to be
                    // drawn too (with the clamped last texture column), so every sprite was one column wider than MAME's. On the
                    // fight screen the dark 33rd column of each 32x32 sprite showed as thin black vertical lines next to the players.
                    if (!sprite_x_past_edge && cur_pixel != 4'd0 && cur_draw_x >= 10'sd0 && cur_draw_x < 10'sd256) begin
                        // Normal sprite pixel.
                        // Since we scan from sprite 63 down to 0, later iterations
                        // (lower index) have higher priority. We ALWAYS overwrite
                        // whatever is in the line buffer (background or lower-priority sprite).
                        draw_addr <= cur_draw_x[7:0];
                        // MAME's sprite_callback zeroes the runtime `color` param, but
                        // GFXDECODE_ENTRY("sprites", ..., 4*16, 1) hardcodes color_base=64
                        // (colors 64-79 = palette bank 4) for Battlantis specifically.
                        // sprite_color_base (Round 13) makes this per-game instead of a
                        // second hardcoded constant -- see its own port comment above.
                        // Round 15: the low nibble is now the real PROM-remapped pixel
                        // (cur_pixel_remapped), not the raw ROM nibble -- see the
                        // sprite_color_prom declaration above for the full reasoning.
                        draw_data <= {sprite_color_base, USE_PROM ? cur_pixel_remapped : cur_pixel};
                        draw_we   <= 1;
                    end
                    
                    pix_x <= pix_x + 1'd1;
                    if (sprite_x_past_edge || pix_x == 7'd127 || cur_draw_x >= 10'sd256) begin
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

`ifdef SIM_BUDGET
    // Simulation only: does the sprite engine finish all 64 sprites inside one scanline? The line restarts at h_cnt == 0 (state <= 0, sprite_idx <= 63);
    // when that happens while state is not 16 (idle/done) the sprites that had not been reached yet (indices sprite_idx down to 0, the highest priority
    // ones) are missing from that line. One summary line per frame: lines that ran out of time, the most sprites lost on one line, and the sum.
    integer bud_frame = 0;
    integer bud_over = 0, bud_maxdrop = 0, bud_sumdrop = 0, bud_maxclk = 0;
    integer bud_clk = 0, bud_peak = 0;
    reg bud_seen = 1'b0;
    reg bud_vs_d = 1'b0;
    always @(posedge clk) begin
        if (!reset) begin
            bud_vs_d <= (h_cnt == 0 && v_cnt == 0);
            if (h_cnt == 0 && !last_h_cnt_0) begin
                if (state != 16 && !sprite_idx[6] && v_cnt >= 16 && v_cnt < 240) begin
                    bud_over    = bud_over + 1;
                    bud_sumdrop = bud_sumdrop + sprite_idx + 1;
                    if (sprite_idx + 1 > bud_maxdrop) bud_maxdrop = sprite_idx + 1;
                end
                bud_clk <= 0;
                bud_seen <= 1'b0;
            end else begin
                bud_clk <= bud_clk + 1;
                if (state == 16 && !bud_seen && v_cnt >= 16 && v_cnt < 240) begin
                    bud_seen <= 1'b1;
                    if (bud_clk > bud_peak) bud_peak = bud_clk;
                end
                if (state != 16 && bud_clk > bud_maxclk) bud_maxclk = bud_clk;
            end
            if (h_cnt == 0 && v_cnt == 0 && !bud_vs_d) begin
                $display("BUD f=%0d over=%0d maxdrop=%0d sumdrop=%0d peakclk=%0d", bud_frame, bud_over, bud_maxdrop, bud_sumdrop, bud_peak);
                bud_frame = bud_frame + 1; bud_over = 0; bud_maxdrop = 0; bud_sumdrop = 0; bud_maxclk = 0; bud_peak = 0;
            end
        end
    end
`endif

`ifdef SIM_TRACE
    // Simulation only: the ordered stream of sprite tile references (13 bit tile index = calc_rom_addr[17:5]) the render engine makes, as the cache
    // sees it (one entry per new fetch address, consecutive repeats of the same tile dropped), written to a text file inside two frame windows given
    // with +trace_lo1/+trace_hi1/+trace_lo2/+trace_hi2. Used to compare cache organisations offline (direct mapped, hashed index, set associative).
    integer trc_fd = 0, trc_frame = 0, trc_lo1 = 0, trc_hi1 = 0, trc_lo2 = 0, trc_hi2 = 0;
    reg trc_vs_d = 1'b0;
    reg [12:0] trc_last = 13'h1FFF;
    wire trc_on = (trc_frame >= trc_lo1 && trc_frame < trc_hi1) || (trc_frame >= trc_lo2 && trc_frame < trc_hi2);
    initial begin
        if (!$value$plusargs("trace_lo1=%d", trc_lo1)) trc_lo1 = 0;
        if (!$value$plusargs("trace_hi1=%d", trc_hi1)) trc_hi1 = 0;
        if (!$value$plusargs("trace_lo2=%d", trc_lo2)) trc_lo2 = 0;
        if (!$value$plusargs("trace_hi2=%d", trc_hi2)) trc_hi2 = 0;
        trc_fd = $fopen("/dev/shm/pf/tiletrace.txt", "w");
    end
    always @(posedge clk) begin
        if (!reset) begin
            trc_vs_d <= (h_cnt == 0 && v_cnt == 0);
            if (h_cnt == 0 && v_cnt == 0 && !trc_vs_d) begin
                trc_frame = trc_frame + 1;
                if (trc_on) $fwrite(trc_fd, "F%0d\n", trc_frame);
            end
            if (trc_on && tap_valid && (!last_checked_valid || tap_addr != last_checked_addr) && tap_addr[17:5] != trc_last) begin
                $fwrite(trc_fd, "%04h\n", {3'd0, tap_addr[17:5]} );
                trc_last <= tap_addr[17:5];
            end
        end
    end
`endif

endmodule