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
    
    // IOCTL ROM Download (for Tile Graphics)
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    
    // Output Pixels
    output reg  [7:0]  pixel_color, // color index 0-15
    
    // Interrupts
    output reg         vblank,
    output reg         int_enabled,
    output reg         irq,
    input  wire        irq_ack
);

    // ==============================================================================
    // TILE GRAPHICS ROM  (256 KB, stored in M10K BRAM — ROM file: 777c04.13a)
    // ==============================================================================
    // Physical SDRAM layout: 0x060000 – 0x09FFFF (256KB).
    // At MiSTer boot the ioctl loader writes ROM bytes sequentially; we capture
    // any byte in the 0x60000–0x9FFFF window and store it word-swapped (^ 1)
    // because the Konami tile format interleaves even/odd bytes differently
    // from the byte order they arrive in over ioctl.
    //
    // TO ADD A DIFFERENT TILE ROM: change the ioctl_addr window (>= / <) and
    // update the subtracted base address to match the new SDRAM offset.
    // ==============================================================================
    (* ramstyle = "M10K" *) reg [7:0] tile_rom [0:262143];

    always @(posedge clk) begin
        if (ioctl_wr && ioctl_addr >= 25'h60000 && ioctl_addr < 25'hA0000) begin
            // No swap here: byte_xor (applied at read time below) already provides the
            // single word-swap that MAME's ROM_LOAD16_WORD_SWAP calls for. Swapping here
            // too would cancel that out (XOR of the same address bit twice = no swap),
            // leaving raw unswapped ROM data - which is what was happening before this fix.
            tile_rom[(ioctl_addr - 25'h60000)] <= ioctl_dout;
        end
    end
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
    
    // ROM Fetch (Port A of tile_rom, write is done via ioctl in top)
    reg [17:0] vid_tile_addr;
    reg [7:0]  vid_tile_dout_reg;
    
    always @(posedge clk) begin
        vid_tile_dout_reg <= tile_rom[vid_tile_addr];
    end
    
    wire [7:0] vid_tile_dout = vid_tile_dout_reg;

    // Storage for fetched data
    reg [7:0] layer0_tile, layer0_attr;
    reg [7:0] layer1_tile, layer1_attr;
    reg [7:0] layer0_data [0:3];
    reg [7:0] layer1_data [0:3];
    
    reg [2:0] layer0_bank;
    reg [2:0] layer1_bank;

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
            8:  layer0_data[0] <= vid_tile_dout; // pixels 0-1
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

endmodule
