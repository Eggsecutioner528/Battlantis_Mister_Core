// ==============================================================================
// BATTLANTIS / KONAMI TWIN-16 HARDWARE TEMPLATE
// ==============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_HB = ~VGA_DE;
assign VGA_VB = ~VGA_DE;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'd0;

// ==============================================================================
// HPS IO (Communication with MiSTer Linux)
// ==============================================================================

`include "build_id.v" 
localparam CONF_STR = {
    "Battlantis;;",
    "O[1],Orientation,Horizontal,Vertical;",
    "O[2],Flip Monitor,Off,On;",
    "-;",
    "O[4:3],Aspect ratio,Original,Pixel Perfect,Full Screen;",
    "-;",
    "O[6:5],Lives,7,5,3,2;",
    "O[8:7],Difficulty,Very Difficult,Hard,Normal,Easy;",
    "O[10:9],Bonus Life,50k,40k,40k/80k,30k/70k;",
    "O[11],Demo Sounds,On,Off;",
    "O[12],Cabinet,Upright,Cocktail;",
    "O[13],Flip Screen,Off,On;",
    "O[14],Upright Controls,Single,Dual;",
    "O[15],Mode,Game,Test;",
    "O[16],Continues,5 Times,3 Times;",
    "O[20:17],Coin 1,1C 1C,1C 2C,1C 3C,1C 4C,1C 5C,1C 6C,1C 7C,2C 1C,2C 3C,2C 5C,3C 1C,3C 2C,3C 4C,4C 1C,4C 3C,Free Play;",
    "O[24:21],Coin 2,1C 1C,1C 2C,1C 3C,1C 4C,1C 5C,1C 6C,1C 7C,2C 1C,2C 3C,2C 5C,3C 1C,3C 2C,3C 4C,4C 1C,4C 3C,Free Play;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "V,v",`BUILD_DATE 
};

// Orientation menu (status[1]): Horizontal listed first/default (0),
// Vertical second (1). NOTE: this cabinet's monitor is physically mounted
// such that the DDR3-actively-rotated path (orientation_vertical=1
// internally) visually reads as landscape, and the raw-passthrough path
// (orientation_vertical=0) visually reads as portrait -- the OPPOSITE of
// what the internal wire naming assumes. Label text is intentionally
// swapped relative to the internal wire's own "true portrait/landscape"
// semantics so the menu matches what's actually seen on screen; the wire
// itself is left alone (only CONF_STR text changed here).
//
// Flip Monitor (status[2]) corrects an upside-down mount in either mode:
// for the raw-passthrough path it drives screen_rotate's native `flip`;
// for the actively-rotated path (no separate flip primitive while
// rotating) it picks the rotation direction (CW vs CCW) instead.
wire orientation_vertical = ~status[1];
wire flip_monitor         = status[2];
wire [1:0] ar = status[4:3];

