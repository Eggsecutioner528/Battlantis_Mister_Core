module k007342 #(
    parameter OVERSCAN_MASK = 0   // 1: Battlantis style priority mask over the overscan/frame area (hides sprites there); 0 off (Blades of Steel, Rack 'Em Up)
) (
    input  wire        clk,
    input  wire        reset,

    // 2026-08-28: gates whether Layer 1 composites into the video output at
    // all. See the `layer1_wins` comment further down for why this exists
    // -- Battlantis.sv derives this from the loaded ROM's own content
    // (Layer 1 VRAM is real tile data for some games on this hardware,
    // pure CPU scratch RAM for others, and there's no way to tell from the
    // chip's own registers alone).
    input  wire        layer1_enable,

    // 2026-09-12 (Round 12, Blades of Steel bring-up): selects between two
    // real, different compositing behaviors this chip supports depending on
    // how a specific game's own screen_update() sequences its tilemap/
    // sprite draws:
    //  0 (default) -- Battlantis/Rack 'Em Up's own behavior, confirmed from
    //    battlnts_mame.cpp: layer1 (MAME tilemap 1) is an optional overlay
    //    on top of layer0 (MAME tilemap 0), and layer0's own attr[7] alone
    //    decides whether it renders above or below sprites. This is the
    //    ORIGINAL, already-proven formula, completely untouched below when
    //    this port is 0 -- zero behavior change for either already-working,
    //    already-deployed game.
    //  1 -- Blades of Steel's own behavior, confirmed directly from
    //    bladestl_mame.cpp's screen_update(): `tilemap_draw(1,OPAQUE)`
    //    (layer1 as the opaque BASE) -> `sprites_draw()` -> `tilemap_draw
    //    (1,cat1,OPAQUE)` (layer1's own priority tiles redrawn on top of
    //    sprites) -> `tilemap_draw(0,cat0)` -> `tilemap_draw(0,cat1)`
    //    (layer0, MAME tilemap 0, always drawn LAST and unconditionally on
    //    top of everything, transparent-on-zero). So here layer0 is the
    //    overlay (unconditionally above sprites whenever non-transparent)
    //    and layer1's own attr[7] decides over/under sprites for the base
    //    layer specifically -- the reverse roles from Battlantis, and a
    //    genuinely different rule (not just "which layer is enabled"),
    //    which is why this needs its own explicit mode select rather than
    //    trying to infer it from layer1_enable alone.
    input  wire        alt_priority_mode,

    // tile_code_layout: how the tile ROM address is built from the colour/attribute
    // byte. This is the game's own MAME `tile_callback`, so it differs per game:
    //  0 -- Battlantis / Rack 'Em Up:  code |= ((attr & 0x0f) << 9) | ((attr & 0x40) << 2)
    //       => tile code = {attr[3:0], attr[6], tile[7:0]}   (the original, proven layout)
    //  1 -- Blades of Steel:           code |= ((attr & 0x0f) << 8) | ((attr & 0x40) << 6)
    //       => tile code = {attr[6], attr[3:0], tile[7:0]}   (bladestl_mame.cpp tile_callback)
    // The two agree only while attr[6] == 0 and attr[3:0] == 0 (or both bits equal in
    // the swapped positions), which is why tiles with attr == 0 (the tile-0x10 filler,
    // for one) looked right while every banked tile (title art, crowd, borders) did not.
    input  wire        tile_code_layout,

    // CPU Interface (16KB memory space to include vreg at 0x2600)
    input  wire [13:0] cpu_addr,
    input  wire [7:0]  cpu_din,
    output wire [7:0]  cpu_dout,
    input  wire        cpu_we,
    input  wire        cpu_re,
    input  wire        vram_bank,

    // Scroll RAM Interface
    input  wire [8:0]  scroll_addr,
    input  wire [7:0]  scroll_din,
    output wire [7:0]  scroll_dout,
    input  wire        scroll_we,

    // Video Output (Pixel Stream)
    input  wire        ce_pix,
    input  wire [8:0]  h_cnt,
    input  wire [8:0]  v_cnt,
    
    // IOCTL ROM Download (for Tile Graphics)
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    
    // Output Pixels
    output reg  [7:0]  pixel_color, // color index 0-15 (bit7 always 0 -- see pixel_priority)
    output reg         pixel_priority, // layer0_priority (attr[7]) for the sprite/bg compositing
                                        // mux ONLY -- kept separate from pixel_color so it can
                                        // never affect the palette RAM address (see the fix note
                                        // at this reg's assignment below)

    // Interrupts
    output reg         vblank,
    output reg         int_enabled,
    output reg         irq,
    input  wire        irq_ack,

    // Real K007342 register 0x02 bit 7 (see the sprite_wrap_y assignment
    // below for the full reasoning) -- tells the sprite chip to also draw
    // sprites a second time, offset a full screen height away, so they
    // don't pop in/out abruptly at the top/bottom scroll edge.
    output reg         sprite_wrap_y,

    // Task #17, revived 2026-08-29 for real cocktail-cabinet use: real
    // K007342 register 0x00 (address 0x2600) bit 4 is the chip's own
    // dynamic screen-flip request -- Battlantis's own game code writes
    // this bit when it detects Cocktail cabinet mode (DSW2 cab_opt) and
    // it's Player 2's turn, so the CRT physically flips 180 degrees to
    // face whichever player is currently up, without any manual OSD
    // interaction. Previously dropped (2026-08-24) as unneeded for an
    // upright-only setup; revived now that real cocktail-cabinet
    // deployment is a real goal. Exposed here as a combinational read of
    // `regs[0]` (already latched below, same write path as int_enabled)
    // for Battlantis.sv to combine with the existing manual "Flip
    // Monitor" OSD toggle.
    output wire        flip_screen_req,

    // Task #18 (2026-08-16, retired): K007342 register 0x02's "32 columns"
    // per-column scroll mode was checked via a sticky diagnostic across
    // several full sessions of real gameplay and never once selected --
    // closed as not utilized by this game's program, no longer implemented
    // or tracked here.

    // Shadow SDRAM verification (2026-08-13, Stage 1 of the tile-ROM/SDRAM
    // migration plan): Port 2 was reserved for k007342 from the start of the
    // project but has been hardwired off all session (tile_sdram_req=1'b0
    // in Battlantis.sv). This taps two values the real BRAM tile-fetch
    // pipeline already computes every Layer-0 byte-0 fetch (vid_tile_addr,
    // vid_tile_dout) with zero new address-computation logic in the
    // timing-critical fetch state machine, then independently re-reads the
    // SAME address via SDRAM Port 2 and compares -- entirely in a separate,
    // slower state machine with no influence on the real-time tile-fetch
    // timing (does not gate, stall, or feed back into it in either
    // direction). Purpose: prove whether SDRAM can serve tile ROM data
    // reliably BEFORE ever switching real rendering over to it or touching
    // the BRAM array's size, following this whole session's established
    // "validate first via a passive tap, never risk the live render path"
    // practice (this is exactly what caught Test 185's regression -- this
    // design deliberately avoids that failure class by keeping the new
    // logic's only contact with the real pipeline a single passive read of
    // already-computed values, not new arithmetic near the display path).
    output wire         shadow_sdram_req,
    output wire [24:0]  shadow_sdram_addr,
    input  wire [7:0]   shadow_sdram_dout,
    input  wire         shadow_sdram_ready,
    output wire [17:0]  shadow_verify_addr_out,
    output wire [7:0]   shadow_verify_expected_out,
    output wire [7:0]   shadow_verify_actual_out,
    output wire         shadow_verify_match_out,
    output wire [15:0]  shadow_verify_pass_count_out,
    output wire [15:0]  shadow_verify_fail_count_out,
    output wire [15:0]  shadow_max_wait_cycles_out,
    output wire         shadow_currently_stuck_out,

    // Passive tile-cache hit-rate simulator (2026-08-14, Stage 2 scoping --
    // see the localparam comment below for the full design rationale).
    output wire [23:0]  cache_sim_hit_count_out,
    output wire [23:0]  cache_sim_miss_count_out,

    // Port 3 busy signal (2026-08-14, Test 221): a corrupted plain SDRAM
    // read just glitches one pixel for one frame, but a corrupted FILL
    // persists in the cache until evicted -- Test 220 confirmed real
    // hardware sees ~29-31% per-byte corruption on fills specifically
    // because they're issued concurrently with live Port 3 sprite traffic
    // (the same pre-existing concurrent-access limitation Tests 204-215
    // characterized), while Port 2 ALONE was already proven 100% reliable
    // (Test 207, 0/160 frames failed with Port 3 isolated). Rather than
    // trying to statistically detect corruption after the fact (a double-
    // read scheme was considered and rejected on Gemini's advice: Port 2
    // and Port 3 are both synchronous to the same clock, so two back-to-
    // back reads of the same byte would likely hit contention at the same
    // relative phase both times and could reliably agree on the SAME wrong
    // byte, defeating the check), this input lets the fill state machine
    // simply wait for a genuinely idle moment before issuing each byte
    // request -- reusing Test 207's already-proven-reliable condition
    // directly instead of a new, unverified statistical assumption. Wired
    // to sdram_arbiter's new p3_active output (Battlantis.sv), NOT the raw
    // p3_mux_req request line -- caught in Gemini review before this was
    // ever deployed: k007420 only pulses sprite_sdram_req for a single
    // cycle, so checking the raw request line would see "idle" while the
    // arbiter still has that request latched and in-flight (dispatch/wait/
    // complete/cooldown can take many more cycles), letting a fill slip in
    // during what's actually still an active Port 3 transaction and
    // recreating the exact contention this exists to avoid. p3_active
    // stays high for the request's entire lifetime (mirrors the arbiter's
    // own latched_p3_req, cleared only at cooldown), giving genuine
    // exclusivity.
    input  wire          port3_busy
);

    // ==============================================================================
    // TILE GRAPHICS ROM (256 KB) -- NO LONGER a local BRAM copy (2026-08-14,
    // Test 222, real cutover). The full-array `tile_rom` this comment used to
    // describe is gone; background tile data now lives in the 64KB tile_cache
    // further down this file, backed by SDRAM on a miss. No local write-
    // capture is needed here: Battlantis.sv's Port 0 IOCTL wiring
    // (`.p0_addr(ioctl_download ? ioctl_addr : ...)`, `.p0_din(... ioctl_dout
    // ...)`, `.p0_req(... ioctl_wr ...)`) already writes every downloaded
    // byte -- tile ROM included -- into SDRAM directly during boot, so the
    // cache's fill mechanism finds real data there with no separate capture
    // path required.
    // ==============================================================================
    // VIDEO RAM  (16 KB dual-port BRAM — 2 banks of 8 KB, selected by vram_bank)
    // ==============================================================================
    // Bank 0 layout (vram_bank=0, addr 0x0000–0x1FFF):
    //   0x0000–0x07FF : Layer 0 Attribute bytes (colour + MSB tile index)
    //   0x0800–0x0FFF : Layer 0 Tile LSB bytes  (low 8 bits of tile code)
    //   0x1000–0x17FF : Layer 1 Attribute bytes
    //   0x1800–0x1FFF : Layer 1 Tile LSB bytes
    // Bank 1 layout (vram_bank=1): same structure, used by the CPU during gameplay.
    //
    // The CPU writes through the vram_bank register in K007342 reg 0x2600.
    // The video fetch state machine always reads from the bank currently “held”
    // (vram_bank output from the CPU side) so it never tears mid-frame.
    //
    // SPECIAL CASE — Register region 0x2600–0x2607:
    //   These addresses overlap VRAM but map to the K007342’s internal control
    //   registers (scroll, INT enable, etc.). Writes go to `regs[]`, not VRAM.
    //   Reads return VRAM[0]–[7] because the address decoder is incomplete
    //   (real hardware behaviour confirmed in MAME).
    // ==============================================================================
