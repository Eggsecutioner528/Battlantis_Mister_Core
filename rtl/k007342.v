module k007342 (
    input  wire        clk,
    input  wire        reset,

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

    // IOCTL ROM Download (for Tile Graphics) -- written directly into SDRAM
    // by the top level's Port 0 wiring, not captured locally here; only used
    // by this module indirectly, via the tile cache's SDRAM-backed fills.
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,

    // Output Pixels
    output reg  [7:0]  pixel_color, // color index 0-15

    // Interrupts
    output reg         vblank,
    output reg         int_enabled,
    output reg         irq,
    input  wire        irq_ack,

    // SDRAM interface for on-demand background tile fills (Port 2). See the
    // "TILE CACHE + SDRAM-BACKED FILL" section below for the full design.
    output wire         tile_sdram_req,
    output wire [24:0]  tile_sdram_addr,
    input  wire [7:0]   tile_sdram_dout,
    input  wire         tile_sdram_ready
);

    // ==============================================================================
    // TILE GRAPHICS ROM (256 KB, ROM file: 777c04.13a) -- lives in SDRAM, not a
    // local BRAM copy. Background tile data is served through the 64KB tile
    // cache further down this file (backed by SDRAM on a miss), not a full
    // local array -- see the "TILE CACHE + SDRAM-BACKED FILL" section below.
    // The top level's Port 0 IOCTL wiring already writes every downloaded
    // byte -- tile ROM included -- into SDRAM directly during boot, so the
    // cache's fill mechanism finds real data there with no separate capture
    // path required here.
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
    (* ramstyle = "M10K" *) reg [7:0] vram [0:16383];

    // Port A: CPU read/write
    reg [7:0] vram_dout;
    // Remap register region (0x2600-0x2607) to low VRAM addresses for the read path
    wire [12:0] cpu_vram_addr      = (cpu_addr >= 14'h2600 && cpu_addr <= 14'h2607) ? {10'd0, cpu_addr[2:0]} : cpu_addr[12:0];
    wire [13:0] cpu_vram_full_addr = (cpu_addr >= 14'h2600 && cpu_addr <= 14'h2607) ? {1'b0, cpu_vram_addr} : {vram_bank, cpu_vram_addr};

    always @(posedge clk) begin
        if (cpu_we && cpu_addr < 14'h2000) begin
            vram[{vram_bank, cpu_addr[12:0]}] <= cpu_din;
        end
        vram_dout <= vram[cpu_vram_full_addr];
    end
    reg [7:0] regs [0:7]; // K007342 control registers (write-only from CPU side)
    // K007342 registers are write-only. Reading 0x2600-0x2607 returns VRAM[0]-VRAM[7] due to incomplete address decoding.
    assign cpu_dout = vram_dout;

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
    // BRAM pipeline fetch (VRAM read → tile cache read → pixel shift load).
    //
    // `fetch_state` combines the pixel’s tile-column offset (h_cnt[2:0], 0–7)
    // with the sub-pixel clock counter (ce_div, 0–7) to produce a 6-bit phase
    // counter that cycles 0–63 once per tile column.
    //
    // TIMING OVERVIEW (states used in the case block below):
    //   States  0–17 : Layer 0 — VRAM read (attr + tile code) then tile cache read (4 bytes)
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
    wire [8:0] next_v = (v_cnt == 9'd261) ? 9'd0 : (v_cnt + 9'd1); // wrap at last scanline

    // Layer 1 scroll: simple global X/Y offset applied to the tilemap grid.
    wire [8:0] layer1_scrolled_v = next_v + layer1_scroll_y;
    wire [8:0] layer1_scrolled_h = next_h + layer1_scroll_x;
    wire [5:0] layer1_tile_x = layer1_scrolled_h[8:3]; // which tile column (divide by 8)
    wire [4:0] layer1_tile_y = layer1_scrolled_v[7:3]; // which tile row

    // Layer 0 scroll: supports optional per-scanline row scroll from scroll_ram.
    wire [8:0] layer0_scrolled_v = next_v + layer0_scroll_y;
    wire [7:0] row_scroll_idx = next_v[7:0];                           // RAM index is screen row, NOT scrolled row
    wire [7:0] scroll_ram_lsb  = scroll_ram[{row_scroll_idx, 1'b0}];   // X[7:0] for this row
    wire [7:0] scroll_ram_msb  = scroll_ram[{row_scroll_idx, 1'b1}];   // X[8]   for this row
    wire [8:0] layer0_row_scroll_x = {scroll_ram_msb[0], scroll_ram_lsb}; // combined 9-bit row offset

    // use_row_scroll: true when K007342 reg2 bits [4:2] == 3’b101 (mode 0x14)
    // TO DISABLE ROW SCROLL: change == 8’h14 to 1’b0.
    wire use_row_scroll = ((regs[2] & 8'h1C) == 8'h14);
    wire [8:0] effective_layer0_scroll_x = use_row_scroll ? layer0_row_scroll_x : layer0_scroll_x;
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

    // Pipeline delays for memory reads
    reg [7:0] vid_vram_dout;
    always @(posedge clk) vid_vram_dout <= vram[{vram_bank, vid_vram_addr[12:0]}];

    // ROM Fetch -- reads the tile cache (see the "TILE CACHE + SDRAM-BACKED
    // FILL" section below, which drives vid_tile_dout_reg from its own
    // dedicated read/write block).
    reg [17:0] vid_tile_addr;
    wire [7:0] vid_tile_dout_reg;

    wire [12:0] vid_tile_key   = vid_tile_addr[17:5];
    wire [10:0] vid_tile_index = vid_tile_key[10:0];
    wire [1:0]  vid_tile_tag   = vid_tile_key[12:11];

    wire [7:0] vid_tile_dout = vid_tile_dout_reg;

    // Storage for fetched data
    reg [7:0] layer0_tile, layer0_attr;
    reg [7:0] layer1_tile, layer1_attr;
    reg [7:0] layer0_data [0:3];
    reg [7:0] layer1_data [0:3];

    reg [2:0] layer0_bank;
    reg [2:0] layer1_bank;

    // One-cycle-later tap of the real read path (captured at fetch_state==8,
    // the point layer0's first tile-ROM byte lands each tile fetch), used
    // only to detect "this is a genuinely new tile fetch" so the cache-miss
    // check below runs once per real fetch, not every clock cycle -- a tile
    // spans 8 scanlines, so the same address is re-read many times.
    reg [17:0] tap_addr;
    reg        tap_valid;

    always @(posedge clk) begin
        if (reset) begin
            int_enabled <= 1'b0;
            irq <= 1'b0;
            vblank <= 1'b0;
            layer0_scroll_x <= 0;
            layer0_scroll_y <= 0;
            layer1_scroll_x <= 0;
            layer1_scroll_y <= 0;
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
    //   [17:14] = attr[3:0]   : palette / colour bank (4 bits)
    //   [13]    = attr[6]     : tile index MSB (extends code to 9 bits)
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
    wire [1:0] byte_xor = 2'd1; // Correct 16-bit word swap for Battlantis

    always @(posedge clk) begin
        case (fetch_state)
            // ------------------------------------------------------------------
            // LAYER 0 FETCH  (states 0–17)
            // ------------------------------------------------------------------
            // Reads happen 2 states after the address is set (1-cycle BRAM latency
            // + 1 pipeline register in vid_vram_dout / vid_tile_dout_reg).

            0:  vid_vram_addr <= layer0_vram_offset + 14'h0800; // set addr: Layer 0 tile code (LSB)
            2:  layer0_tile   <= vid_vram_dout;                  // latch tile code
            3:  vid_vram_addr <= layer0_vram_offset + 14'h0000; // set addr: Layer 0 attribute byte
            5:  layer0_attr   <= vid_vram_dout;               // Read all 4 ROM bytes for this tile's current scanline row:
            6:  vid_tile_addr <= {layer0_attr[3:0], layer0_attr[6], layer0_tile, layer0_scrolled_v[2:0], 2'd0 ^ byte_xor};
            8:  begin
                    layer0_data[0] <= vid_tile_dout; // pixels 0-1
                    // Cache-miss trigger tap -- see its declaration above.
                    tap_addr <= vid_tile_addr;
                    tap_valid <= 1'b1;
                end
            9:  vid_tile_addr <= {layer0_attr[3:0], layer0_attr[6], layer0_tile, layer0_scrolled_v[2:0], 2'd1 ^ byte_xor};
            11: layer0_data[1] <= vid_tile_dout; // pixels 2-3
            12: vid_tile_addr <= {layer0_attr[3:0], layer0_attr[6], layer0_tile, layer0_scrolled_v[2:0], 2'd2 ^ byte_xor};
            14: layer0_data[2] <= vid_tile_dout; // pixels 4-5
            15: vid_tile_addr <= {layer0_attr[3:0], layer0_attr[6], layer0_tile, layer0_scrolled_v[2:0], 2'd3 ^ byte_xor};
            17: layer0_data[3] <= vid_tile_dout; // pixels 6-7

            // ------------------------------------------------------------------
            // LAYER 1 FETCH  (states 18–35) — identical pipeline to Layer 0
            // ------------------------------------------------------------------
            // NOTE: In Battlantis, Layer 1 VRAM is repurposed as CPU work RAM
            // during gameplay. Layer 1 is NOT rendered (see final_pix below).
            // These fetches still run every scanline but their output is unused.

            18: vid_vram_addr <= layer1_vram_offset + 14'h1800; // Layer 1 tile code
            20: layer1_tile   <= vid_vram_dout;
            21: vid_vram_addr <= layer1_vram_offset + 14'h1000; // Layer 1 attribute
            23: layer1_attr   <= vid_vram_dout;

            24: vid_tile_addr <= {layer1_attr[3:0], layer1_attr[6], layer1_tile, layer1_scrolled_v[2:0], 2'd0 ^ byte_xor};
            26: layer1_data[0] <= vid_tile_dout;
            27: vid_tile_addr <= {layer1_attr[3:0], layer1_attr[6], layer1_tile, layer1_scrolled_v[2:0], 2'd1 ^ byte_xor};
            29: layer1_data[1] <= vid_tile_dout;
            30: vid_tile_addr <= {layer1_attr[3:0], layer1_attr[6], layer1_tile, layer1_scrolled_v[2:0], 2'd2 ^ byte_xor};
            32: layer1_data[2] <= vid_tile_dout;
            33: vid_tile_addr <= {layer1_attr[3:0], layer1_attr[6], layer1_tile, layer1_scrolled_v[2:0], 2'd3 ^ byte_xor};
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

    always @(posedge clk) begin
        if (fetch_state == 63) begin
            disp0[0] <= layer0_data[0];
            disp0[1] <= layer0_data[1];
            disp0[2] <= layer0_data[2];
            disp0[3] <= layer0_data[3];
            disp1[0] <= layer1_data[0];
            disp1[1] <= layer1_data[1];
            disp1[2] <= layer1_data[2];
            disp1[3] <= layer1_data[3];
        end
        if (ce_pix && h_cnt[2:0] == 3'd0) begin
            fine_scroll_latch0 <= effective_layer0_scroll_x[2:0];
            fine_scroll_latch1 <= layer1_scroll_x[2:0];
        end
    end

    // Smooth scroll pixel select for Layer 0
    wire [3:0] adj_idx0      = {1'b0, h_cnt[2:0]} + {1'b0, fine_scroll_latch0};
    wire        use_next0     = adj_idx0[3];            // 1 = need next tile (overflow)
    wire [1:0]  adj_byte0    = adj_idx0[2:1];
    wire        adj_nib0     = adj_idx0[0];
    wire [7:0]  sel_byte0    = use_next0 ? layer0_data[adj_byte0] : disp0[adj_byte0];
    wire [3:0]  layer0_pix   = adj_nib0 ? sel_byte0[3:0] : sel_byte0[7:4];

    // Smooth scroll pixel select for Layer 1 (currently unused in Battlantis)
    wire [3:0] adj_idx1      = {1'b0, h_cnt[2:0]} + {1'b0, fine_scroll_latch1};
    wire        use_next1     = adj_idx1[3];
    wire [1:0]  adj_byte1    = adj_idx1[2:1];
    wire        adj_nib1     = adj_idx1[0];
    wire [7:0]  sel_byte1    = use_next1 ? layer1_data[adj_byte1] : disp1[adj_byte1];
    wire [3:0]  layer1_pix   = adj_nib1 ? sel_byte1[3:0] : sel_byte1[7:4];

    // Battlantis uses only Layer 0 for background graphics.
    wire [3:0] final_pix = layer0_pix;

    // MAME's battlnts.cpp tile_callback sets `color = 0` for all tiles, so all
    // background tiles use palette bank 0. This matches the real hardware.
    wire [2:0] final_pal = 3'd0;

    // layer0_priority (attr[7]): when high, Layer 0 renders on TOP of sprites.
    wire layer0_priority = layer0_attr[7];

    // Output: {priority=0, palette_bank[2:0], colour_index[3:0]}
    always @(posedge clk) begin
        if (ce_pix) begin
            pixel_color <= {1'b0, final_pal, final_pix};
        end
    end

    // ==============================================================================
    // TILE CACHE + SDRAM-BACKED FILL
    // ==============================================================================
    // Background tile data lives in a 64KB direct-mapped BRAM cache (2048
    // tiles x 32 bytes), backed by a fill state machine that fetches a
    // missing tile's full 32 bytes via SDRAM Port 2 on a miss. This is the
    // ONLY source of tile data -- no full local ROM copy. Freeing the BRAM a
    // full 256KB tile ROM copy would have used lets the sprite engine
    // (k007420.v) hold its entire 256KB ROM statically instead of a smaller
    // BRAM cache backed by SDRAM overflow -- eliminating sprite SDRAM
    // traffic entirely, which in turn gives this cache's Port 2 fills
    // effectively exclusive access to the SDRAM bus during real gameplay
    // (concurrent access from two independent SDRAM consumers was the actual
    // source of intermittent fill corruption during development, not a bug
    // in the cache/fill logic itself).
    //
    // NO STALLING: a cache miss never pauses the video pipeline (would risk
    // breaking sync). On a miss, the slot keeps whatever was last written
    // there (stale data from a previous tenant, or zero if never filled)
    // until the background fill completes -- a rare, self-correcting,
    // single-frame visual imperfection, not a timing risk.
    //
    // Cache key = {palette, tile index} (13 bits, address bits [17:5] with
    // row/byte stripped): 2048-entry direct-mapped, index = key[10:0], tag =
    // key[12:11].
    localparam TILE_CACHE_ENTRIES = 2048;
    (* ramstyle = "M10K" *) reg [7:0] tile_cache [0:TILE_CACHE_ENTRIES*32-1]; // 64KB: {index[10:0], offset[4:0]}
    reg [1:0]  tile_cache_tag [0:TILE_CACHE_ENTRIES-1];
    reg        tile_cache_valid [0:TILE_CACHE_ENTRIES-1];

    wire [12:0] tap_tile_key   = tap_addr[17:5];
    wire [10:0] tap_tile_index = tap_tile_key[10:0];
    wire [1:0]  tap_tile_tag   = tap_tile_key[12:11];
    wire        tap_tile_claims_hit = tile_cache_valid[tap_tile_index] && (tile_cache_tag[tap_tile_index] == tap_tile_tag);

    // --- Background fill state machine (Port 2: request/wait, 32 bytes per miss) ---
    localparam FILL_IDLE    = 2'd0;
    localparam FILL_REQUEST = 2'd1;
    localparam FILL_WAIT    = 2'd2;

    reg [1:0]  fill_state;
    reg [10:0] fill_index;
    reg [1:0]  fill_tag;
    reg [4:0]  fill_offset;
    reg [24:0] fill_sdram_addr_reg;
    reg        fill_req_reg;
    reg [17:0] tile_last_checked_addr;
    reg        tile_last_checked_valid;

    // Dedicated, minimal read/write block for tile_cache ONLY: a single block
    // with one write (gated by a simple enable) and one unconditional
    // registered read is what Quartus reliably infers as one clean dual-port
    // M10K; entangling the read/write with unrelated logic in nested
    // if/case branches risks Quartus duplicating it into two unsynchronized
    // physical instances instead. Write-forwarding bypass: on Cyclone V
    // M10K, a same-cycle read and write to the same address returns
    // undefined data -- real here, not just theoretical: the render path can
    // revisit the same tile a fill is still populating (a tile spans 8
    // scanlines; a slower fill can still be in flight when a later row of
    // the SAME tile is re-read).
    wire        tile_cache_write_en   = (fill_state == FILL_WAIT) && tile_sdram_ready;
    wire [15:0] tile_cache_write_addr = {fill_index, fill_offset};
    wire [15:0] tile_cache_read_addr  = {vid_tile_index, vid_tile_addr[4:0]};
    reg  [7:0]  tile_cache_dout;
    always @(posedge clk) begin
        if (tile_cache_write_en) tile_cache[tile_cache_write_addr] <= tile_sdram_dout;
        if (tile_cache_write_en && (tile_cache_write_addr == tile_cache_read_addr))
            tile_cache_dout <= tile_sdram_dout;
        else
            tile_cache_dout <= tile_cache[tile_cache_read_addr];
    end
    assign vid_tile_dout_reg = tile_cache_dout;

    integer ci;
    always @(posedge clk) begin
        if (reset) begin
            fill_state <= FILL_IDLE;
            fill_req_reg <= 1'b0;
            tile_last_checked_valid <= 1'b0;
            for (ci = 0; ci < TILE_CACHE_ENTRIES; ci = ci + 1) tile_cache_valid[ci] <= 1'b0;
        end else begin
            // New-tile detection: only process each genuinely-new tile fetch
            // once, not every cycle its already-cached row is re-read.
            if (tap_valid && (!tile_last_checked_valid || tap_addr != tile_last_checked_addr)) begin
                tile_last_checked_addr <= tap_addr;
                tile_last_checked_valid <= 1'b1;
                if (!tap_tile_claims_hit && fill_state == FILL_IDLE) begin
                    // A miss just isn't serviced yet if the fill state
                    // machine is already busy with a different tile -- it'll
                    // be retried automatically next time this same tile is
                    // fetched (every tile is fetched up to 8x/frame, one per
                    // scanline it spans), no queue needed.
                    fill_index <= tap_tile_index;
                    fill_tag   <= tap_tile_tag;
                    fill_offset <= 5'd0;
                    fill_state <= FILL_REQUEST;
                    // Invalidate the slot THE MOMENT eviction starts, not
                    // when the fill completes: otherwise a reader still
                    // wanting the OLD tile at this same index sees the old
                    // tag as a "hit" while the fill is mid-flight, reading a
                    // mix of old bytes and already-overwritten new-tile
                    // bytes.
                    tile_cache_valid[tap_tile_index] <= 1'b0;
                end
            end

            case (fill_state)
                FILL_IDLE: ; // waiting for the trigger above
                FILL_REQUEST: begin
                    fill_sdram_addr_reg <= {7'd0, fill_tag, fill_index, fill_offset} + 25'h60000; // relative -> absolute (tile ROM base)
                    fill_req_reg <= 1'b1;
                    fill_state <= FILL_WAIT;
                end
                FILL_WAIT: begin
                    if (tile_sdram_ready) begin
                        fill_req_reg <= 1'b0;
                        // tile_cache write itself happens in the dedicated
                        // block above; this block only tracks state/offset
                        // progression and the tag/valid update once all 32
                        // bytes have landed.
                        if (fill_offset == 5'd31) begin
                            tile_cache_tag[fill_index]   <= fill_tag;
                            tile_cache_valid[fill_index] <= 1'b1;
                            fill_state <= FILL_IDLE;
                        end else begin
                            fill_offset <= fill_offset + 5'd1;
                            fill_state <= FILL_REQUEST;
                        end
                    end
                end
                default: fill_state <= FILL_IDLE;
            endcase
        end
    end

    assign tile_sdram_req = fill_req_reg;
    assign tile_sdram_addr = fill_sdram_addr_reg;

endmodule