// Aspect ratio must match whichever real shape is on screen: Horizontal
// (raw landscape, true native ratio -- no bezel-cropping concern there)
// needs the literal landscape numbers; Vertical (rotated portrait, may
// sit behind cabinet bezel artwork that slightly crops the top/bottom of
// the visible area on some MisterCade builds) needs a slight vertical
// squish -- a ratio closer to square than the true native 7:8 -- instead
// of a clean transpose. Explicit per-orientation tables, not a shared
// transpose formula: ar==0 (Original) Vertical=10:9, Horizontal=4:3;
// ar==1 (Pixel Perfect) Vertical=13:12, Horizontal=8:7 (literal); ar==2
// (Full Screen) is 0:0 (no fixed ratio) either way.
wire [11:0] vert_arx  = (ar == 2'd0) ? 12'd10 : (ar == 2'd1) ? 12'd13 : 12'd0;
wire [11:0] vert_ary  = (ar == 2'd0) ? 12'd9  : (ar == 2'd1) ? 12'd12 : 12'd0;
wire [11:0] horiz_arx = (ar == 2'd0) ? 12'd4  : (ar == 2'd1) ? 12'd8  : 12'd0;
wire [11:0] horiz_ary = (ar == 2'd0) ? 12'd3  : (ar == 2'd1) ? 12'd7  : 12'd0;
assign VIDEO_ARX = orientation_vertical ? vert_arx : horiz_arx;
assign VIDEO_ARY = orientation_vertical ? vert_ary : horiz_ary;

wire [1:0] buttons;
wire [127:0] status;
wire ioctl_download;
wire ioctl_wr;
wire [24:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire ioctl_wait;
wire [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;

hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    
    .buttons(buttons),
    .status(status),
    .status_menumask(0),
    
    .ps2_key(ps2_key),
    
    .joystick_0(joystick_0),
    .joystick_1(joystick_1),

    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait)
);

// ==============================================================================
// ROM DOWNLOAD TO SDRAM & DDR3 FRAMEBUFFER ROTATION
// ==============================================================================

wire [15:0] sdram_dout;
wire sdram_ready;
wire sdram_rd;
wire sdram_we;
wire [24:0] sdram_addr_in;
wire [1:0] sdram_wtbt;
wire [15:0] sdram_din;

sdram sdram_inst (
    .init(~locked),
    .clk(clk_sys), 
    
    // SDRAM pins
    .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_A(SDRAM_A),
    .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA),
    .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CKE(SDRAM_CKE),
    .SDRAM_CLK(SDRAM_CLK),

    // Interface
    .wtbt(sdram_wtbt),
    .addr(sdram_addr_in),
    .dout(sdram_dout),
    .din(sdram_din),
    .we(sdram_we),
    .rd(sdram_rd),
    .ready(sdram_ready)
);

    // ==============================================================================
    // MAIN CPU ROM (96KB in BRAM: 64KB Banked + 32KB Fixed)
    // ==============================================================================
    (* ramstyle = "M10K" *) reg [7:0] banked_rom [0:65535];
    (* ramstyle = "M10K" *) reg [7:0] fixed_rom [0:32767];

    always @(posedge clk_sys) begin
        if (ioctl_download && ioctl_wr) begin
            if (ioctl_addr < 25'h10000) begin
                banked_rom[ioctl_addr[15:0]] <= ioctl_dout;
            end else if (ioctl_addr >= 25'h10000 && ioctl_addr < 25'h18000) begin
                fixed_rom[ioctl_addr[14:0]] <= ioctl_dout;
            end
        end
    end

    reg [7:0] fixed_rom_dout;
    reg [7:0] banked_rom_dout;

    always @(posedge clk_sys) begin
        fixed_rom_dout  <= fixed_rom[cpu_addr[14:0]];
        banked_rom_dout <= banked_rom[{rom_bank[1:0], cpu_addr[13:0]}];
    end
    wire [7:0] cpu_rom_dout = (cpu_addr >= 16'h8000) ? fixed_rom_dout : banked_rom_dout;

    wire cpu_sdram_req = 1'b0;
    wire [24:0] cpu_sdram_addr = 25'd0;
    wire [7:0] cpu_sdram_dout_raw;
    wire cpu_sdram_ready;

    wire tile_sdram_req = 1'b0;
    wire [24:0] tile_sdram_addr = 25'd0;
    wire [7:0] tile_sdram_dout;
    wire tile_sdram_ready;

    wire sprite_sdram_req;
    wire [24:0] sprite_sdram_addr;
    wire [7:0] sprite_sdram_dout;
    wire sprite_sdram_ready;

wire p0_ready;
sdram_arbiter arbiter (
    .clk(clk_sys),
    .reset(sys_reset),

    // Port 0: IOCTL (Write Only)
    .p0_req(ioctl_download & ioctl_wr),
    .p0_addr(ioctl_addr),
    .p0_din(ioctl_dout),
    .p0_ready(p0_ready),
    .p0_busy(ioctl_wait),

    // Port 1: Main CPU (Read Only)
    .p1_req(cpu_sdram_req),
    .p1_addr(cpu_sdram_addr),
    .p1_dout(cpu_sdram_dout_raw),
    .p1_ready(cpu_sdram_ready),

    // Port 2: Tilemap (Unused - Available)
    .p2_req(tile_sdram_req),
    .p2_addr(tile_sdram_addr),
    .p2_dout(tile_sdram_dout),
    .p2_ready(tile_sdram_ready),

    // Port 3: Sprites (Unused - Available)
    .p3_req(sprite_sdram_req),
    .p3_addr(sprite_sdram_addr),
    .p3_dout(sprite_sdram_dout),
    .p3_ready(sprite_sdram_ready),

    // SDRAM Controller Interface
    .sdram_addr(sdram_addr_in),
    .sdram_rd(sdram_rd),
    .sdram_we(sdram_we),
    .sdram_din(sdram_din),
    .sdram_dout(sdram_dout),
    .sdram_ready(sdram_ready),
    .sdram_wtbt(sdram_wtbt)
);



// CLOCKS
wire clk_sys;
wire locked;

pll pll(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys), // Needs to be 48MHz
	.locked(locked)
);

reg [2:0] clk_div = 0;
always @(posedge clk_sys) clk_div <= clk_div + 1'd1;
wire clk_12m = (clk_div[1:0] == 2'b11); // 48 / 4 = 12 MHz for CPU EXTAL, 1-cycle pulse
reg ce_pix = 0;
always @(posedge clk_sys) ce_pix <= (clk_div == 3'd7); // 48 / 8 = 6 MHz for pixel clock, registered to avoid glitches

// ==============================================================================
// MAIN CPU (MC6809 / HD6309)
// ==============================================================================
wire [15:0] cpu_addr;
wire [7:0] cpu_dout;
wire [7:0] cpu_din;
wire cpu_rw;
wire cpu_we = ~cpu_rw;

// Generate 3MHz E and Q clocks
reg [1:0] cpu_clk_div = 0;
always @(posedge clk_sys) begin
    if (clk_12m) begin
        cpu_clk_div <= cpu_clk_div + 1'd1;
    end
end
wire ce_cpu = (clk_12m && cpu_clk_div == 2'b00);
wire cpu_q = (cpu_clk_div == 2'b01 || cpu_clk_div == 2'b10); // High for phase 1,2
wire cpu_e = (cpu_clk_div == 2'b10 || cpu_clk_div == 2'b11); // High for phase 2,3

wire k007342_irq; // Interrupt from K007342, driven on vblank when interrupts enabled

mc6809i mc6809_inst (
    .D(cpu_din),
    .DOut(cpu_dout),
    .ADDR(cpu_addr),
    .RnW(cpu_rw),
    .E(cpu_e),
    .Q(cpu_q),
    .BS(),
    .BA(),
    .nIRQ(~k007342_irq),
    .nFIRQ(1'b1),
    .nNMI(1'b1),
    .AVMA(),
    .BUSY(),
    .LIC(),
    .nRESET(~reset),
    .nDMABREQ(1'b1),
    .nHALT(1'b1)
);



// IRQ is generated and managed internally by k007342.
// k007342_irq is asserted on vblank when int_enabled=1, cleared on irq_ack.

// sys_reset combines the framework's hardware RESET input, the OSD's Reset
// option (status[0], from T[0]/R[0] in CONF_STR), and the joystick reset
// button (buttons[1]) — standard MiSTer template pattern (see Template.sv:120).
// This was previously undriven (an implicit net), so none of these ever
// actually reset the core - only ioctl_download (ROM loading) did.
wire sys_reset = RESET | status[0] | buttons[1];
wire reset = sys_reset | ioctl_download;

// CLK_VIDEO and CE_PIXEL are driven directly by arcade_video module below

reg [10:0] h_cnt = 0;
reg [9:0] v_cnt = 0;
wire h_sync, v_sync;

always @(posedge clk_sys) begin
    if (ce_pix) begin
        if (h_cnt == 383) begin // H-total = 384 (6MHz / 384 = 15.625 kHz)
            h_cnt <= 0;
            v_cnt <= (v_cnt == 261) ? 0 : v_cnt + 1; // V-total = 262 (15625 / 262 = 59.6 Hz)
        end else begin
            h_cnt <= h_cnt + 1;
        end
    end
end

// ==============================================================================
// K007342 TILEMAP GENERATOR (0x0000 - 0x1FFF)
// ==============================================================================

wire [7:0] k007342_dout;
wire [7:0] k007342_pixel;
wire k007342_we = cpu_rw == 1'b0 && (cpu_addr <= 16'h1FFF || (cpu_addr >= 16'h2600 && cpu_addr <= 16'h2607));
wire k007342_re = cpu_rw == 1'b1 && (cpu_addr <= 16'h1FFF || (cpu_addr >= 16'h2600 && cpu_addr <= 16'h2607));
wire k007342_scroll_we = cpu_rw == 1'b0 && (cpu_addr >= 16'h2200 && cpu_addr <= 16'h23FF);
wire k007342_scroll_re = cpu_rw == 1'b1 && (cpu_addr >= 16'h2200 && cpu_addr <= 16'h23FF);
wire [7:0] k007342_scroll_dout;

reg k007342_vram_bank; // Bankswitch for VRAM attributes


wire vblank;
wire k007342_int_enabled;

// irq_ack: K007342 internal IRQ flag is cleared when CPU acknowledges the interrupt.
// The 6809 does this by reading the interrupt vector (0xFFF8-0xFFFF during IRQ service).
wire k007342_irq_ack = cpu_e & cpu_rw & (cpu_addr >= 16'hFFF8);

k007342 k007342_inst (
    .clk(clk_sys),
    .reset(reset),
    
    .vblank(vblank),
    .int_enabled(k007342_int_enabled),
    .vram_bank(k007342_vram_bank),
    
    .cpu_addr(cpu_addr[13:0]),
    .cpu_din(cpu_dout),
    .cpu_dout(k007342_dout),
    .cpu_we(k007342_we),
    .cpu_re(k007342_re),
    
    .scroll_addr(cpu_addr[8:0]),
    .scroll_din(cpu_dout),
    .scroll_dout(k007342_scroll_dout),
    .scroll_we(k007342_scroll_we),
    
    .ce_pix(ce_pix),
    .h_cnt(h_cnt[8:0]),
    .v_cnt(v_cnt[8:0]),
    
    .ioctl_wr(ioctl_download & ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    
    .irq(k007342_irq),
    .irq_ack(k007342_irq_ack),
    .pixel_color(k007342_pixel)
);

// ==============================================================================
// K007420 SPRITE GENERATOR (0x2000 - 0x21FF)
// ==============================================================================

wire [7:0] k007420_dout;
wire [7:0] k007420_pixel;
wire k007420_active;
reg k051937_sprite_enable; // Sprite RAM enable flag at 0x2400

wire k007420_we = cpu_rw == 1'b0 && (cpu_addr >= 16'h2000 && cpu_addr <= 16'h21FF);
wire k007420_re = cpu_rw == 1'b1 && (cpu_addr >= 16'h2000 && cpu_addr <= 16'h21FF);



wire [15:0] sprite_diag_req_count;
wire [15:0] sprite_diag_ready_count;

k007420 sprite_gen (
    .clk(clk_sys),
    .reset(reset),
    
    .spritebank(sprite_bank), // Pass sprite_bank to k007420
    
    .cpu_addr(cpu_addr[8:0]),
    .cpu_din(cpu_dout),
    .cpu_dout(k007420_dout),
    .cpu_we(k007420_we),
    
    .ce_pix(ce_pix),
    .h_cnt(h_cnt[8:0]),
    .v_cnt(v_cnt[8:0]),
    
    .ioctl_wr(ioctl_download & ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    
    .sprite_color(k007420_pixel),
    .sprite_active(k007420_active),
    
    .sprite_sdram_req(sprite_sdram_req),
    .sprite_sdram_addr(sprite_sdram_addr),
    .sprite_sdram_dout(sprite_sdram_dout),
    .sprite_sdram_ready(sprite_sdram_ready),
    
    .diag_sdram_req_count(sprite_diag_req_count),
    .diag_sdram_ready_count(sprite_diag_ready_count),
    .has_non_zero_rom_out(sprite_has_non_zero_rom)
);

// ==============================================================================
// PALETTE RAM (1024 x 8-bit = 512 16-bit xBGR_555 entries)
// ==============================================================================
reg [7:0] palette_ram [0:1023];

wire [7:0] bg_pixel     = k007342_pixel;
wire [7:0] sprite_pixel = k007420_pixel;

// ==============================================================================
// PIXEL MIXER — Sprite / Background priority
// ==============================================================================
// The K007420 line buffer holds sprite pixels, and k007342 holds background.
// Both output an 8-bit palette index.
// ==============================================================================
wire bg_priority    = bg_pixel[7];
wire sprite_visible = k007420_active && sprite_pixel[3:0] != 4'd0;
wire bg_visible     = bg_pixel[3:0] != 4'd0;

// Per-tile priority: k007342_mame.cpp:278 sets tileinfo.category = (color & 0x80) >> 7,
// and battlnts_mame.cpp's screen_update() draws category-1 tiles OPAQUE in a second
// pass AFTER sprites (map(0x2400,0x24ff)... tilemap_draw(...,0,TILEMAP_DRAW_OPAQUE,0);
// sprites_draw(...); tilemap_draw(...,0,1|TILEMAP_DRAW_OPAQUE,0)). So a background tile
// with attr[7]=1 must render OVER sprites, opaque regardless of its own pixel value.
wire show_sprite = sprite_visible && !bg_priority;

// pixel_color: which palette index to look up.
wire [7:0] pixel_color = show_sprite ? sprite_pixel : bg_pixel;

// Palette RAM lookup: each entry is 2 bytes (xBGR_555 Big-Endian format)
// 16-bit word = {even_byte, odd_byte} = {xBBBBBGG, GGGRRRRR}
// Even byte (addr[0]=0): { x, B[4:0], G[4:3] } = bits [15:8] of 16-bit word
// Odd byte  (addr[0]=1): { G[2:0], R[4:0] }   = bits [7:0] of 16-bit word
reg [7:0] pal_byte_even, pal_byte_odd;

always @(posedge clk_sys) begin
    if (ce_pix) begin
        pal_byte_even     <= palette_ram[{pixel_color, 1'b0}];
        pal_byte_odd      <= palette_ram[{pixel_color, 1'b1}];
    end
end

wire [4:0] pal_r = pal_byte_odd[4:0];                       // Red: bits [4:0] of 16-bit word (odd byte)
wire [4:0] pal_g = {pal_byte_even[1:0], pal_byte_odd[7:5]}; // Green: bits [9:5] of 16-bit word
wire [4:0] pal_b = pal_byte_even[6:2];                      // Blue: bits [14:10] of 16-bit word (even byte)

// Expand 5-bit palette channels to 8-bit output (replicate top 3 bits into low 3 bits)
wire [7:0] vga_r = {pal_r, pal_r[4:2]};
wire [7:0] vga_g = {pal_g, pal_g[4:2]};
wire [7:0] vga_b = {pal_b, pal_b[4:2]};

// Bankswitch & Control Registers
  reg [1:0] rom_bank;
  reg sprite_bank;
  reg sound_irq_trigger;
  reg watchdog_timer;
  reg [7:0] sound_latch;
  reg sound_irq;

  always @(posedge clk_sys) begin
      sound_irq <= 1'b0;
      if (reset) begin
          rom_bank <= 2'b00;
          sprite_bank <= 1'b0;
          sound_irq_trigger <= 1'b0;
          k007342_vram_bank <= 1'b0;
          k051937_sprite_enable <= 1'b0;
          sound_latch <= 8'd0;
      end else if (cpu_we) begin
          if (cpu_addr == 16'h2e08) begin
              k007342_vram_bank <= 1'b0; // Battlantis has single flat 8KB VRAM (no VRAM banking)
              rom_bank <= cpu_dout[7:6]; // ROM bank index is in bits 7 and 6
          end
          if (cpu_addr >= 16'h2400 && cpu_addr <= 16'h27FF) palette_ram[cpu_addr[9:0]] <= cpu_dout;
          if (cpu_addr == 16'h2e10) watchdog_timer <= 0;
          if (cpu_addr == 16'h2e0c) sprite_bank <= cpu_dout[0];
          if (cpu_addr == 16'h2e14) sound_latch <= cpu_dout;
          if (cpu_addr == 16'h2e18) begin
              sound_irq_trigger <= 1'b1;
              sound_irq <= 1'b1;
          end
      end
  end

// ==============================================================================
// MEMORY SUBSYSTEM
// ==============================================================================

// Inputs
// Coinage (DSW1): matches MAME's KONAMI_COINAGE_LOC table / the manual's
// Coin 1 (SW1-4) and Coin 2 (SW5-8) tables exactly. Switches are active
// low (OFF=1), so each nibble is the bitwise NOT of the OSD's 0-15 index
// (index 0 = all switches OFF = 1 Coin/1 Credit, matching the default).
wire [3:0] coin1_opt = status[20:17];
wire [3:0] coin2_opt = status[24:21];
wire [7:0] dip_switch_1 = {~coin2_opt, ~coin1_opt};

// DIP Switch 2 mapping from OSD
wire [1:0] lives_opt = status[6:5];   // 00=7, 01=5, 10=3, 11=2
wire [1:0] diff_opt  = status[8:7];   // 00=Very Diff, 01=Diff, 10=Normal, 11=Easy
wire [1:0] bonus_opt = status[10:9];  // 00=50k, 01=40k, 10=40k/80k, 11=30k/70k
wire demo_opt        = status[11];    // 0=On, 1=Off
wire cab_opt         = status[12];    // 0=Upright (0x00), 1=Cocktail (0x04)
wire [7:0] dip_switch_2 = (status[16:0] == 17'd0) ? 8'hA6 : { demo_opt, diff_opt, bonus_opt, cab_opt, lives_opt }; 

// DSW3: bit 0: Coin1, bit 1: Coin2, bit 3: Start1, bit 4: Start2
wire m_coin1  = joystick_0[5] | joystick_1[5]; // Usually Select/Coin
wire m_start1 = joystick_0[7];
wire m_start2 = joystick_1[7];
wire flip_opt = status[13]; // 0=Off (0x20), 1=On (0x00)
wire ctrl_opt = status[14]; // 0=Single (0x40), 1=Dual (0x00)
wire test_opt = status[15]; // 0=Game (0x00), 1=Test (0x80)
wire cont_opt = status[16]; // 0=5 Times (0x00, factory default per manual/MAME), 1=3 Times (0x80)
wire [7:0] dip_switch_3 = (status[16:0] == 17'd0) ? {1'b1, 2'b11, ~m_start2, ~m_start1, 2'b11, ~m_coin1} : {~test_opt, ~ctrl_opt, ~flip_opt, ~m_start2, ~m_start1, 2'b11, ~m_coin1};

// Bit 7 (MAME PORT_DIPNAME 0x80 on the P1 port, not DSW3) is the
// Allow_Continue DIP -- was previously hardcoded to 1'b1 (always "3
// Times"), leaving the "Continues" OSD option wired to nothing.
wire [7:0] player_1_inputs = {cont_opt, 2'b11, ~joystick_0[4], ~joystick_0[3], ~joystick_0[2], ~joystick_0[0], ~joystick_0[1]};
wire [7:0] player_2_inputs = 8'hFF; // Unused for now, default to unpressed

// 4KB Work RAM (0x3000 - 0x3FFF)
(* ramstyle = "M10K" *) reg [7:0] work_ram [0:4095];
reg [7:0] work_ram_dout;
always @(posedge clk_sys) begin
    if (cpu_we && (cpu_addr >= 16'h3000 && cpu_addr <= 16'h3FFF)) begin
        work_ram[cpu_addr[11:0]] <= cpu_dout;
    end
    work_ram_dout <= work_ram[cpu_addr[11:0]];
end



// Z80 3.58 MHz Clock Enable Generator (48 MHz / 13)
reg [3:0] z80_clk_cnt;
always @(posedge clk_sys) begin
    z80_clk_cnt <= (z80_clk_cnt == 4'd12) ? 4'd0 : z80_clk_cnt + 1'b1;
end
wire ce_z80 = (z80_clk_cnt == 4'd0);

wire ioctl_sound_we = ioctl_download && ioctl_wr && (ioctl_addr >= 25'h18000 && ioctl_addr < 25'h20000);
wire [14:0] ioctl_sound_addr = ioctl_addr[14:0];
wire signed [15:0] audio_l, audio_r;

battlantis_sound battlantis_sound (
    .clk(clk_sys),
    .rst(reset),
    .ce_z80(ce_z80),
    .snd_latch(sound_latch),
    .snd_irq(sound_irq),
    .ioctl_sound_addr(ioctl_sound_addr),
    .ioctl_sound_data(ioctl_dout[7:0]),
    .ioctl_sound_we(ioctl_sound_we),
    .audio_l(audio_l),
    .audio_r(audio_r)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

  reg [7:0] cpu_data_in_reg;
  always @(*) begin
      if (cpu_addr <= 16'h1FFF) cpu_data_in_reg = k007342_dout;
      else if (cpu_addr >= 16'h2000 && cpu_addr <= 16'h21FF) cpu_data_in_reg = k007420_dout;
      else if (cpu_addr >= 16'h2200 && cpu_addr <= 16'h23FF) cpu_data_in_reg = k007342_scroll_dout;
      else if (cpu_addr >= 16'h2400 && cpu_addr <= 16'h27FF) cpu_data_in_reg = palette_ram[cpu_addr[9:0]];
      else if (cpu_addr >= 16'h2600 && cpu_addr <= 16'h2607) cpu_data_in_reg = k007342_dout;
      else if (cpu_addr >= 16'h3000 && cpu_addr <= 16'h3FFF) cpu_data_in_reg = work_ram_dout;
      else if (cpu_addr >= 16'h2e00 && cpu_addr <= 16'h2e07) begin
          case (cpu_addr[2:0])
              3'd0: cpu_data_in_reg = dip_switch_1;
              3'd1: cpu_data_in_reg = player_2_inputs;
              3'd2: cpu_data_in_reg = player_1_inputs;
              3'd3: cpu_data_in_reg = dip_switch_3;
              3'd4: cpu_data_in_reg = dip_switch_2;
              default: cpu_data_in_reg = 8'hFF;
          endcase
      end
      else cpu_data_in_reg = 8'hFF; // Default unmapped memory returns FF
  end

assign cpu_din = (cpu_addr >= 16'h4000) ? cpu_rom_dout : cpu_data_in_reg;


// ==============================================================================
// FRAMEWORK SAFE-TIES (Displaying VRAM data)
// ==============================================================================

// Define the active display area (the "canvas" where the game renders).
// Per MAME's screen.set_raw(24_MHz_XTAL/4, 384, 0, 256, 264, 16, 240) for
// battlnts, real hardware's active vertical window is v_cnt 16..239 (still
// 224 lines), NOT 0..223. We were treating v_cnt 0..223 as active, which
// showed 2 tile-rows too early at the top (whatever's in VRAM rows 0-1) and
// cropped 2 real rows off the bottom -- invisible on busy/scrolling gameplay
// content, but a clean ~16px (2-tile-row) downward shift on any static,
// symmetric screen (confirmed via the attract-mode kill-count screen's
// black square, measured off-center by almost exactly this amount).
// v_cnt itself and the tile-fetch pipeline (next_v, etc.) are untouched --
// only which slice of the already-computed v_cnt range counts as on-screen.
wire active_area = (h_cnt < 256 && (v_cnt >= 16 && v_cnt < 240));

// The pixel color pipeline lags h_cnt by 2 ce_pix cycles: 1 cycle in k007342's own
// registered pixel_color output, plus 1 more cycle in the palette RAM lookup below
// (pal_byte_even/odd). active_area/VGA_DE was being asserted on the raw, undelayed
// h_cnt, so the display window "opened" 2 pixels before real column-0 data actually
// arrived - the first 2 columns showed stale blanking-period data (visible as a
// slightly short/cropped left edge, most noticeable once Pixel Perfect removed the
// stretching that had been masking it). Delaying active_area by the same 2 cycles
// for display timing (leaving h_sync/v_sync pulse timing untouched) fixes the
// alignment without touching the tile-fetch pipeline itself.
reg [1:0] active_area_sr;
always @(posedge clk_sys) if (ce_pix) active_area_sr <= {active_area_sr[0], active_area};
wire active_area_disp = active_area_sr[1];

// NTSC Standard Porches:
// Back porch should be ~4.7us (30 pixels @ 6.25MHz). Sync ~4.7us (30 pixels).
// Setting h_sync near the end of the line ensures the back porch is correct.
assign h_sync = (h_cnt >= 320 && h_cnt < 352); // Active HIGH sync pulses
assign v_sync = (v_cnt >= 244 && v_cnt < 247); // Active HIGH sync
// no_rotate=1: raw passthrough, DDR3 bypassed entirely (menu label
// "Vertical" on this cabinet -- see orientation_vertical comment above).
// no_rotate=0: actively rotated via DDR3 (menu label "Horizontal", the
// default). Flip Monitor: for the raw-passthrough path it drives
// screen_rotate's native `flip` (180 degree flip, only used when
// no_rotate=1 -- screen_rotate ignores it otherwise); for the
// actively-rotated path it picks the rotation direction (CW vs CCW)
// since there's no separate flip primitive while rotating. Both
// confirmed on hardware to need the direct (non-inverted) flip_monitor
// mapping: rotate_ccw=0 / flip=0 at Flip off gives the correct
// orientation in each respective path.
wire no_rotate  = ~orientation_vertical;
wire rotate_ccw = flip_monitor;
wire flip       = flip_monitor;
wire video_rotated;

// screen_rotate must consume arcade_video's OUTPUT (post-video_mixer VGA_R/
// G/B/HS/VS/DE/CE_PIXEL), not the core's raw pre-mixer signals. Test 119
// found that feeding it the raw signals (as this used to) corrupted the
// picture: every prior hardware confirmation this session validated video
// timing only through the arcade_video/video_mixer output path (no_rotate=1
// bypassed screen_rotate entirely), so that pipelined/resampled signal is
// the one screen_rotate's auto-measured hsz/vsz and DDR3 write gating
// actually need to match -- not the earlier raw core-side timing. Matches
// the reference wiring pattern in jtcores_ref's jtframe_mister.sv, where
// screen_rotate is chained off arcade_video's scan2x_* outputs, not the
// core's raw video.
screen_rotate screen_rotate (
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R),
    .VGA_G(VGA_G),
    .VGA_B(VGA_B),
    .VGA_HS(VGA_HS),
    .VGA_VS(VGA_VS),
    .VGA_DE(VGA_DE),
    .rotate_ccw(rotate_ccw),
    .no_rotate(no_rotate),
    .flip(flip),
    .video_rotated(video_rotated),
    .FB_EN(FB_EN),
    .FB_FORMAT(FB_FORMAT),
    .FB_WIDTH(FB_WIDTH),
    .FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE),
    .FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL),
    .FB_LL(FB_LL),
    .DDRAM_CLK(DDRAM_CLK),
    .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DIN(DDRAM_DIN),
    .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE),
    .DDRAM_RD(DDRAM_RD)
);

wire [21:0] gamma_bus;

arcade_video #(256, 24) arcade_video (
    .clk_video(clk_sys),
    .ce_pix(ce_pix),
    .RGB_in({vga_r, vga_g, vga_b}),
    .HBlank(~active_area_disp),
    .VBlank(~(v_cnt >= 16 && v_cnt < 240)),
    .HSync(h_sync),
    .VSync(v_sync),
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R),
    .VGA_G(VGA_G),
    .VGA_B(VGA_B),
    .VGA_HS(VGA_HS),
    .VGA_VS(VGA_VS),
    .VGA_DE(VGA_DE),
    .VGA_SL(VGA_SL),
    .fx(status[17:15]),
    .forced_scandoubler(0),
    .gamma_bus(gamma_bus)
);

  reg [23:0] cpu_heartbeat;
  reg oam_write_flag;
  always @(posedge clk_sys) begin
      if (ce_pix) cpu_heartbeat <= cpu_heartbeat + 1'd1;
      if (k007420_we) oam_write_flag <= 1'b1;
  end

  assign LED_USER  = cpu_heartbeat[18]; // Blinks if CPU is running
  assign LED_POWER = 0;
  // SDRAM DIAGNOSTIC LEDs:
  // LED_DISK[0] = blinks if SDRAM requests are being issued (req_count > 0)
  // LED_DISK[1] = blinks if SDRAM ready responses arrive (ready_count > 0)
  // Both ON = handshake works. Only [0] ON = state machine stalls in state 14.
  assign LED_DISK  = {sprite_diag_ready_count[8], sprite_diag_req_count[8]};

endmodule