`ifdef SIM_SPRITE_SDRAM_PROBE
    // TEMP (2026-08-30): cross-check for the k007420.v investigation --
    // does THIS module's own ioctl_wr port also see zero pulses across the
    // whole download? k007342 doesn't use ioctl_wr for anything (SDRAM/
    // Port 0 does the tile ROM download directly, see the big comment
    // above), so this is purely diagnostic and has no effect on real
    // behavior either way.
    reg [31:0] local_k342_total_wr_count = 32'd0;
    always @(posedge clk) begin
        if (ioctl_wr) begin
            local_k342_total_wr_count <= local_k342_total_wr_count + 32'd1;
        end
    end
`endif

    (* ramstyle = "M10K" *) reg [7:0] vram [0:8191];
    // On real Cyclone V silicon, M10K block RAM has no guaranteed all-zero power-up content.
    // Explicit all-zero initialization gives Quartus a clean initial state.
    initial begin
        integer vram_init_i;
        for (vram_init_i = 0; vram_init_i < 4096; vram_init_i = vram_init_i + 1) vram[vram_init_i] = 8'h00;
        for (vram_init_i = 4096; vram_init_i < 8192; vram_init_i = vram_init_i + 1) vram[vram_init_i] = 8'h00;
    end

    // Port A: CPU read/write
    reg [7:0] vram_dout;
    // Remap register region (0x2600-0x2607) to low VRAM addresses for the read path
    wire [12:0] cpu_vram_addr = (cpu_addr >= 14'h2600 && cpu_addr <= 14'h2607) ? {10'd0, cpu_addr[2:0]} : cpu_addr[12:0];
    
    always @(posedge clk) begin
        if (cpu_we && cpu_addr < 14'h2000) begin
            vram[cpu_addr[12:0]] <= cpu_din;
        end
        vram_dout <= vram[cpu_vram_addr];
    end
    reg [7:0] regs [0:7]; // K007342 control registers (write-only from CPU side)
    // K007342 registers are write-only. Reading 0x2600-0x2607 returns VRAM[0]-VRAM[7] due to incomplete address decoding.
    assign cpu_dout = vram_dout;
    // Task #17 revival: regs[0] bit 4 is the real chip's dynamic
    // screen-flip request (see the flip_screen_req port comment above).
    // regs[] has no explicit reset value (matches int_enabled's own
    // regs[0]-derived write path immediately below), but Cyclone V's
    // ALM-based flip-flops -- unlike M10K block RAM -- do have a
    // documented, guaranteed power-on-reset state of 0 with no explicit
    // reset needed, so this doesn't carry the same uninitialized-content
    // risk task #83 found for actual block RAM.
    assign flip_screen_req = regs[0][4];

    // ==============================================================================
    // PER-ROW SCROLL RAM  (512 bytes)
    // ==============================================================================
    // When the K007342 row-scroll mode is active (regs[2] bits [4:2] == 3'b101),
    // each scanline can have its own independent horizontal scroll offset for Layer 0.
    // The CPU writes a 9-bit X offset per scanline as two consecutive bytes:
    //   scroll_ram[row * 2 + 0] = X[7:0]  (LSB)
    //   scroll_ram[row * 2 + 1] = X[8]    (MSB, only bit 0 used)
    //
    // TO DISABLE ROW SCROLL: clear bits [4:2] of regs[2] (write 0x00 to 0x2602).
    // TO FORCE FLAT SCROLL:  clear `use_row_scroll` below or tie it to 1’b0.
    // ==============================================================================
    reg [7:0] scroll_ram [0:511];
    initial begin
        integer i;
        for (i = 0; i < 512; i = i + 1) scroll_ram[i] = 8'h00;
    end
    reg [7:0] scroll_dout_reg;
    always @(posedge clk) begin
        if (scroll_we) begin
            scroll_ram[scroll_addr] <= scroll_din;
        end
        scroll_dout_reg <= scroll_ram[scroll_addr];
    end
    assign scroll_dout = scroll_dout_reg;

    // ==============================================================================
    // TILE FETCH STATE MACHINE
    // ==============================================================================
    // The system clock (clk_sys) runs at 48 MHz. Each pixel clock (ce_pix) is
    // asserted once every 8 clk_sys cycles. Each tile is 8 pixels wide, so we
    // have exactly 64 clk_sys cycles per tile — enough to perform a multi-step
    // BRAM pipeline fetch (VRAM read → tile ROM read → pixel shift load).
    //
    // `fetch_state` combines the pixel’s tile-column offset (h_cnt[2:0], 0–7)
    // with the sub-pixel clock counter (ce_div, 0–7) to produce a 6-bit phase
    // counter that cycles 0–63 once per tile column.
    //
    // TIMING OVERVIEW (states used in the case block below):
    //   States  0–17 : Layer 0 — VRAM read (attr + tile code) then tile ROM read (4 bytes)
    //   States 18–35 : Layer 1 — same sequence
    //   States 36–63 : Idle (spare cycles; fetch is done before next tile column)
    // ==============================================================================
    reg [2:0] ce_div;
    always @(posedge clk) begin
        if (ce_pix) ce_div <= 0;       // reset sub-pixel counter at each pixel clock
        else ce_div <= ce_div + 1'd1;
    end
    
    // 6-bit phase within each 8-pixel tile column
    wire [5:0] fetch_state = {h_cnt[2:0], ce_div};
    
    // Fetch addresses are calculated ONE TILE AHEAD of the current display position
    // (next_h = current_h + 8 pixels) so the pixel shift register is loaded and
    // ready exactly when the tile starts rendering. Without the look-ahead, the
    // first tile of each row would show stale data from the previous frame.
    wire [8:0] next_h = (h_cnt >= 9'd376) ? (h_cnt - 9'd376) : (h_cnt + 9'd8);
    // 2026-08-16: wrap point matches Battlantis.sv's v_cnt counter, which now
    // wraps at 263 (V-total = 264, fixed to match MAME's real raster -- was
    // 261/V-total=262). Missed in the original V-total fix and left stale.
    // TEMPORARY DIAGNOSTIC REVERT (2026-08-16, boot-hang bisection) -- back
    // to 261, matching Battlantis.sv's own temporarily-reverted V-total.
    // Round 50: tile rows are fetched one tile AHEAD horizontally (next_h = h_cnt + 8), so they belong to the
    // CURRENT scanline, except while prefetching across the line wrap (h_cnt >= 376 fetches the first tile of
    // the NEXT line). The old `v_cnt + 1` for every fetch put every tile but the first one scanline early
    // (measured against MAME: tile layer dv = -1, sprites dv = 0). 263 is the last line (V total 264).
    wire [8:0] v_cnt_incr = (v_cnt == 9'd263) ? 9'd0 : (v_cnt + 9'd1);
    wire [8:0] next_v = (h_cnt >= 9'd376) ? v_cnt_incr : v_cnt;
    // Round 53: only tile columns that can reach the screen may touch the tile cache. The fetch sequencer walks all 48
    // column slots of the 384 clock line, so 15 of them per line (next_h >= 264) belong to horizontal blanking and are never
    // displayed -- but their keys went through the miss/fill logic like any other. On the Blades fight screen (a 28 x 32 tile
    // picture in layer 1 built from 856 distinct lines, plus 214 lines that only blanking slots ask for) those lookups
    // evicted visible lines from the 2-way sets every frame and left blank 8x8 cells. next_h < 264 keeps columns 0..32: column 32
    // starts at pixel 256, where it is still needed as the second tile of the last pixel group whenever the fine scroll is not 0.
    wire tap_col_visible = (next_h < 9'd264);
    
    // Layer 1 scroll: simple global X/Y offset applied to the tilemap grid.
    wire [8:0] layer1_scrolled_v = next_v + layer1_scroll_y;
    wire [8:0] layer1_scrolled_h = next_h + layer1_scroll_x;
    wire [5:0] layer1_tile_x = layer1_scrolled_h[8:3]; // which tile column (divide by 8)
    wire [4:0] layer1_tile_y = layer1_scrolled_v[7:3]; // which tile row
    
    // Layer 0 scroll: supports full screen, per-scanline row scroll (0x14), and 32-column vertical scroll (0x0C).
    wire use_row_scroll = ((regs[2] & 8'h1C) == 8'h14); // Mode 0x14: 256 rows horizontal scroll
    wire use_col_scroll = ((regs[2] & 8'h1C) == 8'h0C); // Mode 0x0C: 32 columns vertical scroll (pool player animation)

    // Per-scanline horizontal row scroll (Mode 0x14)
    wire [7:0] row_scroll_idx      = next_v[7:0];                           // RAM index is screen row, NOT scrolled row
    wire [7:0] scroll_ram_lsb      = scroll_ram[{row_scroll_idx, 1'b0}];   // X[7:0] for this row
    wire [7:0] scroll_ram_msb      = scroll_ram[{row_scroll_idx, 1'b1}];   // X[8]   for this row
    wire [8:0] layer0_row_scroll_x = {scroll_ram_msb[0], scroll_ram_lsb}; // combined 9-bit row offset

    // Per-column vertical scroll (Mode 0x0C)
    wire [4:0] col_scroll_idx      = next_h[7:3];                         // Column index (0..31 across 256 pixels)
    wire [7:0] col_scroll_ram_lsb  = scroll_ram[{3'b000, col_scroll_idx, 1'b0}]; // Y[7:0] for this column
    wire [7:0] col_scroll_ram_msb  = scroll_ram[{3'b000, col_scroll_idx, 1'b1}]; // Y[8]   for this column
    wire [8:0] layer0_col_scroll_y = {col_scroll_ram_msb[0], col_scroll_ram_lsb}; // combined 9-bit col offset

    wire [8:0] effective_layer0_scroll_x = use_row_scroll ? layer0_row_scroll_x : layer0_scroll_x;
    wire [8:0] effective_layer0_scroll_y = use_col_scroll ? layer0_col_scroll_y : layer0_scroll_y;

    wire [8:0] layer0_scrolled_v = next_v + effective_layer0_scroll_y;
    wire [8:0] layer0_scrolled_h = next_h + effective_layer0_scroll_x;
    wire [5:0] layer0_tile_x = layer0_scrolled_h[8:3];
    wire [4:0] layer0_tile_y = layer0_scrolled_v[7:3];
    // VRAM offset formula: {tile_x[5], tile_y[4:0], tile_x[4:0]} = 11-bit index into the 2KB attribute/tile table
    wire [10:0] layer1_vram_offset = {layer1_tile_x[5], layer1_tile_y[4:0], layer1_tile_x[4:0]};
    wire [10:0] layer0_vram_offset = {layer0_tile_x[5], layer0_tile_y[4:0], layer0_tile_x[4:0]};
    
    reg [13:0] vid_vram_addr;
    
    reg [8:0] layer0_scroll_x;
    reg [7:0] layer0_scroll_y;
    reg [8:0] layer1_scroll_x;
    reg [7:0] layer1_scroll_y;

    // Shadow-verify tap registers (2026-08-13) -- see the shadow_sdram_*
    // port comment above. Deliberately separate from every real render-path
    // register so this can never feed back into actual rendering.
    reg [17:0] tap_addr;
    reg        tap_valid;
    // 2026-09-02, task #77 warning cleanup: removed `tap_data` -- predates
    // this session's own investigations and was never read by anything.
    //
    // `tap_layer` (below) briefly went dead too, right after Round 168's
    // cache-partition revert, and was removed in that same cleanup pass --
    // then reintroduced minutes later (still 2026-09-02) once the revert's
    // real cost became clear: it fixed Battlantis but silently reopened
    // Rack 'Em Up's original cross-layer aliasing bug (task #79), since
    // both used the same index space this flag used to help partition.
    // Now feeds `tap_tile_tag`'s own layer bit instead (see
    // vid_tile_set's comment further down for the full current design).
    reg        tap_layer;
    // Same story as `tap_layer` -- see vid_tile_set's comment below for
    // the current design (now feeds `vid_tile_tag`, not the index).
    reg        cache_layer_reg;

    // Pipeline delays for memory reads
    reg [7:0] vid_vram_dout;
    always @(posedge clk) vid_vram_dout <= vram[vid_vram_addr[12:0]];
    
    // ROM Fetch -- reads the tile CACHE now (2026-08-14, Test 222 real
    // cutover), not a full local ROM copy. The actual read happens in the
    // dedicated tile_cache read/write block further down this file (kept as
    // a single block with the fill write, the same structure already
    // confirmed to synthesize as one clean dual-port M10K rather than the
    // duplicated instances an earlier, more tangled version produced).
    // vid_tile_dout_reg is driven from there, not here.
    reg [17:0] vid_tile_addr;
    wire [7:0] vid_tile_dout_reg;

    wire [12:0] vid_tile_key   = vid_tile_addr[17:5];
    // 2026-08-29, tasks #74/#79/#80: original cache-partition attempt --
    // reserved the index's top bit to sort entries into two disjoint
    // 1024-entry halves, one per layer, to stop Layer 0/Layer 1 evicting
    // each other's entries (Rack 'Em Up's persistent garbage). Worked for
    // that, but unconditionally halved the cache for EVERY game, including
    // Battlantis (layer1_enable=0 always, so the "Layer 1 half" is pure
    // waste for it) -- confirmed on real hardware 2026-09-01/02 as a real
    // regression (Stage 1 black squares, from the halved cache missing
    // more often under sustained real play than the short, narrow
    // Round-92/93 simulation happened to catch). Reverting the partition
    // outright (tried first) fixed Battlantis but silently reintroduces Rack 'Em
    // Up's original cross-layer aliasing bug, since it's the exact same
    // index space this comment used to warn about.
    //
    // 2026-09-02: replaced with a design that gives both games what they
    // need without either problem. The INDEX is unconditionally the full,
    // un-partitioned `vid_tile_key[10:0]` -- every game gets the real,
    // full 2048-entry cache, zero capacity cost, ever. Cross-layer safety
    // instead comes from the TAG: its extra bit (already 3 bits wide from
    // the partition work, previously always forced 0) now carries which
    // layer wrote this entry (`cache_layer_reg`, the exact same clean,
    // case-statement-registered value the old partition scheme used to
    // feed into the INDEX -- reused here for the TAG instead). A Layer 0
    // and a Layer 1 tile can still land on the same physical slot (they
    // now share the full space, same as the pre-partition scheme), but
    // the tag comparison (`tile_cache_tag[index] == tag`, elsewhere in
    // this file) now fails whenever the stored and requested layer bits
    // differ, correctly forcing a MISS (Task #25's safe 8'h00 fallback,
    // then a real refill) instead of the original bug's silent
    // WRONG-LAYER-BYTES-AS-YOUR-OWN corruption. Structurally this can
    // only produce FEWER misses than the old partition scheme, never
    // more (sharing one 2048-entry space beats splitting into two
    // 1024-entry halves for any access pattern), while being exactly as
    // safe against cross-layer corruption -- a strict improvement on both
    // axes, not a trade-off between them.
    //
    // Still applied via the same safe, case-statement-registered pattern
    // as before (`cache_layer_reg` set to 0 at fetch_state 0, to
    // layer1_enable at fetch_state 18 -- see that case statement below)
    // rather than a live ternary or comparator: this file has twice
    // already hit real Quartus M10K-inference breaks (Error 276003, "doesn't
    // fit the device") from combinational logic sitting directly in front
    // of `tile_cache`'s own read address (documented in this file's own
    // history, and in debugging_log.md's Test 163). Critically, THIS
    // design never puts `cache_layer_reg` anywhere near that read address
    // at all -- the index stays a pure, unconditional slice of
    // `vid_tile_key`, exactly like the reverted no-partition version, so
    // that specific risk doesn't apply here regardless. `cache_layer_reg`
    // only feeds `tile_cache_tag`'s WRITE data and the post-read tag
    // comparison, both well clear of `tile_cache`'s own address path.
    //
    // Round 198 (2026-09-03): went 2-way set-associative to cut the real,
    // measured aliasing rate (Round 164: two different tiles regularly
    // fight over the same slot under Battlantis's actual scroll-heavy
    // access pattern) without spending more M10K than the existing 64KB
    // (Round 195 already proved brute-force doubling the direct-mapped
    // size doesn't fit the device). One index bit moves from the SET into
    // the TAG instead: SET is now vid_tile_key[9:0] (1024 sets, half as
    // many as before), TAG widens 3->4 bits ({layer, key[12:10]}) to cover
    // the extra bit. Two tiles that used to force an immediate evict/
    // refill cycle on each other can now both stay resident at once (one
    // per way); only a THIRD contender for the same set still evicts.
    // Kept the exact same "index/set stays a pure, unconditional slice,
    // nothing else goes near it" discipline from the comment above --
    // see the read/write block further down for how the way-select
    // avoids ever touching either way's own read address directly.
    // Round 50: the set index is key[9:0] XOR a hash of the tag ({layer, key[12:10]}). A pure key[9:0] index
    // let three hot lines share one set on the roster screen (layer 0 tile 0x10, layer 1 tile 0x10 and layer 1
    // tile 0x10 with attr[6]); with 2 ways the third was evicted forever and 7 tiles rendered black. The hash
    // gives all 16 tag values distinct single-bit offsets, so lines that differ only in layer or bank bits can
    // no longer collide; the tag still identifies the line uniquely, so the index is invertible (see the
    // un-hash at the SDRAM fill address). Chosen offline over 146 MAME attract-mode screens (title, roster and
    // demo gameplay): 0 over-subscribed sets on every screen, including the full 64x32 maps of both layers,
    // versus up to 6 sets with the plain index.
    // Round 53: the Round 50 constants (0x040, 0x200, 0x080, 0x008) were chosen on attract mode screens only. The fight
    // animation (a 28 x 32 tile picture in layer 1, 856 distinct lines) left 3 sets with 3 to 4 contenders and 13 lines
    // refilled every frame, which shows as blank 8x8 cells. Re-chosen offline on the cache lookups the chip really makes
    // (tap log of the chip testbench, hblank columns excluded, see tap_col_visible) over 162 MAME states (146 attract, 7
    // earlier dumps, 9 fight) and checked on 136 more from an autoplay run (title, roster, play, shoot out, fight): 0 sets
    // with more than 2 distinct lines on every one of them (the Round 50 hash: 40 excess lines on 8 screens, 95 on 19 of the
    // autoplay screens). The first Round 53 constants (0x001, 0x20C, 0x080, 0x132) still left 3 lines in conflict on one screen
    // type of the later attract loops (frames 13800 to 14150 and the same moment of every loop); the constants below were searched
    // on 1692 states (304 distinct lookup sets: 480 + 800 attract loop states, 136 autoplay, 114 fights, 162 first set) and
    // cross validated (a hash fitted on either half of the sets has 0 over-subscribed sets on the other half). Constrained so that every set bit depends on at most ONE tag bit (the four constants have
    // disjoint bit support), which keeps the logic depth in front of the cache read address exactly as it was.
    function [9:0] tile_set_hash(input [3:0] tag);
        tile_set_hash = (tag[3] ? 10'h011 : 10'h000)   // layer
                      ^ (tag[0] ? 10'h220 : 10'h000)   // key[10]
                      ^ (tag[1] ? 10'h004 : 10'h000)   // key[11]
                      ^ (tag[2] ? 10'h18A : 10'h000);  // key[12]
    endfunction
    wire        cache_layer_bit = cache_layer_reg;
    wire [3:0]  vid_tile_tag   = {cache_layer_bit, vid_tile_key[12:10]};
    wire [9:0]  vid_tile_set   = vid_tile_key[9:0] ^ tile_set_hash(vid_tile_tag);

    wire [7:0] vid_tile_dout = vid_tile_dout_reg;

    // Storage for fetched data
    reg [7:0] layer0_tile, layer0_attr;
    reg [7:0] layer1_tile, layer1_attr;
    reg [7:0] layer0_data [0:3];
    reg [7:0] layer1_data [0:3];

    integer regs_reset_i;
    always @(posedge clk) begin
        if (reset) begin
            int_enabled <= 1'b0;
            irq <= 1'b0;
            vblank <= 1'b0;
            layer0_scroll_x <= 0;
            layer0_scroll_y <= 0;
            layer1_scroll_x <= 0;
            layer1_scroll_y <= 0;
            sprite_wrap_y <= 1'b0;
            // 2026-08-29, task #83 follow-up: `regs[]` (and therefore
            // flip_screen_req = regs[0][4], see that port's comment) had no
            // reset value -- this assumed Cyclone V flip-flops reliably
            // power up to 0, an unverified real-hardware assumption of
            // exactly the same class this project has already been burned
            // by tonight for block RAM. If regs[0][4] powers up as 1 on
            // real silicon, flip_screen_req is stuck asserted from boot,
            // which plausibly explains a real-hardware-only "screen split
            // into repeating columns" regression that appeared only after
            // this register was first read for anything (the cocktail-flip
            // feature) -- a structural symptom that fits a stuck video
            // rotate/flip signal far better than sprite/VRAM content ever
            // did. Explicit reset removes the dependency on any assumed
            // power-up value entirely.
            for (regs_reset_i = 0; regs_reset_i < 8; regs_reset_i = regs_reset_i + 1) regs[regs_reset_i] <= 8'h00;
        end else begin
            if (cpu_we && cpu_addr >= 14'h2600 && cpu_addr <= 14'h2607) begin
                regs[cpu_addr[2:0]] <= cpu_din;
            end
            if (cpu_we && cpu_addr == 14'h2600) begin
                int_enabled <= cpu_din[1];
            end
            if (cpu_we && cpu_addr == 14'h2602) begin
                layer0_scroll_x[8] <= cpu_din[0];
                layer1_scroll_x[8] <= cpu_din[1];
                // Bit 7 of this same register is the real K007342's sprite
                // Y-wrap enable flag (k007342_mame.cpp: `m_sprite_wrap_y_cb(BIT(data,7))`
                // on this exact register write) -- tells the K007420 sprite
                // chip to also draw a sprite a second time, offset a full
                // screen height away, so sprites don't pop in/out abruptly
                // as they scroll past the top/bottom edge. Was previously
                // completely dropped (only bits 0/1 were captured) -- found
                // 2026-08-16 after the user directly observed a sprite's
                // "shadow" rendering a full screen away from the sprite
                // itself (near the bottom while the sprite was near the
                // top), which is exactly this feature's signature when
                // missing/uncontrolled.
                sprite_wrap_y <= cpu_din[7];
            end
            if (cpu_we && cpu_addr == 14'h2603) layer0_scroll_x[7:0] <= cpu_din;
            if (cpu_we && cpu_addr == 14'h2604) layer0_scroll_y      <= cpu_din;
            if (cpu_we && cpu_addr == 14'h2605) layer1_scroll_x[7:0] <= cpu_din;
            if (cpu_we && cpu_addr == 14'h2606) layer1_scroll_y      <= cpu_din;
            
            if (v_cnt == 9'd240 && h_cnt == 9'd0) begin
                vblank <= 1'b1;
                if (int_enabled) irq <= 1'b1;
            end else if (v_cnt == 9'd260) begin
                vblank <= 1'b0;
            end
            
            if (irq_ack) irq <= 1'b0;
        end
    end

    // ==============================================================================
    // TILE ROM ADDRESS CONSTRUCTION
    // ==============================================================================
    // Each 8x8 tile occupies 32 bytes in the tile ROM (8 rows x 4 bytes/row).
    // The 18-bit ROM address is built as:
    //   [17:13] = bank bits   : attr[3:0] and attr[6], in the order selected by
    //                           tile_code_layout (0 = {attr[3:0], attr[6]} Battlantis,
    //                           1 = {attr[6], attr[3:0]} Blades of Steel)
    //   [12:5]  = tile        : tile code LSB (8 bits)
    //   [4:2]   = scrolled_v[2:0] : which pixel row within the 8x8 tile (0–7)
    //   [1:0]   = byte_xor    : which of the 4 bytes in the row (0–3)
    //
    // Each byte encodes 2 pixels (4 bits each): pixel_a = [7:4], pixel_b = [3:0].
    // All 4 bytes together give 8 pixels = one full tile row.
    //
    // BYTE XOR CONFIGURATION — byte_xor selects the byte order within each row:
    //   2’d0 = A,B,C,D  (no swap)
    //   2’d1 = B,A,D,C  (16-bit word swap)
    //   2’d2 = C,D,A,B  (32-bit word swap)
    //   2’d3 = D,C,B,A  (Reverse)
    //
    // MAME uses ROM_LOAD16_WORD_SWAP for Battlantis graphics, so the correct 
    // sequence to un-swap the bytes during fetch is 2'd1 (B,A,D,C).
    // ==============================================================================
    wire [1:0] byte_xor = 2'd1; // Correct 16-bit word swap for Battlantis (and Blades: same ROM_LOAD16_WORD_SWAP + packed_msb)

    // Tile-code high bits (5 bits: attr[6] + attr[3:0]) in the order the game's own
    // tile_callback composes them. See the tile_code_layout port comment.
    // Tile flip attributes (MAME k007342 get_tile_info: flags = TILE_FLIPYX((attr & 0x30) >> 4), i.e. attr[4] = flip X,
    // attr[5] = flip Y, for every game). Round 50: the RTL never implemented them (Battlantis rarely sets them), but the
    // Blades rink and boards are built from mirrored tiles. Flip Y selects the mirrored pixel row of the tile ROM line.
    wire [2:0] layer0_row_in_tile = layer0_scrolled_v[2:0] ^ {3{layer0_attr[5]}};
    wire [2:0] layer1_row_in_tile = layer1_scrolled_v[2:0] ^ {3{layer1_attr[5]}};
    wire [4:0] layer0_bank_bits = tile_code_layout ? {layer0_attr[6], layer0_attr[3:0]}
                                                   : {layer0_attr[3:0], layer0_attr[6]};
    wire [4:0] layer1_bank_bits = tile_code_layout ? {layer1_attr[6], layer1_attr[3:0]}
                                                   : {layer1_attr[3:0], layer1_attr[6]};

    always @(posedge clk) begin
        case (fetch_state)
            // ------------------------------------------------------------------
            // LAYER 0 FETCH  (states 0–17)
            // ------------------------------------------------------------------
            // Reads happen 2 states after the address is set (1-cycle BRAM latency
            // + 1 pipeline register in vid_vram_dout / vid_tile_dout_reg).

            0:  begin
                    vid_vram_addr <= layer0_vram_offset + 14'h0800; // set addr: Layer 0 tile code (LSB)
                    cache_layer_reg <= 1'b0;
                end
            2:  layer0_tile   <= vid_vram_dout;                  // latch tile code
            3:  vid_vram_addr <= layer0_vram_offset + 14'h0000; // set addr: Layer 0 attribute byte
            5:  layer0_attr   <= vid_vram_dout;               // Read all 4 ROM bytes for this tile's current scanline row:
            6:  vid_tile_addr <= {layer0_bank_bits, layer0_tile, layer0_row_in_tile, 2'd0 ^ byte_xor};
            8:  begin
                    layer0_data[0] <= vid_tile_dout; // pixels 0-1
                    // Shadow-verify tap (2026-08-13): passively captures the address
                    // and BRAM-fetched byte the real pipeline just used, for later
                    // independent re-verification via SDRAM in a separate state
                    // machine below. Zero new address computation here -- both
                    // values already exist for the real render path.
                    if (tap_col_visible) begin
                        tap_addr <= vid_tile_addr;
                        tap_valid <= 1'b1;
                        tap_layer <= 1'b0; // Layer 0's own tap capture
                    end
                end
            9:  vid_tile_addr <= {layer0_bank_bits, layer0_tile, layer0_row_in_tile, 2'd1 ^ byte_xor};
            11: layer0_data[1] <= vid_tile_dout; // pixels 2-3
            12: vid_tile_addr <= {layer0_bank_bits, layer0_tile, layer0_row_in_tile, 2'd2 ^ byte_xor};
            14: layer0_data[2] <= vid_tile_dout; // pixels 4-5
            15: vid_tile_addr <= {layer0_bank_bits, layer0_tile, layer0_row_in_tile, 2'd3 ^ byte_xor};
            17: layer0_data[3] <= vid_tile_dout; // pixels 6-7
            
            // ------------------------------------------------------------------
            // LAYER 1 FETCH  (states 18–35) — identical pipeline to Layer 0
            // ------------------------------------------------------------------
            // 2026-08-28: found that this pipeline's read side (vid_tile_addr/
            // vid_tile_dout, both shared with Layer 0) was always correctly
            // computed, but the tile_cache's MISS/FILL-TRIGGER detection only
            // ever looked at `tap_addr`, which was only ever captured during
            // Layer 0's own fetch (state 8) -- meaning Layer 1 could never
            // trigger its own cache fill. It could only "borrow" whatever
            // Layer 0 happened to have already cached at the same 2048-entry
            // index+tag, or miss and get a safe blank byte -- never its own
            // real content. Fixed by mirroring the same tap capture here at
            // state 26 (Layer 1's own equivalent of Layer 0's state 8), so
            // Layer 1 gets independent fill-trigger detection through the
            // same shared cache/fill machinery.
            //
            // 2026-08-28, same day, gated on layer1_enable: this tap capture
            // is a SHARED resource with Layer 0 (one fill state machine, one
            // 2048-entry cache) -- for a game like Battlantis where Layer 1
            // never contributes real pixels at all, letting its fetches keep
            // triggering real cache fills anyway was a real regression, not
            // a theoretical one: confirmed on real hardware as black boxes
            // appearing and changing size across multiple stages (Level 1,
            // Stage 11) immediately after this fix was first deployed
            // without this gate. Layer 1's fetch pipeline still runs every
            // scanline regardless (states 18-35 unconditionally), but now
            // only feeds the shared cache/fill machinery when layer1_enable
            // is actually true -- for Battlantis this makes Layer 1's tap
            // capture a complete no-op again, exactly matching the original,
            // known-good behavior before any of this investigation started.

            18: begin
                    vid_vram_addr <= layer1_vram_offset + 14'h1800; // Layer 1 tile code
                    cache_layer_reg <= layer1_enable;
                end
            20: layer1_tile   <= vid_vram_dout;
            21: vid_vram_addr <= layer1_vram_offset + 14'h1000; // Layer 1 attribute
            23: layer1_attr   <= vid_vram_dout;

            24: vid_tile_addr <= {layer1_bank_bits, layer1_tile, layer1_row_in_tile, 2'd0 ^ byte_xor};
            26: begin
                    layer1_data[0] <= vid_tile_dout;
                    if (layer1_enable && tap_col_visible) begin
                        tap_addr <= vid_tile_addr;
                        tap_valid <= 1'b1;
                        tap_layer <= 1'b1; // Layer 1's own tap capture
                    end
                end
            27: vid_tile_addr <= {layer1_bank_bits, layer1_tile, layer1_row_in_tile, 2'd1 ^ byte_xor};
            29: layer1_data[1] <= vid_tile_dout;
            30: vid_tile_addr <= {layer1_bank_bits, layer1_tile, layer1_row_in_tile, 2'd2 ^ byte_xor};
            32: layer1_data[2] <= vid_tile_dout;
            33: vid_tile_addr <= {layer1_bank_bits, layer1_tile, layer1_row_in_tile, 2'd3 ^ byte_xor};
            35: layer1_data[3] <= vid_tile_dout;
            // States 36-63: idle (no fetch needed; pipeline is complete)
        endcase
    end
    // ==============================================================================
    // PIXEL OUTPUT WITH SMOOTH HORIZONTAL SCROLLING
    // ==============================================================================
    // disp0 holds the current tile column's 4 bytes (latched at fetch_state==63).
    // layer0_data[] holds the NEXT tile being prefetched (available by h_cnt[2:0]=2).
    //
    // Smooth scroll: pixel_index = h_cnt[2:0] + fine_scroll_latch.
    //   If pixel_index < 8: read from disp0  (current tile, bits [2:0])
    //   If pixel_index >= 8: read from layer0_data (next tile, bits [2:0] - 8 = [2:0])
    //
    // fine_scroll_latch is captured at h_cnt[2:0]==0 so it stays constant for
    // the entire 8-pixel tile column, avoiding mid-tile tearing.
    //
    // Timing note: layer0_data[0] is valid from h_cnt[2:0]=2 onward (fetch_state=8
    // fires at h_cnt=1 ce_div=0, result available at h_cnt=2). For fine_scroll=6
    // the first overflow pixel is at h_cnt[2:0]=2 — just valid. fine_scroll=7
    // overflows at h_cnt[2:0]=1, causing a 1-pixel glitch that is imperceptible.
    // ==============================================================================
    reg [7:0] disp0 [0:3];  // display buffer for Layer 0 (current tile column)
    reg [7:0] disp1 [0:3];  // display buffer for Layer 1
    reg [2:0] fine_scroll_latch0;
    reg [2:0] fine_scroll_latch1;
    // Round 193 (2026-09-03), ported from Gemini's fix in RackEmUp_template
    // (commit 8d17fe4): disp0[]/disp1[] hold the CURRENT tile's pixel data,
    // latched at fetch_state==63 -- but layer0_priority/layer1_priority
    // used to always read the LIVE layer0_attr/layer1_attr register, which
    // by the time a given pixel is displayed may already have moved on to
    // the NEXT tile being prefetched. These latch the attribute byte
    // alongside its own tile's pixel data so priority stays aligned with
    // whichever tile (current vs. next) sel_byte0/1 actually selected.
    reg [7:0] disp0_attr;
    reg [7:0] disp1_attr;

    always @(posedge clk) begin
        if (fetch_state == 63) begin
            disp0[0]   <= layer0_data[0];
            disp0[1]   <= layer0_data[1];
            disp0[2]   <= layer0_data[2];
            disp0[3]   <= layer0_data[3];
            disp0_attr <= layer0_attr;
            disp1[0]   <= layer1_data[0];
            disp1[1]   <= layer1_data[1];
            disp1[2]   <= layer1_data[2];
            disp1[3]   <= layer1_data[3];
            disp1_attr <= layer1_attr;
        end
        if (ce_pix && h_cnt[2:0] == 3'd0) begin
            fine_scroll_latch0 <= effective_layer0_scroll_x[2:0];
            fine_scroll_latch1 <= layer1_scroll_x[2:0];
        end
    end

    // Smooth scroll pixel select for Layer 0
    wire [3:0] adj_idx0      = {1'b0, h_cnt[2:0]} + {1'b0, fine_scroll_latch0};
    wire        use_next0     = adj_idx0[3];            // 1 = need next tile (overflow)
    // flip X: reverse the pixel order inside the tile that supplies this pixel (per tile attribute, attr[4])
    wire        flipx0       = use_next0 ? layer0_attr[4] : disp0_attr[4];
    wire [2:0]  pix_i0       = adj_idx0[2:0] ^ {3{flipx0}};
    wire [1:0]  adj_byte0    = pix_i0[2:1];
    wire        adj_nib0     = pix_i0[0];
    wire [7:0]  sel_byte0    = use_next0 ? layer0_data[adj_byte0] : disp0[adj_byte0];
    wire [3:0]  layer0_pix   = adj_nib0 ? sel_byte0[3:0] : sel_byte0[7:4];

    // Smooth scroll pixel select for Layer 1 (currently unused in Battlantis)
    wire [3:0] adj_idx1      = {1'b0, h_cnt[2:0]} + {1'b0, fine_scroll_latch1};
    wire        use_next1     = adj_idx1[3];
    wire        flipx1       = use_next1 ? layer1_attr[4] : disp1_attr[4];
    wire [2:0]  pix_i1       = adj_idx1[2:0] ^ {3{flipx1}};
    wire [1:0]  adj_byte1    = pix_i1[2:1];
    wire        adj_nib1     = pix_i1[0];
    wire [7:0]  sel_byte1    = use_next1 ? layer1_data[adj_byte1] : disp1[adj_byte1];
    wire [3:0]  layer1_pix   = adj_nib1 ? sel_byte1[3:0] : sel_byte1[7:4];

    // 2026-08-28: Layer 1 re-enabled as a real transparent-on-zero overlay
    // above Layer 0, now that the cache fill-trigger gap above is fixed
    // (this exact compositing logic was tried once already and produced a
    // uniform garbage-glyph overlay on real hardware -- root-caused
    // afterward to the fill-trigger gap, not this mux itself; re-verify
    // carefully in Verilator before trusting this on real hardware again).
    // Round 193: priority now reads whichever tile's own attribute byte
    // (current disp*_attr vs. live layer*_attr for the prefetched next
    // tile) matches whichever tile sel_byte0/1 actually pulled the pixel
    // from, instead of always the live register -- see disp0_attr's own
    // comment above for why this matters.
    wire layer1_priority = use_next1 ? layer1_attr[7] : disp1_attr[7];

    // Original formula (Battlantis/Rack 'Em Up, alt_priority_mode=0):
    // layer1 is an optional overlay on top of layer0.
    wire        layer1_wins  = layer1_enable && (layer1_pix != 4'd0);
    wire [3:0]  final_pix_orig      = layer1_wins ? layer1_pix : layer0_pix;
    wire        final_priority_orig = layer1_wins ? layer1_priority : layer0_priority;
    wire [2:0]  final_pal_orig      = {2'd0, layer1_wins};

    // New formula (Blades of Steel, alt_priority_mode=1): layer0 is the
    // overlay, unconditionally above sprites whenever non-transparent;
    // layer1 is the opaque base, using its own attr[7] for over/under
    // sprites. See alt_priority_mode's own port comment above for the
    // real screen_update() sequence this reproduces.
    wire [3:0]  l1_base_pix   = layer1_enable ? layer1_pix : 4'd0;
    wire        l0_shows_alt  = (layer0_pix != 4'd0);
    wire [3:0]  final_pix_alt      = l0_shows_alt ? layer0_pix : l1_base_pix;
    wire        final_priority_alt = l0_shows_alt ? 1'b1 : layer1_priority;
    wire [2:0]  final_pal_alt       = {2'd0, ~l0_shows_alt}; // layer0 shown -> bank0, layer1 shown -> bank1 (tile_callback: color=layer)

    wire [3:0] final_pix      = alt_priority_mode ? final_pix_alt      : final_pix_orig;
    wire       final_priority = alt_priority_mode ? final_priority_alt : final_priority_orig;
    wire [2:0] final_pal      = alt_priority_mode ? final_pal_alt      : final_pal_orig;

    // layer0_priority (attr[7]): when high, Layer 0 renders on TOP of sprites.
    // Round 193: see layer1_priority's own comment above -- reads whichever
    // tile's attribute (current disp0_attr vs. live layer0_attr for the
    // prefetched next tile) matches what sel_byte0 actually pulled from.
    wire layer0_priority = use_next0 ? layer0_attr[7] : disp0_attr[7];

    // Round 192 (2026-09-03) fix: `final_priority` used to be packed into
    // pixel_color's own bit 7 ({final_priority, final_pal, final_pix}),
    // which put every attr[7]=1 tile's palette lookup into pixel_color
    // 0x80-0xFF -- a completely different half of palette RAM than every
    // attr[7]=0 tile, despite `final_pal` always being 0 either way. Real
    // hardware doesn't do this: `battlnts_mame.cpp`'s `tile_callback` sets
    // `color = 0` unconditionally (never touches attr[7]/bit 0x80), and
    // priority is handled entirely separately via MAME's tilemap draw-
    // category mechanism, not by changing which palette entries a tile
    // addresses. Since games have no reason to populate that upper half
    // (real hardware never reads it for tile color), it reads back as
    // whatever colorram/testpattern data happens to sit there -- black in
    // every real-game-state capture taken this session -- so any priority
    // tile rendered black instead of its real color. Fixed by keeping
    // pixel_color's bit 7 hardcoded 0 and carrying priority on its own
    // dedicated `pixel_priority` output instead, so it can only affect
    // sprite/background compositing order (Battlantis.sv's `bg_priority`),
    // never the palette RAM address.
    // Output: {1'b0, palette_bank[2:0], colour_index[3:0]}.
    // Priority masking:
    // 1. Layer 0 / Layer 1 native priority (attr[7] == 1): HUD, table rails, shot window top border.
    // 2. Top and bottom overscan margins: rows 0-1 (adj_v < 16) and rows 26-27 (adj_v >= 208).
    //    The arcade CPU clears these rows to black with attr=0, but on a 224-line display (and when
    //    rotated 90 degrees), sprites positioned near screen edges (e.g. shot view billiard balls
    //    at spr_y=8) must not bleed into the black overscan margins.
    // 3. Shot view left frame and power meter (Rows 0-10, Columns 0-2: adj_v < 88 && h_cnt < 24):
    //    In the cutscene, the CPU writes the left frame and "SHOT VIEW" text with attr=0x42 (priority bit 7=0).
    //    Occluding sprites behind this region keeps the billiard ball animations cleanly confined within
    //    the inset shot window.
    wire [8:0] adj_v = (v_cnt >= 9'd16) ? (v_cnt - 9'd16) : 9'd0;
    wire is_overscan_or_frame = (adj_v < 9'd16) || (adj_v >= 9'd208) ||
                                ((adj_v < 9'd88) && (h_cnt < 9'd24));

    // Round 53b: is_overscan_or_frame is a Battlantis / Rack 'Em Up specific mask (it hides sprites under the tiles in the first and
    // last 16 raster lines and, in the first 88 lines, the first 24 columns). Blades of Steel inherited it with the file and
    // therefore lost every sprite pixel over an opaque tile inside those bands: players vanished 16 pixels before the boards
    // on both sides of the rink (the user's 'sprites drop off early at both sides'). MAME's bladestl screen_update has no such
    // rule: tiles cover sprites only through the layer 1 attribute bit 7 and through layer 0, which is drawn last. alt_priority_mode
    // selects the Blades rule set, so the mask is bypassed there.
    wire rackemup_bg_priority = final_priority || (OVERSCAN_MASK != 0 && is_overscan_or_frame && !alt_priority_mode);

    always @(posedge clk) begin
        if (ce_pix) begin
            pixel_color <= {1'b0, final_pal, final_pix};
            pixel_priority <= rackemup_bg_priority;
        end
    end

    // ==============================================================================
    // TILE GRAPHICS ROM: the whole 256KB on chip (Round 53b, 2026-10-09, an experiment requested by the user)
    // ==============================================================================
    // Until Round 53 the tile ROM was read through a 2 way, 64KB cache that missed to SDRAM port 2 (blank on miss, miss queue of 4,
    // hashed set index; see TASKS.md Rounds 50 and 53 for the history). That design needed the lookups to be filtered and the hash
    // to be tuned per scene type, and it can still show blank cells whenever a new picture needs more lines than the fill engine
    // delivers in time. The tile ROM now sits completely in on chip RAM (written during the ROM download by the same strobe that
    // writes the SDRAM copy, which is no longer read), so a lookup can never miss, SDRAM port 2 is idle and the cache, the hash,
    // the miss queue and the fill state machine are gone. The read keeps the timing of the cache it replaces: vid_tile_addr is a
    // register, the RAM output is registered once, the fetch state machine consumes it two states later.
    (* ramstyle = "M10K" *) reg [7:0] tile_rom_bram [0:262143];                 // {bank[4:0], tile[7:0], row[2:0], byte[1:0]}
    wire        tile_dl_hit = ioctl_wr && (ioctl_addr >= 25'h60000) && (ioctl_addr < 25'hA0000);
    wire [24:0] tile_dl_off = ioctl_addr - 25'h60000;
    reg  [7:0]  tile_rom_dout;
    always @(posedge clk) begin
        if (tile_dl_hit)
            tile_rom_bram[tile_dl_off[17:0]] <= ioctl_dout;
        tile_rom_dout <= tile_rom_bram[vid_tile_addr];
    end
    assign vid_tile_dout_reg = tile_rom_dout;

    // SDRAM port 2 and the cache statistics are unused now; the ports stay so the top level and the diagnostic overlay are unchanged.
    assign shadow_sdram_req               = 1'b0;
    assign shadow_sdram_addr              = 25'd0;
    assign shadow_verify_addr_out         = 18'd0;
    assign shadow_verify_expected_out     = 8'd0;
    assign shadow_verify_actual_out       = 8'd0;
    assign shadow_verify_match_out        = 1'b0;
    assign shadow_verify_pass_count_out   = 16'd0;
    assign shadow_verify_fail_count_out   = 16'd0;
    assign shadow_max_wait_cycles_out     = 16'd0;
    assign shadow_currently_stuck_out     = 1'b0;
    assign cache_sim_hit_count_out        = 24'd0;
    assign cache_sim_miss_count_out       = 24'd0;

endmodule
