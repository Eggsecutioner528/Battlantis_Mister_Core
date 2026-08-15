module k007420 (
    input  wire        clk,
    input  wire        reset,

    input  wire        spritebank,

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
    output wire        sprite_active
);

    // ==============================================================================
    // SPRITE RAM (512 Bytes True Dual-Port BRAM)
    // ==============================================================================
    (* ramstyle = "M10K" *) reg [7:0] oam [0:511];

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

    // Read current pixel in off-screen buffer at cur_draw_x[7:0] to prevent lower-priority shadows from overwriting feet/bodies
    wire [7:0] existing_lb_pixel = (buf_sel == 1'b0) ? line_buf_0[cur_draw_x[7:0]] : line_buf_1[cur_draw_x[7:0]];

    // ==============================================================================
    // SPRITE RENDER STATE MACHINE
    // ==============================================================================
    reg [4:0] state;
    reg signed [9:0] spr_y;
    reg [7:0] spr_x, spr_code_lsb, spr_attr, spr_flags, spr_zoom;
    reg [6:0] pix_x;
    reg [4:0] pix_y;
    reg [8:0] oam_addr;

    wire [8:0] eval_v = (v_cnt == 9'd261) ? 9'd0 : (v_cnt + 9'd1);
    wire signed [9:0] true_y_diff = $signed({1'b0, eval_v}) - spr_y;

    wire flip_x = spr_flags[2];
    wire flip_y = spr_flags[3];

    // Sprite size code (spr_flags[6:4]) selects the bounding box: Battlantis uses
    // 16x16 for most enemies/player, but also 32x32 for bosses (Red Dragon, Emperor
    // Asmodeus, Stage 3/6 bosses) and 8x8/8x16/16x8 elsewhere. Hardcoding max=15
    // here previously clamped 32x32 sprites to a 16x16 box, cutting off their
    // bottom/right half. Bounds must track the same size code used by final_8x8_index below.
    // All 5 real MAME size codes explicitly enumerated (rather than lumping
    // 16x16 into a shared default with the genuinely-reserved codes) so only
    // the 3 truly-reserved codes (101/110/111) reach the 8x8 fallback.
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

    // Inverse-scale mapping without a hardware divider: since MAME's scale factor is
    // 0x10000*128/zoom_raw, source_coord = dest_coord * zoom_raw / 128 is algebraically
    // equivalent and needs only a multiply + right-shift (zoom_raw=128 -> 1:1 step;
    // <128 -> source advances slower than dest, i.e. enlarge; >128 -> shrink).
    // 9-bit * 10-bit product needs 19 bits of headroom (max 511*1023 = 522,753).
    wire [19:0] y_mul = true_y_diff[9] ? 20'd0 : ({11'd0, true_y_diff[8:0]} * {10'd0, zoom_raw});
    wire [12:0] tex_y_full = y_mul[19:7];
    wire [4:0]  tex_y_raw  = (tex_y_full > {6'd0, max_y}) ? max_y : tex_y_full[4:0];
    wire [4:0]  tex_y      = tex_y_raw;
    wire [4:0]  actual_y   = flip_y ? (max_y - tex_y) : tex_y;

    wire [16:0] x_mul = {10'd0, pix_x} * {7'd0, zoom_raw};
    wire [9:0]  tex_x_full = x_mul[16:7];
    wire [4:0]  tex_x_raw  = (tex_x_full > {5'd0, max_x}) ? max_x : tex_x_full[4:0];
    wire [4:0]  tex_x      = tex_x_raw;
    wire [4:0]  actual_x   = flip_x ? (max_x - tex_x) : tex_x;

    // Destination-space loop/window bounds: instead of pre-computing a scaled bounding
    // box (which needs division), stop stepping once the mapped SOURCE coordinate has
    // walked past the sprite's native edge. This is what scaled_max_x/y fed into state 5
    // and state 15 previously; now derived from the full-precision mapping above so it
    // works for every zoom_raw value, not just exactly 2x.
    wire sprite_y_in_bounds = (true_y_diff >= 10'sd0) && (tex_y_full <= {6'd0, max_y});
    wire sprite_x_past_edge = (tex_x_full > {5'd0, max_x});

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
    wire signed [9:0] cur_draw_x = signed_spr_x + $signed({5'd0, pix_x});

    // Multiply by 32 bytes per 8x8 tile, then add Y offset (4 bytes per line) and X offset (1 byte per 2 pixels)
    wire [17:0] calc_rom_addr = {final_8x8_index, 5'd0} + {13'd0, actual_y[2:0], 2'd0} + {15'd0, actual_x[2:1]};

    reg last_h_cnt_0;
    reg [6:0] sprite_idx; // 63 down to 0

    // ==============================================================================
    // FULL 256KB STATIC SPRITE ROM
    // ==============================================================================
    // The entire sprite ROM lives in BRAM, addressed directly by calc_rom_addr
    // (0x00000-0x3FFFF relative / 0x20000-0x5FFFF SDRAM IOCTL) -- every sprite
    // fetch is a same-cycle-address-set, next-cycle-data-ready BRAM read, with
    // no per-address routing or SDRAM fallback needed. This is affordable
    // because the background tile ROM (rtl/k007342.v) no longer needs a full
    // local BRAM copy of its own -- it holds only a 2048-entry (64KB) cache,
    // backed by SDRAM on a miss -- freeing enough BRAM for this array to cover
    // the sprite ROM's full 256KB outright.
    // ==============================================================================
    (* ramstyle = "M10K" *) reg [7:0] sprite_rom_bram [0:262143];
    reg [17:0] sprite_bram_addr;
    reg [7:0]  sprite_bram_dout;

    always @(posedge clk) begin
        if (ioctl_wr && ioctl_addr >= 25'h20000 && ioctl_addr < 25'h60000) begin
            sprite_rom_bram[ioctl_addr - 25'h20000] <= ioctl_dout;
        end
        sprite_bram_dout <= sprite_rom_bram[sprite_bram_addr];
    end

    reg [7:0] raw_y;

    always @(posedge clk) begin
        last_h_cnt_0 <= (h_cnt == 0);
        draw_we <= 0;

        if (reset) begin
            state <= 16;
            sprite_idx <= 7'd63;
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
                    // (spr_code_lsb != 0 || spr_attr != 0) clause removed (2026-08-13):
                    // MAME's real sprites_draw() (k007420_mame.cpp) has no code==0/color==0
                    // skip -- it only skips on zoom==0. The clause was also redundant on its
                    // own terms: an unused OAM slot already has raw_y==0 AND zoom==0, both
                    // already checked here, so it added no real protection -- it only ever
                    // incorrectly rejected a genuine, positioned, correctly-zoomed sprite
                    // that happens to use tile 0 with attribute 0.
                    if (raw_y != 8'd0 && zoom_raw != 10'd0 && sprite_y_in_bounds) begin
                        last_byte_valid <= 1'b0; // new sprite: invalidate cache, force a real fetch at pix_x=0
                        state <= 12; // Active scanline: proceed to rendering
                    end else begin
                        sprite_idx <= sprite_idx - 1'd1;
                        state <= 1; // Out of bounds or disabled: skip cleanly
                    end
                end

                12: begin
                    // The entire 256KB sprite ROM is BRAM-resident (see the
                    // array declaration above), so this is always a
                    // same-cycle-address-set, next-cycle-data-ready BRAM
                    // read -- no per-address slot routing or SDRAM fallback.
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
