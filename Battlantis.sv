//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// SDRAM pins driven for real below (Round 7 -- tile/sprite graphics ROM
// storage, ported from Battlantis's proven sdram.sv/sdram_arbiter.sv).
// DDRAM_* belong to screen_rotate (the HDMI rotation framebuffer, see the video output section at the end of this file); VGA_SL comes
// from arcade_video.
assign FB_FORCE_BLANK = 1'b0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1; // signed
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// HDMI picture options (same menu bits, labels and screen_rotate wiring as Battlantis, confirmed on this board):
//   Orientation (status[1]): Horizontal (0, default) = the picture is rotated in DDR3 by screen_rotate so the vertical monitor game is upright
//   (portrait, pillar boxed) on a normal landscape display; Vertical (1) = raw passthrough, for a display that is itself mounted vertically.
//   Flip Monitor (status[2]) turns the picture 180 degrees; it is combined (xor) with the game's own flip request (K007342 reg 0 bit 4,
//   set by the game when its Flip Screen DIP is on), the way a real board combines a DIP and a software flip source.
//   Aspect ratio (status[4:3]): Original (the arcade monitor's 4:3, shown as 3:4 once rotated), Pixel Perfect (square pixels, 8:7 raw or
//   7:8 rotated), Full Screen (no fixed ratio). The CRT / analog output is not touched by any of these: it stays the raw 15 kHz raster.
wire        orientation_vertical = status[1];
wire        no_rotate    = orientation_vertical;
wire        flip_monitor = status[2];
wire  [1:0] ar           = status[4:3];
wire [11:0] raw_arx = (ar == 2'd0) ? 12'd4 : (ar == 2'd1) ? 12'd8 : 12'd0;
wire [11:0] raw_ary = (ar == 2'd0) ? 12'd3 : (ar == 2'd1) ? 12'd7 : 12'd0;
wire [11:0] rot_arx = (ar == 2'd0) ? 12'd3 : (ar == 2'd1) ? 12'd7 : 12'd0;
wire [11:0] rot_ary = (ar == 2'd0) ? 12'd4 : (ar == 2'd1) ? 12'd8 : 12'd0;
assign VIDEO_ARX = no_rotate ? raw_arx : rot_arx;
assign VIDEO_ARY = no_rotate ? raw_ary : rot_ary;

// CRT rotation (analog output) through the DDR3 hub, independent of the HDMI options above. CRT Orientation Horizontal (status[53]) rotates and scales
// the CRT picture, CRT Flip (status[59]) turns it by 180 degrees in either orientation, CRT Size (status[58:54]) lists the default size first (182x208:
// 13 / 16 of the game's pixels, so the 16 pixel grid cells come out exactly 13 pixels wide), then larger, then smaller.
wire        crt_rot_sel    = status[53];                 // CRT Orientation Horizontal (rotated)
wire        crt_flip       = status[59];                 // CRT Flip (180 degrees), in both orientations
wire  [4:0] crt_size_idx   = status[58:54];              // 0..15 the listed sizes (default first, then larger, then smaller)
wire  [3:0] crt_size_n     = (crt_size_idx > 5'd15) ? 4'd0 : crt_size_idx[3:0];   // a value from an older build's list (with Auto) falls back to the default
wire  [3:0] crt_size       = (crt_size_n <= 4'd3) ? (4'd12 + crt_size_n) : (4'd15 - crt_size_n);
// CRT position: the V and H options always mean what you see on the CRT. Rotated, the horizontal option moves along the raster lines (hs shift);
// raw (a portrait CRT, raster up and down) the vertical option does.
wire  [3:0] crt_hs_step    = crt_rot_sel ? status[49:46] : status[45:42];
wire  [3:0] crt_vs_step    = crt_rot_sel ? status[45:42] : status[49:46];
wire  [7:0] crt_r, crt_g, crt_b;
wire        crt_hs, crt_vs, crt_de;
wire        crt_ready;
wire  [1:0] crt_status;

`include "build_id.v"
// Round 9 (2026-09-12): real DIP switches, confirmed directly from
// bladestl_mame.cpp's INPUT_PORTS_START(bladestl_joy)/konamipt.h's
// KONAMI_COINAGE_ALT_LOC macro. Coin A/B each get the real 16-entry
// Konami coinage table (see the case-statement translation in the DIP
// section below) rather than a raw hex/bitfield OSD control, so the OSD
// labels match what a player would actually see on real hardware.
localparam CONF_STR = {
	"Battlantis;;",
	"-;",
	// Which game to run comes first, then a gap, then the sub pages (Video, Sound Settings and DIP Switches), then the reset entries.
	"O[41:40],Game Version,Battlantis (version G),Battlantis (version F),Battlantis (Japan version E);",
	"-;",
	"P1,Video;",
	"P1O[1],HDMI Orientation,Horizontal,Vertical;",
	"P1O[2],Flip Monitor,Off,On;",
	"P1O[4:3],Aspect ratio,Original,Pixel Perfect,Full Screen;",
	"P1-;",
	// CRT (analog output), independent of the HDMI options above. Orientation Vertical (raw) is the unrotated 15 kHz raster of the real board (a vertical
	// monitor, or a CRT on its side). Horizontal (rotated) rotates and scales the picture through a DDR3 buffer (rtl/ddr_rotate_hub.sv) for a normally
	// mounted CRT, Size picks the picture size. CRT Flip turns the CRT picture by 180 degrees in either
	// orientation (counter clockwise instead of clockwise when rotated, upside down when raw) and it is the only rotation control.
	// Position works in both modes by shifting the sync, and always means the direction you see on the CRT in the chosen orientation: in the rotated
	// mode the horizontal option moves the picture along the raster lines (3 pixel clocks a step) and the vertical option along the raster columns
	// (2 lines a step); in the raw mode the two swap roles (the raster runs up and down on a CRT that stands in portrait). No options are hidden.
	"P1O[53],CRT Orientation,Vertical (raw),Horizontal (rotated);",
	"P1O[59],CRT Flip,Off,On;",
	"P1O[58:54],CRT Size,182x208,189x216,196x224,203x232,175x200,168x192,161x184,154x176,147x168,140x160,133x152,126x144,119x136,112x128,105x120,98x112;",
	"P1O[60],CRT Aspect,Square pixels,Arcade 3:4;",
	"P1O[61],CRT Smoothing,On,Off;",
	"P1O[45:42],CRT V Position,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"P1O[49:46],CRT H Position,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	// Sound Settings: the board mixes its two YM3812 chips to mono; here each chip gets a level (100% is the real board) and the output can be split
	// stereo (chip 1 left, chip 2 right; the OSD label stays short: option values over 28 characters froze the OSD on hardware, see sim_scratch/check_conf_str.py). Everything on its first entry is bit for bit the original audio (rtl/snd_mixer.v). Status bits 29 to 39.
	"P3,Sound Settings;",
	"P3O[33:29],FM Chip 1 Volume,100%,94%,88%,81%,75%,69%,63%,56%,50%,44%,38%,31%,25%,19%,13%,6%,Off;",
	"P3O[38:34],FM Chip 2 Volume,100%,94%,88%,81%,75%,69%,63%,56%,50%,44%,38%,31%,25%,19%,13%,6%,Off;",
	"P3O[39],Output,Mono (original),Stereo (chips split);",
	"P3O[8:7],Treble,Original,Soft,Softer,Muffled;",   // a low pass on the final output (corner about 7.5, 3.7 and 1.9 kHz); Original is bit for bit the mix above
	// Factory defaults: with every option on its first entry the DIP switches read exactly as MAME's battlnts defaults (3 lives, bonus life at
	// 30k and every 70k, difficulty Normal, demo sounds On, upright with single controls, 5 continues, coinage 1 coin 1 credit). The entry order
	// is therefore NOT the order of the real DIP tables, see the translation in the DIP section.
	"P2,DIP Switches;",
	"P2O[20:19],Lives,3,5,7,2;",
	"P2O[12:11],Bonus Life,30k And Every 70k,40k And Every 80k,40k,50k;",
	"P2O[14:13],Difficulty,Normal,Easy,Difficult,Very Difficult;",
	"P2O[15],Demo Sounds,On,Off;",
	"P2O[50],Continues,5 Times,3 Times;",
	"P2O[10],Cabinet,Upright,Cocktail;",
	"D4P2O[18],Upright Controls,Single,Dual;",   // greyed out while Cabinet is Cocktail (mask bit 4): Cocktail forces Dual
	"P2O[16],Flip Screen,Off,On;",
	"P2O[17],Service Mode,Off,On;",
	"P2-;",
	"P2O[24:21],Coin A,1C 1C,4C 1C,3C 1C,2C 1C,3C 2C,4C 3C,3C 4C,2C 3C,1C 2C,2C 5C,1C 3C,1C 4C,1C 5C,1C 6C,1C 7C,Free Play;",
	"P2O[28:25],Coin B,1C 1C,4C 1C,3C 1C,2C 1C,3C 2C,4C 3C,3C 4C,2C 3C,1C 2C,2C 5C,1C 3C,1C 4C,1C 5C,1C 6C,1C 7C,No Coin B;",
	"P6,Controller Setup;",
	"H3P6-,Upright Controls: Single;",
	"H3P6-,Changing it restarts game.;",
	"H3P6-,One set of controls.;",
	"H3P6-,Set up your pad once:;",
	"H3P6-,1 Back to the main menu;",
	"H3P6-,2 Press Right (System);",
	"H3P6-,3 Define joystick buttons;",
	"H3P6-,4 Press what it asks:;",
	"H3P6-,Fire Coin Start Start 2;",
	"h3P6-,Upright Controls: Dual;",
	"h3P6-,Changing it restarts game.;",
	"h3P6-,Cocktail cabinet = Dual;",
	"h3P6-,Player 1: the first pad;",
	"h3P6-,Player 2: the second pad;",
	"h3P6-,Set up each pad once:;",
	"h3P6-,1 Back to the main menu;",
	"h3P6-,2 Press Right (System);",
	"h3P6-,3 Define joystick buttons;",
	"h3P6-,4 On the pad you set up;",
	"h3P6-,press what it asks:;",
	"h3P6-,Fire Coin Start Start 2;",
	"-;",
	// High scores: the button saves the BEST 10 table and the HI score to the MiSTer (status bit 62, a trigger). A saved file is loaded and put back by itself
	// after every boot; nothing is ever saved without pressing the button.
	"T[62],Save High Scores;",
	// Clear High Scores is a page that asks the question: only two choices, No (first, so it is the one highlighted) and Yes (status bits 5 and 6, one-shot buttons,
	// nothing is stored in the settings). Yes puts the original scores back, in the game and in the saved file.
	"P5,Clear High Scores;",
	"H2P5-,Are you sure you want to;",
	"H2P5-,clear your hi scores?;",
	"H2P5-,They will be lost forever.;",
	"H2P5-;",
	"H2P5T[5],No;",
	"H2P5T[6],Yes;",
	"-;",
`ifndef FINAL_BUILD
	// Cheats (developer builds only, FINAL_BUILD removes them).
	"P4,Cheats;",
	"P4O[51],99 Lives/Continues,Off,On;",
	"P4O[52],Invincibility,Off,On;",
	"-;",
`endif
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,4;", // [optional] config version 0-99.
	        // If CONF_STR options are changed in incompatible way, then change version number too,
			  // so all options will get default values on first start.
	// The J1 line is metadata, not a menu row, but its position shifts which item the OSD activates: it must sit right before the version line.
	"J1,Fire,Coin,Start,Start 2;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [21:0] gamma_bus;
`ifdef VERILATOR
// Simulation only: the hps_io stub leaves gamma_bus floating, which the video mixer reads as 'gamma enabled with an empty curve' (an all black
// picture). On hardware the real hps_io drives the bus (gamma_en low unless the user turns the framework's gamma option on).
assign gamma_bus[20:0] = 21'd0;
`endif
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire        ioctl_download;
wire [15:0] ioctl_index;     // which file the HPS is sending: 0 the ROM set, 1 the high score file (NVRAM)
wire        ioctl_upload;
wire  [7:0] ioctl_din;
wire        hs_upload_req;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
// Round 51: HPS download flow control. The SDRAM write behind port 0 of the arbiter takes many clk_sys cycles per byte;
// without this handshake the HPS streams the MRA bytes at full speed and every byte that arrives while a write is
// in flight is dropped, so the SDRAM resident ROMs (tiles, sprites, speech) never fully arrive on real hardware.
// Battlantis and Battlantis connect it exactly like this; this core had it open until Round 51.
wire        ioctl_wait;
wire [31:0] joystick_0, joystick_1;
wire  [8:0] spinner_0, spinner_1, spinner_2, spinner_3;

// Cabinet Cocktail always means separate controls for the two players (a control panel at each side of the table), so it counts as Upright Controls Dual.
wire dual_ctrl = status[18] | status[10];
reg hs_menu_hide = 1'b0;   // OSD mask bit 2, driven by the Clear High Scores logic further down
hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({11'd0, status[10], dual_ctrl, hs_menu_hide, 2'b00}),   // bit 2 hides the lines of the Clear High Scores page (the 'H2' prefix in CONF_STR) for a moment after No or Yes: a page with nothing to show makes the OSD return to the main menu

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.spinner_0(spinner_0),
	.spinner_1(spinner_1),
	.spinner_2(spinner_2),
	.spinner_3(spinner_3),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(hs_upload_req),   // pulses about 1.4 s after the high score table last changed, the HPS then saves the file
	.ioctl_upload_index(8'd1),
	.ioctl_din(ioctl_din),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire sdram_clk_shifted;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),          // 48MHz -- see rtl/pll/pll_0002.v's 2026-09-12 comment
	.outclk_1(sdram_clk_shifted), // 48MHz, phase-shifted -- SDRAM_CLK source
	.locked(pll_locked)
);

wire sys_reset = RESET | status[0] | buttons[1];

// Service Mode, Cabinet or Upright Controls changed in the OSD: the game only reads those switches at start up (a 2 player game with Upright Controls Dual
// still read pad 1 on both turns when the switch was changed after the boot, found in simulation 2026-10-18), so restart it (about 40 ms of reset).
reg  [2:0] svc_d = 3'b000;
reg [21:0] svc_cnt = 22'd0;
wire       svc_rst = (svc_cnt != 22'd0);
always @(posedge clk_sys) begin
    svc_d <= {status[18], status[17], status[10]};
    if (svc_d != {status[18], status[17], status[10]}) svc_cnt <= 22'd2000000;
    else if (svc_cnt != 22'd0) svc_cnt <= svc_cnt - 22'd1;
end
// ---- Game version select and ROM copy engine ----
// One rbf and one MRA carry all three versions: Battlantis (version G), (version F) and (Japan, version E). The whole ROM stream goes to SDRAM at the
// ioctl addresses (and the shared tile ROM, sprite ROM and sound ROM are used straight from there as before):
//   0x00000 banked ROM G, 0x10000 fixed ROM G, 0x18000 sound ROM, 0x20000 sprites, 0x60000 tiles,
//   0xA0000 banked ROM F, 0xB0000 fixed ROM F, 0xB8000 banked ROM E, 0xC8000 fixed ROM E.
// The main program ROM (96 KB, banked plus fixed) lives in on chip RAM, so after a download and after every change of the Game Version option a copy
// engine reads the chosen version's 96 KB back from SDRAM (port 1) and writes it into that RAM through the virtual write bus vw_*, with the whole core
// held in reset.
wire [1:0] ver_sel = (status[41:40] == 2'd3) ? 2'd0 : status[41:40];
reg  [1:0] ver_cur = 2'd0;
reg  [1:0] ver_tgt = 2'd0;
reg        dl_d = 1'b0;
reg        copy_busy = 1'b0;
reg  [1:0] cs = 2'd0;
reg [16:0] ccnt = 17'd0;
reg        c_req = 1'b0;
reg        vw_wr = 1'b0;
reg [24:0] vw_addr = 25'd0;
reg  [7:0] vw_dout = 8'd0;
wire [7:0] upd_p1_dout;
wire       upd_p1_ready;
wire [24:0] src_base = (ver_tgt == 2'd1) ? 25'hA0000 : (ver_tgt == 2'd2) ? 25'hB8000 : 25'h00000;
wire [24:0] src_addr = src_base + {8'd0, ccnt};
always @(posedge clk_sys) begin
    vw_wr <= 1'b0;
    dl_d  <= ioctl_download;
    if (!copy_busy) begin
        if ((dl_d & ~ioctl_download) | (~ioctl_download & (ver_sel != ver_cur))) begin
            ver_tgt <= ver_sel; ccnt <= 17'd0; cs <= 2'd0; copy_busy <= 1'b1;
        end
    end else begin
        case (cs)
            2'd0: begin c_req <= 1'b1; cs <= 2'd1; end
            2'd1: if (upd_p1_ready) begin c_req <= 1'b0; vw_wr <= 1'b1; vw_addr <= {8'd0, ccnt}; vw_dout <= upd_p1_dout; cs <= 2'd2; end
            2'd2: begin
                if (ccnt == 17'h17FFF) begin copy_busy <= 1'b0; ver_cur <= ver_tgt; end
                else begin ccnt <= ccnt + 17'd1; cs <= 2'd0; end
            end
            default: cs <= 2'd0;
        endcase
    end
end
wire reset = sys_reset | ioctl_download | copy_busy | svc_rst;
wire rom_idx = (ioctl_index[7:0] == 8'd0);   // the ROM download (the high score file arrives as index 1 and must not be written into the ROM memories)

// Round 51: the SDRAM arbiter must NOT be held in reset while the ROM downloads. The MiSTer framework keeps its RESET output
// asserted for the whole ioctl_download window (sys/sysmem.sv: ~init_reset_n | ~hps_h2f_reset_n | reset_core_req, with
// hps_h2f_reset_n low throughout the download), so an arbiter reset by bare sys_reset is frozen for the entire download and
// port 0 never writes a single byte to SDRAM: the tile, sprite and speech ROMs (everything that lives in SDRAM) never arrive
// and the picture shows whatever the previous core left there. The BRAM resident ROMs only depend on ioctl_wr and were fine,
// which is why the CPU ran. Same fix as Battlantis (Test 230, confirmed on real hardware) and Battlantis. A genuine OSD or
// joystick reset still resets the arbiter, only the download window itself is excluded.
wire sdram_reset = sys_reset & ~ioctl_download;

// ==============================================================================
// MAIN CPU (HD6309E) -- Round 6/7 (2026-09-12): CPU + memory + address-decode
// (design_notes/chip_inventory.md has the full confirmed address map this
// decode is built from). Round 7 adds real K007342/K007420 video -- YM2203,
// UPD7759 and the sound CPU are still NOT wired yet (step 3); their I/O
// region still reads back 8'hFF (open bus) as an explicit placeholder.
wire [15:0] cpu_addr;
wire [7:0]  cpu_dout;
wire [7:0]  cpu_din;
wire        cpu_rw;

// 48MHz clk_sys -> 12MHz CPU EXTAL enable -> 3MHz E/Q, identical divider
// chain to Battlantis/Battlantis's own proven HD6309E clocking (that
// project's real board and this one both use 24MHz/8 = 3MHz).
reg [1:0] bos_clk_div = 0;
always @(posedge clk_sys) bos_clk_div <= bos_clk_div + 1'd1;
wire bos_clk_12m = (bos_clk_div[1:0] == 2'b11);

reg [1:0] bos_cpu_clk_div = 0;
always @(posedge clk_sys) if (bos_clk_12m) bos_cpu_clk_div <= bos_cpu_clk_div + 1'd1;
wire cpu_q = (bos_cpu_clk_div == 2'b01 || bos_cpu_clk_div == 2'b10);
wire cpu_e = (bos_cpu_clk_div == 2'b10 || bos_cpu_clk_div == 2'b11);

// IRQ/FIRQ/NMI: confirmed from bladestl_mame.cpp's vblank_w() (Round 7):
// `if (state && m_k007342->is_int_enabled()) m_maincpu->set_input_line(
// HD6309_FIRQ_LINE, HOLD_LINE);` -- K007342's vblank interrupt drives the
// CPU's FIRQ line specifically, NOT IRQ (unlike Battlantis/Battlantis,
// which use plain IRQ for the same K007342 vblank source -- a real,
// game-specific difference, not a copy-paste assumption).
// - NMI: the real 051733 has its own NMI timer (`set_nmi_cb()` in
//   bladestl_mame.cpp) that jt051733.v does not implement (a known,
//   documented gap -- see design_notes/jt051733_vs_mame_k051733.md's
//   "NMI timer/enable (0x10-0x13) entirely unimplemented" item).
wire cpu_bs, cpu_ba;
wire k007342_irq;
// Round 50: acknowledge ONLY when the FIRQ vector ($FFF6/$FFF7) is being fetched. BS=1 with BA=0 also marks the NMI,
// IRQ and SWI vector fetches, so the NMI the 051733 timer now raises every vblank used to clear the pending vblank
// FIRQ before the CPU ever took it (game frozen in its main loop). MAME's HOLD_LINE is cleared only when that
// specific interrupt is taken.
wire k007342_irq_ack = cpu_bs & ~cpu_ba & (cpu_addr[15:1] == 15'h7FFC); // IRQ vector $FFF8/$FFF9 (Battlantis uses IRQ; Blades of Steel's FIRQ vector is $FFF6) // real interrupt-acknowledge cycle only (see RackEmUp.sv's own
                                          // task #15 root-cause comment for why this beats a bare address check)
wire cpu_irq_n  = ~k007342_irq;   // Battlantis: the K007342 vblank drives the plain IRQ line (Blades of Steel uses FIRQ)
wire cpu_firq_n = 1'b1;
wire cpu_nmi_n = 1'b1;

hd6309i bos_main_cpu (
    .D(cpu_din),
    .DOut(cpu_dout),
    .ADDR(cpu_addr),
    .RnW(cpu_rw),
    .E(cpu_e),
    .Q(cpu_q),
    .BS(cpu_bs),
    .BA(cpu_ba),
    .nIRQ(cpu_irq_n),
    .nFIRQ(cpu_firq_n),
    .nNMI(cpu_nmi_n),
    .AVMA(),
    .BUSY(),
    .LIC(),
    .nRESET(~reset),
    .nDMABREQ(1'b1),
    .nHALT(1'b1)
);

// Main CPU program ROM: one contiguous 64KB image, loaded verbatim from
// ioctl_addr 0x00000-0x0FFFF -- matches the real 27512 EPROM exactly
// (confirmed from bladestl_mame.cpp: ROM_LOAD("797-t01.19c", 0x00000,
// 0x10000, ...), a single 64KB file, no splitting). CPU addr 0x8000-0xffff
// maps straight to ROM offset 0x8000-0xffff (MAME's `map(0x8000,
// 0xffff).rom();`, no bank offset); CPU addr 0x6000-0x7fff is a banked
// 8KB window into ROM offset [bank*0x2000 : +0x2000], bank 0-3 selected by
// bankswitch_w bits 5-6 (`m_rombank->configure_entries(0, 4, ..., 0x2000)`).
// Main program ROM: 96 KB, loaded from the ROM download (ioctl 0x00000-0x17fff): 64 KB banked ROM (765_j03.8e, four 16 KB banks at
// 0x4000-0x7fff) then 32 KB fixed ROM (765_l02.7e at 0x8000-0xffff).
(* ramstyle = "M10K" *) reg [7:0] rack_main_rom [0:98303];
always @(posedge clk_sys) begin
    if (vw_wr && vw_addr < 25'h18000) begin
        rack_main_rom[vw_addr[16:0]] <= vw_dout;   // banked and fixed ROM of the selected version, from the copy engine
    end
end

reg [1:0] rack_rom_bank;
reg       rack_sprite_bank;
always @(posedge clk_sys) begin
    if (reset) begin
        rack_rom_bank    <= 2'd0;
        rack_sprite_bank <= 1'b0;
    end else if (!cpu_rw && cpu_e) begin
        if (bankswitch_cs)   rack_rom_bank    <= cpu_dout[7:6];   // MAME battlnts: bankswitch_w, bits 6 and 7 select the 16 KB bank
        if (spritebank_cs)   rack_sprite_bank <= cpu_dout[0];     // MAME battlnts: spritebank_w
    end
end

// Sound command latch (0x2e14) and the interrupt trigger (0x2e18). The command goes through the same "big load" injection the Battlantis
// core settled on (a synthetic 0x80 command ahead of the first music command), which fixed the OPL fade glitch on real hardware.
reg [7:0] rack_sound_latch;
reg       rack_sound_irq;
reg       cmd80_since_last_bigload, cmd80_seen_before_last_bigload;
always @(posedge clk_sys) begin
    rack_sound_irq <= 1'b0;
    if (reset) begin
        rack_sound_latch <= 8'd0;
        cmd80_since_last_bigload <= 1'b0;
        cmd80_seen_before_last_bigload <= 1'b0;
    end else if (!cpu_rw && cpu_e) begin
        if (soundlatch_cs) begin
            rack_sound_latch <= cpu_dout;
            if (cpu_dout == 8'h80) begin
                cmd80_since_last_bigload <= 1'b1;
            end else if (cpu_dout[7] && cpu_dout < 8'h9b) begin
                cmd80_seen_before_last_bigload <= cmd80_since_last_bigload;
                cmd80_since_last_bigload <= 1'b0;
            end
        end
        if (sndirq_cs) rack_sound_irq <= 1'b1;
    end
end
wire z80_irq_ack;
reg  z80_irq_ack_prev;
always @(posedge clk_sys) z80_irq_ack_prev <= z80_irq_ack;
wire z80_irq_ack_edge = z80_irq_ack && !z80_irq_ack_prev;
localparam INJ_IDLE = 1'b0, INJ_WAIT_ACK = 1'b1;
reg       inj_state;
reg [7:0] inj_pending_cmd;
reg [7:0] sound_latch_to_z80;
reg       sound_irq_to_z80;
always @(posedge clk_sys or posedge reset) begin
    if (reset) begin
        inj_state <= INJ_IDLE;
        sound_latch_to_z80 <= 8'd0;
        sound_irq_to_z80 <= 1'b0;
        inj_pending_cmd <= 8'd0;
    end else begin
        sound_irq_to_z80 <= 1'b0;
        case (inj_state)
            INJ_IDLE: begin
                if (rack_sound_irq) begin
                    if (rack_sound_latch[7] && rack_sound_latch < 8'h9b && !cmd80_seen_before_last_bigload) begin
                        inj_pending_cmd <= rack_sound_latch;
                        sound_latch_to_z80 <= 8'h80;
                        sound_irq_to_z80 <= 1'b1;
                        inj_state <= INJ_WAIT_ACK;
                    end else begin
                        sound_latch_to_z80 <= rack_sound_latch;
                        sound_irq_to_z80 <= 1'b1;
                    end
                end
            end
            INJ_WAIT_ACK: begin
                if (z80_irq_ack_edge) begin
                    sound_latch_to_z80 <= inj_pending_cmd;
                    sound_irq_to_z80 <= 1'b1;
                    inj_state <= INJ_IDLE;
                end
            end
        endcase
    end
end

// ONE read port for both windows (the CPU never reads both in the same cycle): two ports would make the synthesizer keep two copies of
// the 96 KB ROM, and the extra memory blocks pushed the whole design over the device (the framework's scaler and gamma tables were then
// turned into registers and the logic no longer fitted).
wire [16:0] rack_rom_addr = cpu_addr[15] ? {2'b10, cpu_addr[14:0]}             // fixed ROM: 0x10000 + offset
                                         : {1'b0, rack_rom_bank, cpu_addr[13:0]}; // banked ROM: bank * 16 KB + offset
reg  [7:0] rack_rom_dout;
always @(posedge clk_sys) rack_rom_dout <= rack_main_rom[rack_rom_addr];

// Address decode (MAME battlnts.cpp main_map).
wire k007342_cs    = (cpu_addr[15:13] == 3'b000);                      // 0x0000-0x1fff VRAM / colour RAM (the game also uses it as work RAM)
wire k007420_cs    = (cpu_addr[15:9]  == 7'b0010000);                  // 0x2000-0x21ff sprite RAM
wire scroll_cs     = (cpu_addr[15:9]  == 7'b0010001);                  // 0x2200-0x23ff scroll RAM
wire palette_cs    = (cpu_addr[15:9]  == 7'b0010010);                  // 0x2400-0x25ff palette RAM
wire ctrl_cs       = (cpu_addr[15:3]  == 13'b0_0010_0110_0000_0);      // 0x2600-0x2607 K007342 control registers
wire dsw1_cs       = (cpu_addr == 16'h2e00);
wire p2_cs         = (cpu_addr == 16'h2e01);
wire p1_cs         = (cpu_addr == 16'h2e02);
wire dsw3_cs       = (cpu_addr == 16'h2e03);                           // coin and start switches, flip, service
wire dsw2_cs       = (cpu_addr == 16'h2e04);
wire bankswitch_cs = (cpu_addr == 16'h2e08);
wire spritebank_cs = (cpu_addr == 16'h2e0c);
wire soundlatch_cs = (cpu_addr == 16'h2e14);
wire sndirq_cs     = (cpu_addr == 16'h2e18);
wire banked_rom_cs = (cpu_addr[15:14] == 2'b01);                       // 0x4000-0x7fff
wire fixed_rom_cs  = cpu_addr[15];                                     // 0x8000-0xffff


// ==============================================================================
// VIDEO TIMING -- Round 7 (2026-09-12): real timing replacing the stock
// template's mycore stub. Confirmed from bladestl_mame.cpp's machine_config:
// pixel clock 24MHz/4 = 6MHz (48MHz clk_sys / 8), 384 total H / 256 visible,
// 264 total V / 16-240 visible -- the exact same convention already proven
// correct for Battlantis/Battlantis (same chip family). h_sync/v_sync pulse
// timing reused verbatim from RackEmUp.sv (same chipset, same real board
// family, no evidence this game's front porch/sync width differs).
// ==============================================================================
reg [2:0] pix_clk_div = 0;
always @(posedge clk_sys) pix_clk_div <= pix_clk_div + 1'd1;
wire ce_pix = (pix_clk_div == 3'd7);

reg [10:0] h_cnt = 0;
reg [9:0]  v_cnt = 0;
always @(posedge clk_sys) begin
    if (ce_pix) begin
        if (h_cnt == 383) begin
            h_cnt <= 0;
            v_cnt <= (v_cnt == 263) ? 10'd0 : v_cnt + 10'd1;
        end else begin
            h_cnt <= h_cnt + 11'd1;
        end
    end
end

wire active_area = (h_cnt < 256) && (v_cnt >= 16 && v_cnt < 240);
// Round 51: was h_cnt 320..352 = front porch 64 / sync 32 / back porch 32. A back porch SHORTER than the front porch is
// backwards from real arcade/NTSC timing (and from Jotego's Konami sibling boards); active video starts too soon after the
// sync pulse, so the picture sits too far left and runs off the screen. 304..336 gives 48 / 32 / 48, the same correction
// already proven on Battlantis (TASKS.md there, 2026-10-02). Only the pulse position moves: H_TOTAL, the active window and
// h_cnt (which the game timing depends on) are untouched.
// Round 55: the whole sync pulse can be moved earlier by CRT_H_SHIFT pixel clocks. The picture itself (h_cnt, the active window, the HDMI
// path which only uses the data enable) does not move; on the analog output the sync pulse arrives earlier relative to the picture, so the
// picture appears further to the right on the CRT. Front porch 48 / sync 32 / back porch 48 at shift 0.
wire [5:0]  CRT_H_SHIFT = {crt_hs_step, 1'b0} + crt_hs_step;       // 3 pixel clocks per step
wire [10:0] hs_start = 11'd304 - {5'd0, CRT_H_SHIFT};
wire [10:0] hs_end   = 11'd336 - {5'd0, CRT_H_SHIFT};
wire HSync   = (h_cnt >= hs_start && h_cnt < hs_end);
// Vertical sync later by 2 lines per step (CRT Horizontal Position on the portrait monitor); start wraps around the 264 line frame.
wire [8:0] vs_start = (9'd244 + {3'd0, crt_vs_step, 1'b0} >= 9'd264) ? (9'd244 + {3'd0, crt_vs_step, 1'b0} - 9'd264) : (9'd244 + {3'd0, crt_vs_step, 1'b0});
wire [8:0] vs_end   = (vs_start + 9'd3 >= 9'd264) ? (vs_start + 9'd3 - 9'd264) : (vs_start + 9'd3);
wire VSync   = (vs_start < vs_end) ? (v_cnt >= vs_start && v_cnt < vs_end) : (v_cnt >= vs_start || v_cnt < vs_end);
wire HBlank  = ~(h_cnt < 256);
wire VBlank  = ~(v_cnt >= 16 && v_cnt < 240);

// ==============================================================================
// 051733 NMI TIMER (Round 50) -- MAME k051733_device::nmiclock_w() and write(), ported 1:1.
// The ROM programs it at $CECC-$CED1 (STD $2F90 with 0, STA $2F92 with 1), so with a reload of 0 the
// main CPU gets one NMI per vblank. The NMI handler ($D10F) pops one byte from the sound command ring
// buffer ($5C80-$5D00) and writes it to the sound latch ($2E80); without this NMI no in-game sound
// command was ever delivered to the sound CPU. MAME: on every vblank start the 16 bit timer is
// decremented; if it was 0 and reg $12 bit 0 is set, NMI is pulsed for 4 chip clocks (about one CPU E
// cycle; held for 20 clk_sys here so the CPU's E-clocked NMI sampling always sees it), then the timer
// reloads from {reg $10, reg $11}. Reset clears the timer and the NMI line.
// ==============================================================================


// ==============================================================================
// SDRAM (tile/sprite graphics ROM storage) -- ported from Battlantis's
// proven sdram.sv/sdram_arbiter.sv verbatim (same battle-tested timing
// margins, same Port 0/2/3 roles). Port 1 (CPU-via-SDRAM) is unused here --
// the main CPU ROM stays in BRAM (64KB fits easily, no reason to move it).
// ==============================================================================
wire [15:0] sdram_dout_16;
wire        sdram_ready;
wire        sdram_rd;
wire        sdram_we;
wire [24:0] sdram_addr_in;
wire [1:0]  sdram_wtbt;
wire [15:0] sdram_din_16;

sdram sdram_inst (
    .init(~pll_locked),
    .clk(clk_sys),
    .sdram_clk_in(sdram_clk_shifted),

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

    .wtbt(sdram_wtbt),
    .addr(sdram_addr_in),
    .dout(sdram_dout_16),
    .din(sdram_din_16),
    .we(sdram_we),
    .rd(sdram_rd),
    .ready(sdram_ready)
);

wire        upd_p1_req = c_req;     // SDRAM port 1 reads the selected version's program ROM back for the copy engine
wire [24:0] upd_sdram_addr = src_addr;


wire tile_sdram_req, sprite_sdram_req;
wire [24:0] tile_sdram_addr, sprite_sdram_addr;
wire [7:0]  tile_sdram_dout, sprite_sdram_dout, sprite_sdram_dout2;
wire        tile_sdram_ready, sprite_sdram_ready;
wire        p3_active;

// Round 14 fix, Verilator-only workaround (confirmed via a real VCD
// waveform, not just printf reads): `ioctl_download`/`ioctl_wr` are hps_io
// output regs with no RTL writer after their own `initial` block (this
// project's harness drives them externally via Verilator's public_flat_rw
// poke mechanism, which Verilator itself cannot see as a real "driver").
// ANY logic computed from them and fed across a submodule instantiation
// boundary (a cell port connection) -- a plain inline expression, a named
// wire with a real `assign`, and even a genuine clocked register all tested
// and all identically broken -- gets permanently frozen at its t=0 value
// once it crosses into `sdram_arbiter`'s own `p0_req` input, confirmed by a
// real VCD waveform showing `ioctl_wr` toggling normally while
// `bos_arbiter.p0_req` never once changes. A same-module register with NO
// cross-module boundary (this file's own `bos_main_rom` load, structurally
// identical otherwise) is unaffected, isolating the trigger specifically to
// the cell-port crossing, not the computation itself -- a genuine Verilator
// scheduling limitation, not a real hardware defect (inline expressions,
// named wires, and registers are all electrically live-updating on real
// silicon; MiSTer hardware never had this problem). Since simulation-only
// workarounds for this class of bug are exactly what Verilator's own
// public_flat_rw mechanism exists for, and `` `VERILATOR`` is defined
// automatically by Verilator and never by Quartus, real hardware keeps the
// exact same combinational logic it always had; only this simulation-only
// build substitutes a directly C++-poked register that bypasses the broken
// boundary crossing entirely (poked in lockstep with ioctl_wr in the
// harness's own sim_main.cpp download routine).
`ifdef VERILATOR
    reg p0_req_w /* verilator public_flat_rw */ = 1'b0;
`else
    wire p0_req_w = ioctl_download & ioctl_wr & rom_idx;   // only the ROM file (index 0), never the high score file
`endif

`ifdef BOS_SDRAM_MON
wire        mon_req;
wire [24:0] mon_addr;
wire [175:0] mon_rows;
`endif

sdram_arbiter bos_arbiter (
    .clk(clk_sys),
    .reset(sdram_reset),

    .p0_req(p0_req_w),
    .p0_addr(ioctl_addr),
    .p0_din(ioctl_dout),
    .p0_ready(),
    .p0_busy(ioctl_wait),

    .p1_req(upd_p1_req),
    .p1_addr(upd_sdram_addr),
    .p1_dout(upd_p1_dout),
    .p1_ready(upd_p1_ready),

`ifdef BOS_SDRAM_MON
    .p2_req(tile_sdram_req | mon_req),          // Round 54: the SDRAM health monitor uses the idle tile port
    .p2_addr(mon_req ? mon_addr : tile_sdram_addr),
`else
    .p2_req(tile_sdram_req),
    .p2_addr(tile_sdram_addr),
`endif
    .p2_dout(tile_sdram_dout),
    .p2_ready(tile_sdram_ready),

    .p3_req(sprite_sdram_req),
    .p3_addr(sprite_sdram_addr),
    .p3_dout(sprite_sdram_dout),
    .p3_dout2(sprite_sdram_dout2),
    .p3_ready(sprite_sdram_ready),
    .p3_active(p3_active),

    .sdram_addr(sdram_addr_in),
    .sdram_rd(sdram_rd),
    .sdram_we(sdram_we),
    .sdram_din(sdram_din_16),
    .sdram_dout(sdram_dout_16),
    .sdram_ready(sdram_ready),
    .sdram_wtbt(sdram_wtbt)
);

`ifdef BOS_SDRAM_MON
// Round 54: SDRAM health monitor (rtl/sdram_mon.v), diagnostic build only. Its rows are drawn as boxes at the bottom of this file.
reg mon_vb_d;
always @(posedge clk_sys) mon_vb_d <= VBlank;
wire mon_snap = VBlank & ~mon_vb_d;
sdram_mon bos_sdram_mon (
    .clk(clk_sys),
    .reset(reset),
    .dl_wr(p0_req_w),
    .dl_addr(ioctl_addr),
    .dl_din(ioctl_dout),
    .req(mon_req),
    .addr(mon_addr),
    .dout(tile_sdram_dout),
    .ready(tile_sdram_ready),
    .p3_busy(p3_active),
    .snap(mon_snap),
    .rows(mon_rows)
);
`endif

// ==============================================================================
// K007342 TILEMAP GENERATOR (0x0000-0x1fff, ctrl regs 0x2600-0x2607,
// scroll RAM 0x2200-0x23ff) -- ioctl layout note: k007342.v has the real
// tile-cache SDRAM base (0x60000) hardcoded internally (shared file with
// Battlantis), so Blades of Steel's own tile ROM must be loaded at that
// same ioctl_addr offset. Reserved layout: 0x00000-0x0ffff main CPU ROM
// (already loaded via BRAM above), 0x10000-0x1ffff reserved for audio CPU
// (step 3), 0x20000-0x5ffff sprite ROM (256KB, matches k007420.v's own
// hardcoded 0x20000 base), 0x60000-0x9ffff tile ROM (256KB). No .mra file
// exists yet to actually place ROM bytes at these offsets on real hardware
// -- this is forward-looking infrastructure, same caveat as Round 6's CPU
// ROM loading.
// ==============================================================================
wire k007342_we = !cpu_rw && (k007342_cs || ctrl_cs);

// Debug: 99 Lives/Continues. The game keeps its lives and continues counters in the K007342 VRAM (it has no separate work RAM): 0x1090 is
// the lives remaining, 0x1082 and 0x08BE the continues (a display mirror pair), found by live write tracing on 2026-09-24. While the OSD option
// is on, every real CPU write to those cells stores 99 instead, so the game's own logic still reads and decrements them but they never run out.
// Developer builds only: FINAL_BUILD pins the bit to 0 so a stale saved setting cannot switch it on in a release build.
`ifdef FINAL_BUILD
wire debug_99_lives_continues = 1'b0;
`else
wire debug_99_lives_continues = status[51];
`endif
wire k007342_debug_hit = debug_99_lives_continues && k007342_we &&
    (cpu_addr == 16'h1090 || cpu_addr == 16'h1082 || cpu_addr == 16'h08BE);

wire [7:0] k007342_dout;
wire [7:0] k007342_scroll_dout;
wire [7:0] k007342_pixel;
wire       k007342_priority;
wire       int_enabled;
wire       sprite_wrap_y;
wire       flip_screen_req;

// Cheat: Invincibility. The invincibility item (white outline player, TIME n countdown) is a handful of cells in the player object, found by
// comparing MAME RAM dumps of the stage 5 pickup in versions G, F and E (identical addresses in all three):
//   0x1380 player flags: 0xC1 alive and vulnerable, 0x81 invincible (bit 6 cleared), 0x00 no player
//   0x1389 = 64, 0x1399 = 6, 0x13A9 = 128, 0x13B9 = 12 (the countdown, one tick per 64 frames)
// Once per frame, on CPU bus cycles that do not touch the K007342, this reads 0x1380 through the K007342 CPU port: 0xC1 gets the pickup values
// written (the game then behaves as if the item was just taken), 0x81 gets the countdown refreshed to 12 so it never runs out.
`ifdef FINAL_BUILD
wire cheat_invincible = 1'b0;
`else
wire cheat_invincible = status[52];
`endif
reg [19:0] ci_timer = 20'd0;
reg [2:0]  ci_state = 3'd0;      // 0 idle, 1 read issue, 2 read sample, 3..7 write 0x1380, 0x1389, 0x1399, 0x13A9, 0x13B9
reg        ci_drive = 1'b0;
reg        ci_we_q  = 1'b0;
reg [15:0] ci_addr_q = 16'd0;
reg [7:0]  ci_din_q  = 8'd0;
reg [7:0]  ci_flags  = 8'd0;
reg        ci_pend   = 1'b0;      // once-per-frame trigger, latched because ci_timer == 0 lasts one clock and the steps run on every 4th
wire ci_cycle_ok = (bos_cpu_clk_div == 2'b00) && !(k007342_cs || ctrl_cs);   // start of a CPU cycle that leaves the VRAM alone
always @(posedge clk_sys) begin
    ci_timer <= ci_timer + 1'd1;
    if (ci_timer == 20'd0) ci_pend <= 1'b1;
    if (reset || !cheat_invincible) begin
        ci_state <= 3'd0; ci_drive <= 1'b0; ci_we_q <= 1'b0;
    end else if (bos_clk_12m) begin
        ci_drive <= 1'b0; ci_we_q <= 1'b0;                      // each injected access lasts one CPU phase (4 clocks)
        case (ci_state)
            3'd0: if (ci_pend) begin ci_pend <= 1'b0; ci_state <= 3'd1; end
            3'd1: if (ci_cycle_ok) begin
                ci_drive <= 1'b1; ci_addr_q <= 16'h1380; ci_state <= 3'd2;
            end
            3'd2: if (bos_cpu_clk_div == 2'b01) begin             // the read data of the access above is valid now
                ci_flags <= k007342_dout;
                ci_state <= (k007342_dout == 8'hC1) ? 3'd3 : (k007342_dout == 8'h81) ? 3'd7 : 3'd0;
            end
            default: if (ci_cycle_ok) begin
                ci_drive <= 1'b1; ci_we_q <= 1'b1;
                case (ci_state)
                    3'd3: begin ci_addr_q <= 16'h1380; ci_din_q <= ci_flags & 8'hBF; end
                    3'd4: begin ci_addr_q <= 16'h1389; ci_din_q <= 8'd64;  end
                    3'd5: begin ci_addr_q <= 16'h1399; ci_din_q <= 8'd6;   end
                    3'd6: begin ci_addr_q <= 16'h13A9; ci_din_q <= 8'd128; end
                    default: begin ci_addr_q <= 16'h13B9; ci_din_q <= 8'd12; end
                endcase
                ci_state <= (ci_state == 3'd7) ? 3'd0 : ci_state + 1'd1;
            end
        endcase
    end
end
// ==============================================================================
// High score table persistence (restore automatic, saving on the OSD button). The real board has no battery RAM; this is a convenience on top, per the user (2026-10-16).
// The BEST 10 RANKING table is 80 bytes at 0x1100-0x114F of the K007342 VRAM (10 entries of 8 bytes: 3 byte BCD score, stage, padding, 3 name tiles),
// found by MAME write tracing on 2026-09-25. The game rewrites its factory table at every boot, so the saved table is NOT loaded at download time:
//   1. a shadow copy (hs_ram) follows every write that reaches the VRAM at 0x1100-0x114F, real CPU writes and the restore below;
//   2. the file the HPS loads (index 1) is kept in hs_sav; once it has arrived completely it is marked loaded;
//   3. after each boot the game's own table writes are watched; when they have stopped for 4.2 s (the initialisation, RAM test included, is over) the 80 saved
//      bytes are written into the VRAM through the same injection port the cheat uses (on CPU cycles that leave the VRAM alone), once per boot,
//      followed by the 3 byte HI score cell at 0x1050 (the top of the screen shows it; the game copies it from the table during its own boot);
//   4. the OSD button Save High Scores (a trigger) makes the core request an upload: the HPS then saves the shadow copy as the NVRAM file. Nothing is
//      saved by itself, and never before the boot initialisation is over.
// The two 80 byte arrays are plain logic (asynchronous read), no block RAM.
// ==============================================================================
wire hs_cycle_ok = (bos_cpu_clk_div == 2'b00) && !(k007342_cs || ctrl_cs);   // start of a CPU cycle that leaves the VRAM alone (same as the cheat)
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] hs_ram [0:127];   // live shadow of the table (the file the HPS saves)
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] hs_sav [0:127];   // the file the HPS loaded, used for the restore after boot
reg        hs_got = 1'b0, hs_loaded = 1'b0, hs_dl_nv = 1'b0, hs_dl_q = 1'b0;
// Two ways to decide that the game's own table initialisation is over (the saved scores must go in AFTER it, the game rewrites its factory table every boot):
//   fast: 50 ms without a table write (HS_Q50), the game HAS written the table since the reset, and the table in the game passes a structure check (see
//         hs_fcp_nok): this is the normal path, about 3.6 s after boot. The boot RAM test writes patterns in bursts 45 ms apart and the real table in two bursts
//         21 ms apart, so a 50 ms gap alone is not enough, the structure check is what tells the real table from a RAM test pattern.
//   slow: 4.2 s without a write (HS_QUIET), no check at all: the fallback if some game version's table does not pass the structure check.
localparam [27:0] HS_Q50   = 28'd2_400_000;
localparam [27:0] HS_QUIET = 28'd200_000_000;
reg [27:0] hs_quiet = 28'd0;
reg        hs_seen = 1'b0, hs_inj = 1'b0, hs_done = 1'b0, hs_drive = 1'b0;
reg [6:0]  hs_i = 7'd0;
reg [13:0] hs_addr_q = 14'd0;
reg  [7:0] hs_din_q  = 8'd0;
reg        hs_req = 1'b0, hs_btn_q = 1'b0, hs_cp_act = 1'b0, hs_cp_src = 1'b0;   // hs_cp_src: 0 copies the shadow to the restore copy (Save), 1 the factory table (Clear)
reg  [6:0] hs_cp_i = 7'd0;
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] hs_fac [0:127];   // the factory table the game wrote at boot (captured before the saved one is restored)
reg        hs_fac_valid = 1'b0, hs_fcp_act = 1'b0, hs_fcp_ph = 1'b0, hs_c_q = 1'b0, hs_clr_pend = 1'b0, hs_fac_try = 1'b0, hs_fcp_bad = 1'b0;
reg  [6:0] hs_fcp_i = 7'd0;
// The factory table is captured only from a boot in which the game wrote its real table, and only if it looks like one: every entry's three name bytes must be
// printable tile codes (0x20 to 0x7E). A boot that never writes the table (service mode runs only the RAM test) would otherwise leave RAM test patterns or zeros there,
// and Clear would write a blank top 10. One attempt per boot (hs_fac_try), so a bad boot is simply tried again after the next reset.
wire [7:0] hs_fcp_d    = hs_ram[hs_fcp_i];
// structure of one 8 byte entry: bytes 0 to 2 the score in BCD (every nibble 0 to 9), byte 3 zero, byte 4 the stage (not checked), bytes 5 to 7 the name (printable tile codes)
wire [2:0] hs_fcp_k    = hs_fcp_i[2:0];
wire       hs_fcp_bcd  = (hs_fcp_d[7:4] <= 4'd9) && (hs_fcp_d[3:0] <= 4'd9);
wire       hs_fcp_prn  = (hs_fcp_d >= 8'h20) && (hs_fcp_d <= 8'h7E);
`ifdef SIM_HS_BADFAC
wire       hs_fcp_nok  = 1'b0;   // simulation only: pretend the boot table never looked valid
`else
wire       hs_fcp_nok  = (hs_fcp_k <= 3'd2) ? hs_fcp_bcd : (hs_fcp_k == 3'd3) ? (hs_fcp_d == 8'h00) : (hs_fcp_k == 3'd4) ? 1'b1 : hs_fcp_prn;
`endif

// what actually reaches the K007342 CPU port: the restore, else the cheat, else the real CPU
wire [13:0] k007342_cpu_addr = hs_drive ? hs_addr_q : (ci_drive ? ci_addr_q[13:0] : cpu_addr[13:0]);
wire [7:0]  k007342_cpu_din  = hs_drive ? hs_din_q : ((ci_drive && ci_we_q) ? ci_din_q : (k007342_debug_hit ? 8'd99 : cpu_dout));
wire        k007342_cpu_we   = hs_drive ? 1'b1 : (ci_drive ? ci_we_q : k007342_we);

wire hs_save_btn = status[62];   // OSD Save High Scores button (a trigger: the bit is 1 while it is pressed)
wire hs_tbl_we = k007342_we && (cpu_addr >= 16'h1100) && (cpu_addr <= 16'h114F);   // a real CPU write to the table
wire hs_q50    = (hs_quiet >= HS_Q50);
wire hs_qdone  = (hs_quiet >= HS_QUIET);
wire hs_ready  = hs_done;                                            // the boot initialisation is over and the saved table, if any, is in
assign hs_upload_req = hs_req;
assign ioctl_din = (ioctl_upload && ioctl_index[7:0] == 8'd1) ? hs_ram[ioctl_addr[6:0]] : 8'h00;

wire hs_nv_wr   = ioctl_wr && ioctl_download && (ioctl_index[7:0] == 8'd1);        // a byte of the file from the HPS
wire hs_vram_wr = k007342_cpu_we && (k007342_cpu_addr >= 14'h1100) && (k007342_cpu_addr <= 14'h114F);   // a write that reaches the table cells
wire hs_ram_we  = hs_nv_wr | hs_vram_wr;
wire [6:0] hs_ram_wa = hs_nv_wr ? ioctl_addr[6:0] : k007342_cpu_addr[6:0];
wire [7:0] hs_ram_wd = hs_nv_wr ? ioctl_dout : k007342_cpu_din;

// hs_sav (what the restore writes) takes the file from the HPS, or a copy of the shadow when the Save button is pressed: a reset in the same session then
// restores the scores that were just saved, without the HPS loading the file again
wire       hs_sav_we = hs_nv_wr | hs_cp_act;
wire [6:0] hs_sav_wa = hs_nv_wr ? ioctl_addr[6:0] : hs_cp_i;
wire [7:0] hs_sav_wd = hs_nv_wr ? ioctl_dout : (hs_cp_src ? hs_fac[hs_cp_i] : hs_ram[hs_cp_i]);
always @(posedge clk_sys) begin
    if (hs_ram_we) hs_ram[hs_ram_wa] <= hs_ram_wd;
    if (hs_sav_we) hs_sav[hs_sav_wa] <= hs_sav_wd;
    if (hs_fcp_act && hs_fcp_ph) hs_fac[hs_fcp_i] <= hs_ram[hs_fcp_i];   // capturing the factory table (second pass, only after the structure check passed)
end

`ifdef SIM_HS_PRELOAD
// Simulation only: a saved table (hs_preload.hex, 80 bytes) standing in for the NVRAM file the HPS would load
initial begin $readmemh("hs_preload.hex", hs_sav, 0, 79); hs_loaded = 1'b1; end
`endif
`ifdef SIM_HS_TRACE
reg [31:0] hs_clk = 32'd0;
reg        hs_ready_q = 1'b0;
reg        hs_hm_q = 1'b0;
reg        rst_q = 1'b0, qd_q = 1'b0, dl_q2 = 1'b0, ld_q = 1'b0;
integer    hs_k;
always @(posedge clk_sys) begin
    hs_clk <= hs_clk + 1'd1;
    hs_ready_q <= hs_ready;
    if (hs_menu_hide !== hs_hm_q) $display("[hs] clk=%0d menu hide mask = %0d", hs_clk, hs_menu_hide);
    hs_hm_q <= hs_menu_hide;
    rst_q <= reset;
    dl_q2 <= ioctl_download;
    ld_q <= hs_loaded;
    if (ioctl_download != dl_q2) $display("[hs] clk=%0d ioctl_download=%b index=%0d", hs_clk, ioctl_download, ioctl_index);
    if (hs_nv_wr) $display("[hs] clk=%0d nvram byte %0d = %h", hs_clk, ioctl_addr[6:0], ioctl_dout);
    if (hs_loaded && !ld_q) $display("[hs] clk=%0d hs_loaded set (got=%b dl_nv=%b)", hs_clk, hs_got, hs_dl_nv);
    if (reset && !rst_q) $display("[hs] clk=%0d reset asserted (sys_reset=%b ioctl_download=%b copy_busy=%b svc_rst=%b)", hs_clk, sys_reset, ioctl_download, copy_busy, svc_rst);
    if (!reset && rst_q) $display("[hs] clk=%0d reset released", hs_clk);
    if (hs_qdone && !qd_q) $display("[hs] clk=%0d quiet timer done (loaded=%b inj=%b done=%b)", hs_clk, hs_loaded, hs_inj, hs_done);
    qd_q <= hs_qdone;
    if (k007342_we && cpu_addr >= 16'h1050 && cpu_addr <= 16'h1052) $display("[hs] clk=%0d HI cell write %h = %h", hs_clk, cpu_addr, cpu_dout);
    if (hs_tbl_we) $display("[hs] clk=%0d cpu write %h = %h  seen=%b qdone=%b inj=%b done=%b ready=%b", hs_clk, cpu_addr, cpu_dout, hs_seen, hs_qdone, hs_inj, hs_done, hs_ready);
    if (hs_inj && !hs_drive && hs_i == 7'd0 && bos_clk_12m && hs_cycle_ok) $display("[hs] clk=%0d restore starts", hs_clk);
    if (hs_done && !hs_inj && hs_ready && !hs_ready_q) $display("[hs] clk=%0d restore done", hs_clk);
    if (hs_ready && !hs_ready_q) begin
        $write("[hs] clk=%0d ready, table:", hs_clk);
        for (hs_k = 0; hs_k < 80; hs_k = hs_k + 1) $write(" %02x", hs_ram[hs_k]);
        $write("%c", 8'd10);
    end
    if (hs_req) begin
        $write("[hs] clk=%0d UPLOAD REQUEST, table:", hs_clk);
        for (hs_k = 0; hs_k < 80; hs_k = hs_k + 1) $write(" %02x", hs_ram[hs_k]);
        $write("%c", 8'd10);
    end
end
`endif

// Leave the Clear High Scores page after No or Yes (the OSD keeps a page open after a trigger button, but drops back one level when every line of the page is hidden)
reg hs_no_q = 1'b0, hs_yes_q = 1'b0;
reg [25:0] hs_hide_cnt = 26'd0;
always @(posedge clk_sys) begin
    hs_no_q <= status[5];
    hs_yes_q <= status[6];
    if ((status[5] && !hs_no_q) || (status[6] && !hs_yes_q)) begin hs_menu_hide <= 1'b1; hs_hide_cnt <= 26'd48_000_000; end   // about 1 s at 48 MHz, long enough for the OSD to poll the mask
    else if (hs_hide_cnt != 26'd0) begin hs_hide_cnt <= hs_hide_cnt - 26'd1; if (hs_hide_cnt == 26'd1) hs_menu_hide <= 1'b0; end
end

always @(posedge clk_sys) begin
    hs_btn_q <= hs_save_btn;
    hs_c_q <= status[6];
    // factory table capture: once per power on, when the boot initialisation is over and before anything is restored
    // fast path: the game wrote its table since the reset, 50 ms of quiet: check the structure of the table in the game (pass 0), if it is a real table keep a copy as the
    // factory table (pass 1) and then restore the saved one (or just become ready when there is no saved file). One attempt per quiet period (hs_fac_try).
    if (hs_q50 && hs_seen && !hs_fac_try && !hs_fcp_act && !hs_inj && !hs_done && !hs_cp_act) begin
        hs_fcp_act <= 1'b1; hs_fcp_ph <= 1'b0; hs_fcp_i <= 7'd0; hs_fcp_bad <= 1'b0; hs_fac_try <= 1'b1;
    end
    if (hs_fcp_act) begin
        if (!hs_fcp_ph && !hs_fcp_nok) hs_fcp_bad <= 1'b1;
        if (hs_fcp_i == 7'd79) begin
            if (!hs_fcp_ph) begin
                if (hs_fcp_nok && !hs_fcp_bad) begin hs_fcp_ph <= 1'b1; hs_fcp_i <= 7'd0; end   // a real table: copy it
                else hs_fcp_act <= 1'b0;                                                         // not a table (RAM test): wait for the next quiet period
            end else begin
                hs_fcp_act <= 1'b0; hs_fac_valid <= 1'b1;
                if (hs_loaded) begin hs_inj <= 1'b1; hs_i <= 7'd0; end else hs_done <= 1'b1;
            end
        end else hs_fcp_i <= hs_fcp_i + 1'd1;
    end
    // slow path (fallback): 4.2 s of quiet and nothing happened yet: restore the saved table without any check
    if (hs_qdone && !hs_fcp_act && !hs_inj && !hs_done && !hs_cp_act) begin
        if (hs_loaded) begin hs_inj <= 1'b1; hs_i <= 7'd0; end else hs_done <= 1'b1;
    end
    // Clear High Scores: Yes (status[6]) erases, No (status[5]) does nothing. Only once the boot is over and the factory table is known.
    if (status[6] && !hs_c_q && hs_ready && hs_fac_valid && !hs_cp_act && !hs_inj) begin hs_cp_act <= 1'b1; hs_cp_src <= 1'b1; hs_cp_i <= 7'd0; end
    hs_dl_q <= ioctl_download;
    if (ioctl_download) hs_dl_nv <= (ioctl_index[7:0] == 8'd1);
    if (hs_nv_wr) hs_got <= 1'b1;
    if (hs_dl_q && !ioctl_download && hs_dl_nv && hs_got) hs_loaded <= 1'b1;   // the whole file has arrived
    if (hs_cp_act) begin                                                        // copying the shadow to the restore copy (80 clocks)
        if (hs_cp_i == 7'd79) begin
            hs_cp_act <= 1'b0; hs_loaded <= 1'b1;
            if (hs_cp_src) begin hs_inj <= 1'b1; hs_i <= 7'd0; hs_done <= 1'b0; hs_clr_pend <= 1'b1; end   // Clear: write the factory table (and the HI cell) into the game now
            else hs_done <= 1'b1;                                                                       // Save: the table is already in the game, no restore is needed
        end
        else hs_cp_i <= hs_cp_i + 1'd1;
    end

    if (reset) begin
        hs_seen <= 1'b0; hs_fac_try <= 1'b0; hs_quiet <= 28'd0; hs_inj <= 1'b0; hs_done <= 1'b0; hs_i <= 7'd0; hs_drive <= 1'b0;
        hs_req <= 1'b0;
    end else begin
        hs_req <= 1'b0;
        // the boot initialisation of the table: 4.2 s without a write (counted from the end of the reset) ends it
        // (the watch starts when the reset ends, not at the first write: after an OSD Reset the game may restart without touching the table at all)
        if (hs_tbl_we && !hs_inj) begin hs_seen <= 1'b1; hs_quiet <= 28'd0; hs_fac_try <= 1'b0; end
        else if (!hs_qdone) hs_quiet <= hs_quiet + 1'd1;
        // the restore: one write per CPU cycle that leaves the VRAM alone
        if (bos_clk_12m) begin
            hs_drive <= 1'b0;
            if (hs_inj && hs_cycle_ok) begin
                hs_drive  <= 1'b1;
                // 80 table bytes, then the 3 byte HI score shown at the top of the screen (VRAM 0x1050-0x1052, the game copies it from the first table
                // entry during its own boot, so it must be restored separately; it is the first entry's score again)
                hs_addr_q <= (hs_i < 7'd80) ? (14'h1100 + {7'd0, hs_i}) : (14'h1050 + {7'd0, hs_i} - 14'd80);
                hs_din_q  <= (hs_i < 7'd80) ? hs_sav[hs_i] : hs_sav[hs_i - 7'd80];
                if (hs_i == 7'd82) begin hs_inj <= 1'b0; hs_done <= 1'b1; if (hs_clr_pend) begin hs_clr_pend <= 1'b0; hs_req <= 1'b1; end end   // after a Clear the file is saved too
                else hs_i <= hs_i + 1'd1;
            end
        end
        // saving: the OSD button asks the HPS to save the shadow copy (ignored until the boot initialisation is over, so a boot time table is never saved)
        if (hs_save_btn && !hs_btn_q && hs_ready && !hs_cp_act && !hs_inj) begin hs_req <= 1'b1; hs_cp_act <= 1'b1; hs_cp_src <= 1'b0; hs_cp_i <= 7'd0; end
    end
end
wire k007342_re =  cpu_rw && (k007342_cs || ctrl_cs);
wire k007342_scroll_we = !cpu_rw && scroll_cs;

k007342 #(.OVERSCAN_MASK(0)) k007342_inst (
    .clk(clk_sys),
    .reset(reset),
    .layer1_enable(1'b0), // Battlantis uses only tilemap 0 (layer 1 is CPU scratch RAM), per MAME screen_update
    .alt_priority_mode(1'b0), // Battlantis / Battlantis draw order
    .tile_code_layout(1'b0), // Battlantis / Battlantis tile_callback bit order

    .vblank(),
    .int_enabled(int_enabled),
    .sprite_wrap_y(sprite_wrap_y),
    .flip_screen_req(flip_screen_req),
    .vram_bank(1'b0), // no evidence bladestl banks VRAM (same as Battlantis/Battlantis)

    .cpu_addr(k007342_cpu_addr),
    .cpu_din(k007342_cpu_din),
    .cpu_dout(k007342_dout),
    .cpu_we(k007342_cpu_we),
    .cpu_re(k007342_re),

    .scroll_addr(cpu_addr[8:0]),
    .scroll_din(cpu_dout),
    .scroll_dout(k007342_scroll_dout),
    .scroll_we(k007342_scroll_we),

    .ce_pix(ce_pix),
    .h_cnt(h_cnt[8:0]),
    .v_cnt(v_cnt[8:0]),

    .ioctl_wr(p0_req_w), // Round 53b: same strobe as the sprite chip and the SDRAM arbiter (ioctl_download & ioctl_wr on hardware, the poked register in simulation)
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),

    .irq(k007342_irq),
    .irq_ack(k007342_irq_ack),
    .pixel_color(k007342_pixel),
    .pixel_priority(k007342_priority),

    .shadow_sdram_req(tile_sdram_req),
    .shadow_sdram_addr(tile_sdram_addr),
    .shadow_sdram_dout(tile_sdram_dout),
    .shadow_sdram_ready(tile_sdram_ready),
    .shadow_verify_addr_out(),
    .shadow_verify_expected_out(),
    .shadow_verify_actual_out(),
    .shadow_verify_match_out(),
    .shadow_verify_pass_count_out(),
    .shadow_verify_fail_count_out(),
    .shadow_max_wait_cycles_out(),
    .shadow_currently_stuck_out(),
    .cache_sim_hit_count_out(),
    .cache_sim_miss_count_out(),
    .port3_busy(p3_active)
);

// ==============================================================================
// K007420 SPRITE GENERATOR (0x2000-0x21ff)
// ==============================================================================
wire k007420_we = !cpu_rw && k007420_cs;
wire [7:0] k007420_dout;
wire [7:0] k007420_pixel;
wire       k007420_active;

k007420 #(.USE_PROM(0), .SPRITE_Y_ADJ(0)) sprite_gen (   // Battlantis sprites already match MAME, see k007420.v
    .clk(clk_sys),
    .reset(reset),

    .spritebank(rack_sprite_bank),
    .wrap_y(sprite_wrap_y),
    .sprite_color_base(4'd4), // MAME gfx_battlnts_spr: colour base 64 (4 * 16)

    .cpu_addr(cpu_addr[8:0]),
    .cpu_din(cpu_dout),
    .cpu_dout(k007420_dout),
    .cpu_we(k007420_we),

    .ce_pix(ce_pix),
    .h_cnt(h_cnt[8:0]),
    .v_cnt(v_cnt[8:0]),

    .ioctl_wr(p0_req_w), // same value as (ioctl_download & ioctl_wr) on hardware; the poked register
                         // in Verilator (see p0_req_w above), so the sprite colour PROM snoop actually
                         // sees the download strobe in simulation (Round 50)
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),

    .sprite_color(k007420_pixel),
    .sprite_active(k007420_active),

    .sprite_sdram_req(sprite_sdram_req),
    .sprite_sdram_addr(sprite_sdram_addr),
    .sprite_sdram_dout(sprite_sdram_dout),
    .sprite_sdram_dout2(sprite_sdram_dout2),
    .sprite_sdram_ready(sprite_sdram_ready),
    .sprite_traffic_active(1'b1), // no boot-time self-test phase in this core (unlike Rack 'Em
                                   // Up's box8 loopback verify), so Port 3 traffic is always
                                   // genuinely this module's own from time zero.

    .diag_sdram_req_count(),
    .diag_sdram_ready_count(),
    .max_sdram_addr_out(),
    .frame_has_nonzero_out(),
    .max_addr_sprite_idx_out(),
    .max_addr_code_lsb_out(),
    .max_addr_attr_out(),
    .max_addr_flags_out(),
    .bram_debug_out(),
    .last_fetch_addr_out(),
    .last_fetch_nonzero_out(),
    .last_fetch_sprite_idx_out(),
    .last_fetch_code_lsb_out(),
    .last_fetch_attr_out(),
    .last_fetch_flags_out(),
    .last_bram_addr_out(),
    .last_bram_sprite_idx_out(),
    .last_bram_code_lsb_out(),
    .last_bram_attr_out(),
    .last_bram_flags_out(),
    .zoom_wrap_hit_out(),
    .zoom_wrap_sprite_idx_out(),
    .zoom_wrap_zoom_raw_out(),
    .zoom_wrap_spr_y_out(),
    .zoom_wrap_draw_x_out(),
    .zoom_wrap_v_cnt_out(),
    .zoom_wrap_tile_idx_out(),
    .last_bram_was_sdram_out(),
    .max_bram_addr_used_out(),
    .small_sdram_addr_out(),
    .small_sdram_idx_out(),
    .small_sdram_code_lsb_out(),
    .small_sdram_attr_out(),
    .small_sdram_flags_out(),
    .small_sdram_nonzero_out()
);

// ==============================================================================
// PALETTE RAM (0x2400-0x245f, 96 bytes = 48 entries x 2-byte xBGR_555) --
// confirmed exact size from bladestl_mame.cpp: `map(0x2400,
// 0x245f).ram().w(...).share("palette")`. Smaller than Battlantis/Rack 'Em
// Up's 512-byte/256-entry palette because bladestl's sprite colors (32-47)
// go through an additional 256-byte lookup PROM ("proms" ROM region) before
// indexing this RAM -- that indirect remap is NOT implemented yet (flagged
// below), so sprite colors will be approximately, not exactly, correct
// until it's added.
// ==============================================================================
(* ramstyle = "M10K" *) reg [7:0] bos_palette_ram [0:511];
reg [7:0] bos_palette_dout;
always @(posedge clk_sys) begin
    if (palette_cs && !cpu_rw && cpu_e) bos_palette_ram[cpu_addr[8:0]] <= cpu_dout;
    bos_palette_dout <= bos_palette_ram[cpu_addr[8:0]]; // registered read -- see bos_work_ram's own comment
                                                          // above for why (async reads can't map to M10K)
end

// ==============================================================================
// PLAYER INPUTS / DIP SWITCHES (MAME battlnts.cpp INPUT_PORTS battlantis, konamipt.h macros)
// ==============================================================================
// Controller buttons (J1 line): bit 4 = Fire, bit 5 = Coin, bit 6 = Start. The second controller is player 2 with the same layout.
// Keyboard: coin 5 and 6, start 1 and 2 only (player 2 has no keyboard stick or fire, removed on request in v2.0.1); player 1 keyboard play comes through
// the framework's joystick mapping (joystick_0).
reg kb_coin1, kb_coin2, kb_start1, kb_start2;
reg kb_old_stb;
always @(posedge clk_sys) begin
    kb_old_stb <= ps2_key[10];
    if (kb_old_stb != ps2_key[10] && !ps2_key[8]) begin
        case (ps2_key[7:0])
            8'h2E: kb_coin1  <= ps2_key[9];   // 5
            8'h36: kb_coin2  <= ps2_key[9];   // 6
            8'h16: kb_start1 <= ps2_key[9];   // 1
            8'h1E: kb_start2 <= ps2_key[9];   // 2
            default: ;
        endcase
    end
end
wire [31:0] joy1 = joystick_1;   // player 2 plays on the second controller only (no keyboard stick or fire)

// P1 / P2: KONAMI8_B1: bit0 Left, bit1 Right, bit2 Up, bit3 Down, bit4 Button 1, bits 5 and 6 unused (all active low). P1 bit 7 is the
// "Allow Continue" DIP (SW3:4): 0x80 = 3 times, 0x00 = 5 times; P2 bit 7 is unused.
// joystick bits from hps_io are active high: 0 Right, 1 Left, 2 Down, 3 Up.
wire [7:0] rack_p1 = { status[50], 1'b1, 1'b1, ~joystick_0[4], ~joystick_0[2], ~joystick_0[3], ~joystick_0[0], ~joystick_0[1] };
wire [7:0] rack_p2 = { 1'b1,       1'b1, 1'b1, ~joy1[4],       ~joy1[2],       ~joy1[3],       ~joy1[0],       ~joy1[1] };

// DSW3 (0x2e03): bit0 coin 1, bit1 coin 2, bit2 service 1 (not wired), bit3 start 1, bit4 start 2, bit5 flip screen DIP (0 = on),
// bit6 upright controls (1 = single, 0 = dual), bit7 service mode (active low).
wire [7:0] rack_dsw3 = {
    ~status[17],                    // bit7 service mode
    ~dual_ctrl,                     // bit6 upright controls: OSD Single (0) -> 1, Cabinet Cocktail forces Dual (0)
    ~status[16],                    // bit5 flip screen
    ~(joystick_1[6] | joystick_0[7] | kb_start2),   // bit4 start 2 (Start 2 on controller 2, or the Start 2 button of controller 1, or key 2)
    ~(joystick_0[6] | kb_start1),   // bit3 start 1
    1'b1,                           // bit2 service 1
    ~(joystick_1[5] | kb_coin2),    // bit1 coin 2
    ~(joystick_0[5] | kb_coin1)     // bit0 coin 1
};

// DSW2 (0x2e04): bits 1:0 lives, bit 2 cabinet, bits 4:3 bonus life, bits 6:5 difficulty, bit 7 demo sounds (0 = on).
// The OSD entries start with the factory default, so the index is translated into the real DIP encoding:
//   Lives        index 0..3 = 3, 5, 7, 2     -> DIP 2, 1, 0, 3
//   Bonus Life   index 0..3 = 30k+70k, 40k+80k, 40k, 50k -> DIP 3, 2, 1, 0 (the complement of the index)
//   Difficulty   index 0..3 = Normal, Easy, Difficult, Very Difficult -> DIP 2, 3, 1, 0
function [1:0] bat_lives(input [1:0] idx);
    case (idx)
        2'd0: bat_lives = 2'd2;
        2'd1: bat_lives = 2'd1;
        2'd2: bat_lives = 2'd0;
        default: bat_lives = 2'd3;
    endcase
endfunction
function [1:0] rack_diff(input [1:0] idx);
    case (idx)
        2'd0: rack_diff = 2'd2;
        2'd1: rack_diff = 2'd3;
        2'd2: rack_diff = 2'd1;
        default: rack_diff = 2'd0;
    endcase
endfunction
wire [7:0] rack_dsw2 = { status[15], rack_diff(status[14:13]), ~status[12:11], status[10], bat_lives(status[20:19]) };

// DSW1 (0x2e00): coinage, bits 3:0 Coin A, bits 7:4 Coin B (konamipt.h KONAMI_COINAGE_LOC). OSD index -> real nibble, factory default (1C 1C) first,
// the last entry is Free Play (Coin A) / No Coin B.
function [3:0] rack_coin_nibble(input [3:0] idx);
    case (idx)
        4'd0:  rack_coin_nibble = 4'hF; // 1C_1C
        4'd1:  rack_coin_nibble = 4'h2; // 4C_1C
        4'd2:  rack_coin_nibble = 4'h5; // 3C_1C
        4'd3:  rack_coin_nibble = 4'h8; // 2C_1C
        4'd4:  rack_coin_nibble = 4'h4; // 3C_2C
        4'd5:  rack_coin_nibble = 4'h1; // 4C_3C
        4'd6:  rack_coin_nibble = 4'h3; // 3C_4C
        4'd7:  rack_coin_nibble = 4'h7; // 2C_3C
        4'd8:  rack_coin_nibble = 4'hE; // 1C_2C
        4'd9:  rack_coin_nibble = 4'h6; // 2C_5C
        4'd10: rack_coin_nibble = 4'hD; // 1C_3C
        4'd11: rack_coin_nibble = 4'hC; // 1C_4C
        4'd12: rack_coin_nibble = 4'hB; // 1C_5C
        4'd13: rack_coin_nibble = 4'hA; // 1C_6C
        4'd14: rack_coin_nibble = 4'h9; // 1C_7C
        default: rack_coin_nibble = 4'h0; // Free Play / No Coin B
    endcase
endfunction
wire [7:0] rack_dsw1 = { rack_coin_nibble(status[28:25]), rack_coin_nibble(status[24:21]) };

assign cpu_din =
    fixed_rom_cs  ? rack_rom_dout        :
    banked_rom_cs ? rack_rom_dout        :
    (k007342_cs || ctrl_cs) ? k007342_dout :
    k007420_cs    ? k007420_dout        :
    scroll_cs     ? k007342_scroll_dout :
    palette_cs    ? bos_palette_dout    :
    dsw1_cs       ? rack_dsw1           :
    p2_cs         ? rack_p2             :
    p1_cs         ? rack_p1             :
    dsw3_cs       ? rack_dsw3           :
    dsw2_cs       ? rack_dsw2           :
    8'hFF; // write-only registers and unmapped addresses read as open bus

wire [7:0] bg_pixel     = k007342_pixel;
// Round 13: k007420's own sprite palette bank is now data-driven
// (sprite_color_base=4'd2 at the instantiation above), matching bladestl's
// real 0x20-0x2f range instead of aliasing/wrapping to palette entry 0.
// TODO (still not fixed): real hardware additionally remaps the sprite
// pixel through a 256-byte lookup PROM (`color_prom[pixel-0x20]&0x0f)|0x20`,
// from the "proms" ROM region) before it becomes the final palette index --
// not loaded or applied yet, so sprite colors will be closer to correct
// after this round but not pixel-exact.
wire [7:0] sprite_pixel = k007420_pixel;
wire bg_priority    = k007342_priority;
// Round 53b: the old extra test sprite_pixel[3:0] != 0 was a leftover from before the colour PROM was loaded (then [3:0] was the raw ROM pixel). Now
// sprite_pixel[3:0] is the PROM output, and the PROM maps raw pixel 1 of colours 0 and 1 and pixel 14 of colour 8 to 0, i.e. palette pen 0x20, which is
// BLACK. MAME decides transparency on the raw pixel only, so those pixels are drawn black; here they were dropped: every sprite lost its black outline
// pixels (228 of 280 test states, median 1125 pixels). k007420_active is already 'a raw non zero pixel was drawn here' (the line buffer is cleared to 0).
wire sprite_visible = k007420_active && sprite_pixel[3:0] != 4'd0;
wire show_sprite    = sprite_visible && (!bg_priority || (bg_pixel[3:0] == 4'd0));
wire [7:0] pixel_color = show_sprite ? sprite_pixel : bg_pixel;

reg [7:0] pal_byte_even, pal_byte_odd;
wire [8:0] pal_addr_even = {pixel_color, 1'b0};
wire [8:0] pal_addr_odd  = {pixel_color, 1'b1};
always @(posedge clk_sys) begin
    if (ce_pix) begin
        pal_byte_even <= bos_palette_ram[pal_addr_even];
        pal_byte_odd  <= bos_palette_ram[pal_addr_odd];
    end
end

wire [4:0] pal_r = pal_byte_odd[4:0];
wire [4:0] pal_g = {pal_byte_even[1:0], pal_byte_odd[7:5]};
wire [4:0] pal_b = pal_byte_even[6:2];
wire [7:0] video_r = {pal_r, pal_r[4:2]};
wire [7:0] video_g = {pal_g, pal_g[4:2]};
wire [7:0] video_b = {pal_b, pal_b[4:2]};

// ==============================================================================
// SOUND (Z80 + two YM3812), rtl/battlantis_sound.v. Z80 at 24 MHz / 6 = 4 MHz, YM3812 at 24 MHz / 8 = 3 MHz (MAME battlnts.cpp).
// ==============================================================================
reg [3:0] z80_ce_div = 0;
always @(posedge clk_sys) z80_ce_div <= (z80_ce_div == 4'd11) ? 4'd0 : z80_ce_div + 4'd1;
wire ce_z80 = (z80_ce_div == 4'd11);        // 48 MHz / 12 = 4 MHz
reg [3:0] ym_ce_div = 0;
always @(posedge clk_sys) ym_ce_div <= ym_ce_div + 4'd1;
wire ce_ym3812 = (ym_ce_div == 4'd15);      // 48 MHz / 16 = 3 MHz

wire ioctl_sound_we = ioctl_download && ioctl_wr && rom_idx && ioctl_addr >= 25'h18000 && ioctl_addr < 25'h20000;   // 32 KB sound ROM
wire signed [15:0] audio_l, audio_r;
battlantis_sound battlantis_sound (
    .clk(clk_sys),
    .rst(reset),
    .ce_z80(ce_z80),
    .ce_ym3812(ce_ym3812),
    .snd_latch(sound_latch_to_z80),
    .snd_irq(sound_irq_to_z80),
    .ioctl_sound_addr(ioctl_addr[14:0]),
    .ioctl_sound_data(ioctl_dout),
    .ioctl_sound_we(ioctl_sound_we),
    .vol1(status[33:29]),
    .vol2(status[38:34]),
    .stereo(status[39]),
    .audio_l(audio_l),
    .audio_r(audio_r),
    .irq_ack(z80_irq_ack)
);
// Treble (OSD, Sound page): Original passes the mix through untouched, Soft / Softer / Muffled run it through a one pole low pass (rtl/audio_lp.v).
wire signed [15:0] audio_out_l, audio_out_r;
audio_lp audio_lp (
    .clk(clk_sys),
    .ce(ce_ym3812),
    .mode(status[8:7]),
    .in_l(audio_l),
    .in_r(audio_r),
    .out_l(audio_out_l),
    .out_r(audio_out_r)
);
assign AUDIO_L = audio_out_l;
assign AUDIO_R = audio_out_r;

// Round 50: pixel_color (k007342/k007420, registered on ce_pix) and the palette lookup (registered on ce_pix)
// put the picture 2 pixel clocks behind h_cnt. DE and the colour gating used the undelayed active_area, so
// the first 2 output pixels of every line were stale and the last 2 picture pixels were cut off (measured
// against MAME: tiles and sprites both dh = +2). Delay the active window by the same 2 ce_pix instead.
reg [1:0] active_pipe = 2'b00;
always @(posedge clk_sys) if (ce_pix) active_pipe <= {active_pipe[0], active_area};
wire active_disp = active_pipe[1];


`ifdef BOS_SDRAM_MON
// SDRAM health monitor rows: 11 rows of 16 boxes, row r at lines 20 + 14 r .. +9 (raw screenshot y = line - 16), box i at x = 16 i + 3 .. 12.
// yellow = 1, blue = 0, most significant bit on the left. See rtl/sdram_mon.v for the meaning of each row.
wire [9:0]  mon_vy   = v_cnt - 10'd20;
wire [3:0]  mon_row  = mon_vy / 14;
wire [3:0]  mon_off  = mon_vy % 14;
wire [3:0]  mon_col  = h_cnt[7:4];
wire        mon_box  = (h_cnt < 256) && (h_cnt[3:0] >= 4'd3) && (h_cnt[3:0] <= 4'd12) && (v_cnt >= 20) && (mon_row < 4'd11) && (mon_off < 4'd10);
wire [3:0]  mon_rsel = 4'd10 - mon_row;
wire [7:0]  mon_bit  = {mon_rsel, 4'd0} + {4'd0, 4'd15 - mon_col};   // (10 - row) * 16 + (15 - col)
wire        mon_flag = mon_rows[mon_bit];
wire        mon_hit  = active_disp & mon_box;
wire [23:0] mon_rgb24 = mon_flag ? 24'hFFFF00 : 24'h0000FF;
`endif

// ---- video output ----------------------------------------------------------------------------------------------------------
// Round 55: the picture now goes through the framework's arcade_video (sync polarity fix, blanking, gamma) exactly like Battlantis; its
// outputs feed the DDR3 hub, whose crt_* outputs are the VGA_* pins (raw 15 kHz raster or rotated picture). The hub takes the same signals and,
// when HDMI Orientation is Horizontal, writes a rotated copy into DDR3 and switches the HDMI scaler to read it (framebuffer mode).
`ifdef BOS_SDRAM_MON
wire [7:0] out_r = mon_hit ? mon_rgb24[23:16] : (active_disp ? video_r : 8'd0);
wire [7:0] out_g = mon_hit ? mon_rgb24[15:8]  : (active_disp ? video_g : 8'd0);
wire [7:0] out_b = mon_hit ? mon_rgb24[7:0]   : (active_disp ? video_b : 8'd0);
`else
wire [7:0] out_r = active_disp ? video_r : 8'd0;
wire [7:0] out_g = active_disp ? video_g : 8'd0;
wire [7:0] out_b = active_disp ? video_b : 8'd0;
`endif

wire [7:0] av_vga_r, av_vga_g, av_vga_b;
wire       av_vga_hs, av_vga_vs, av_vga_de;

arcade_video #(256, 24) arcade_video (
    .clk_video(clk_sys),
    .ce_pix(ce_pix),
    .RGB_in({out_r, out_g, out_b}),
    .HBlank(~active_disp),
    .VBlank(VBlank),
    .HSync(HSync),
    .VSync(VSync),
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(av_vga_r),
    .VGA_G(av_vga_g),
    .VGA_B(av_vga_b),
    .VGA_HS(av_vga_hs),
    .VGA_VS(av_vga_vs),
    .VGA_DE(av_vga_de),
    .VGA_SL(VGA_SL),
    .fx(3'b000),               // no scanline or hq2x entry in the OSD
    .forced_scandoubler(1'b0), // the analog port always carries the raw 15 kHz raster, as on the real board
    .gamma_bus(gamma_bus)
);

// The analog pins always come from the hub: the rotated picture while CRT Orientation is Horizontal, otherwise the same raw raster, both through the
// same two pixel clock pipeline (so switching the option does not glitch the sync).
assign VGA_R  = crt_r;
assign VGA_G  = crt_g;
assign VGA_B  = crt_b;
assign VGA_HS = crt_hs;
assign VGA_VS = crt_vs;
assign VGA_DE = crt_de;

// The game's own flip request (K007342 register 0 bit 4, written by the game when its Flip Screen DIP is on) and the OSD Flip Monitor are
// combined with an xor: one flips, both cancel. In the rotated path the flip selects the rotation direction (clockwise or counter
// clockwise), in the raw path it is a 180 degree flip (screen_rotate ignores it while rotating).
// Battlantis: the game's own flip request (K007342 reg 0 bit 4) is NOT used. This ROM toggles it at times a real board does not (a long
// standing, never fully traced divergence in the old project notes, Rounds 213 to 221), which turned the HDMI picture upside down at boot.
// Battlantis ignores it for the same reason (cocktail flip dropped as not authentic); the Flip Monitor option covers anyone who needs a flip.
wire effective_flip = flip_monitor;
// Cocktail cabinet: with the Cabinet DIP set to Cocktail the game itself flips the picture for player 2's turn (K007342 register 0 bit 4, flip_screen_req).
// That is applied to the ANALOG output only (the MiSTer in a real cocktail cabinet drives a CRT through the analog port); the HDMI picture never
// flips on its own. With the DIP on Upright the request is ignored altogether, which also keeps the toggling this ROM does at boot (a real board
// does not show it) away from normal cabinets. Turns the CRT picture by 180 degrees in either CRT orientation, like the CRT Flip option.
wire cocktail_flip = status[10] & flip_screen_req;
wire video_rotated;

ddr_rotate_hub ddr_rotate_hub (
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(av_vga_r),
    .VGA_G(av_vga_g),
    .VGA_B(av_vga_b),
    .VGA_HS(av_vga_hs),
    .VGA_VS(av_vga_vs),
    .VGA_DE(av_vga_de),
    .rotate_ccw(effective_flip),
    .no_rotate(no_rotate),
    .flip(effective_flip),
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
    .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .DDRAM_DIN(DDRAM_DIN),
    .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE),
    .DDRAM_RD(DDRAM_RD),
    .crt_en(crt_rot_sel),
    .crt_flip(crt_flip ^ cocktail_flip),   // CRT Flip option, plus the cocktail table's flip (analog output only)
    .crt_size(crt_size),
    .crt_sq(~status[60]),        // CRT Aspect: Square pixels (0, default) or Arcade 3:4 (1)
    .crt_smooth(~status[61]),    // CRT Smoothing: On (0, default) or Off (1)
    .crt_hpos(5'd16),            // picture position comes from the sync shift (CRT Position options), no extra trim
    .crt_vpos(5'd16),
    .crt_r(crt_r),
    .crt_g(crt_g),
    .crt_b(crt_b),
    .crt_hs(crt_hs),
    .crt_vs(crt_vs),
    .crt_de(crt_de),
    .crt_ready(crt_ready),
    .crt_status(crt_status)
);

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1; 
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

endmodule
