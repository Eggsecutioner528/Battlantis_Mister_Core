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
assign LED_DEBUG = 8'd0;

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
    // 2026-08-20, task #24: this is the existing, already-working control
    // for a physical vertical arcade monitor/cabinet -- select "Vertical"
    // here (not a separate build or RTL change). If the image then reads
    // upside-down in that orientation, pair it with "Flip Monitor" below.
    // See the orientation_vertical/flip_monitor comment further down this
    // file for the full internal wiring (screen_rotate's no_rotate/flip/
    // rotate_ccw) behind these two menu entries.
    //
    // Task #24 CLOSED (2026-08-27) as a documented limitation: these two
    // options only rotate content for the DDR3-backed scaled VGA/HDMI
    // path (via screen_rotate below). The CRT on the Analog IO board uses
    // MiSTer's Direct Video mode, which bypasses DDR3/the scaler entirely
    // by design (near-zero latency, cycle-locked to the game's own raster) --
    // there is no framebuffer there to rotate. A dedicated on-chip
    // frame-buffer for Direct Video was scoped but found infeasible on
    // this FPGA: the design already uses 100% of the DE10-Nano's on-chip
    // RAM blocks (`output_files/Template.fit.summary`: 553/553), with
    // zero headroom for the ~100-200 additional blocks a 256x224
    // double-buffered rotator would need. Direct Video therefore stays
    // Portrait-only by design (matching a real MiSTerCade-style
    // physically-rotated cabinet, which is what this ROT90 game's raw
    // signal already assumes) -- Landscape/non-rotated-CRT users should
    // use these two options here via scaled VGA/HDMI instead. See TASKS.md
    // Task #24, Round 166 for the full investigation.
    "O[1],Orientation,Horizontal,Vertical;",
    "O[2],Flip Monitor,Off,On;",
    "-;",
    "O[4:3],Aspect ratio,Original,Pixel Perfect,Full Screen;",
    "-;",
    "O[6:5],Lives,7,5,3,2;",
    "O[16],Continues,5 Times,3 Times;",
    "O[8:7],Difficulty,Very Difficult,Hard,Normal,Easy;",
    "O[10:9],Bonus Life,50k,40k,40k/80k,30k/70k;",
    "-;",
    "O[11],Demo Sounds,On,Off;",
    "O[12],Cabinet,Upright,Cocktail;",
    "O[14],Upright Controls,Single,Dual;",
    "O[15],Mode,Game,Test;",
    "O[20:17],Coin 1,1C 1C,1C 2C,1C 3C,1C 4C,1C 5C,1C 6C,1C 7C,2C 1C,2C 3C,2C 5C,3C 1C,3C 2C,3C 4C,4C 1C,4C 3C,Free Play;",
    "O[24:21],Coin 2,1C 1C,1C 2C,1C 3C,1C 4C,1C 5C,1C 6C,1C 7C,2C 1C,2C 3C,2C 5C,3C 1C,3C 2C,3C 4C,4C 1C,4C 3C,Free Play;",
    "-;",
    "O[30],Pause Game,Off,On;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    // 2026-08-28/29, task #81, CLOSED: this line originally sat right
    // after "Battlantis;;", at the very top of CONF_STR -- that placement
    // caused a real OSD navigation off-by-one (selecting one menu item
    // activated the item below it; "Reset and close OSD" only closed).
    // Moved here, immediately before the version line, matching the more
    // common placement seen in other MiSTer cores -- confirmed fixed on
    // real hardware.
    // 2026-08-29, player feedback: extended from just "Fire" to name the
    // real joystick button bits this core reads (m_coin1/m_start1/m_test
    // wiring further down this file) -- bit4=Fire, bit5=Coin, bit6=Start,
    // in that order, matching MiSTer's "Define joystick" mapping screen's
    // implicit bit-position convention (bits 0-3 are always the 4
    // directions, unnamed/implicit; named buttons start at bit4 in listed
    // order, packed with no gaps). A single "J1" line covers BOTH players
    // symmetrically -- MiSTer applies the same named button list to
    // whichever physical controller is in the Player 2 slot too
    // (player_2_inputs below reads joystick_1 with the identical bit
    // layout); there is no separate "J2" directive in real MiSTer
    // convention. A prior version of this line invented one ("J2,...;"),
    // which isn't real MiSTer syntax and left Player 2 with no working
    // Start/button mapping UI at all -- removed.
    // A version right before this one tried leaving bit6 as an empty,
    // unnamed slot (the double-comma, "J1,Fire,Coin,,Start;") to drop the
    // redundant Test button while keeping Start anchored to bit7 -- that
    // syntax did not work as assumed and broke Start entirely (it stopped
    // registering in-game). Fixed properly this time: Start and Test
    // (m_test below) simply trade bit positions, so the named list packs
    // cleanly into bits 4/5/6 with zero gaps and nothing relies on
    // unverified CONF_STR skip syntax. Test moves to the now-unnamed
    // bit 7 -- redundant with the OSD's own "Mode: Game/Test" option
    // anyway, so not needing a "Define joystick" prompt is fine.
    // 2026-09-02: added "Pause" at bit8 -- a real, remappable button that
    // toggles the existing pause_cpu debug freeze (previously OSD-menu-only
    // via status[30]) so pausing right at boot (e.g. to inspect the
    // self-test screen, task #83) doesn't require navigating the OSD.
    "J1,Shoot (Fire),English (Aim),Coin,Start,Pause;",
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
    .sdram_clk_in(sdram_clk_shifted),

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

    // 2026-08-28: K007342 Layer 1 game-content detection. Confirmed in
    // simulation (see project_history/TASKS.md's Rack 'Em Up section) that
    // Battlantis's own ROM uses most of K007342's Layer 1 VRAM as CPU
    // scratch RAM rather than real tile data -- compositing Layer 1 into
    // the video output unconditionally (needed for Rack 'Em Up, which DOES
    // use Layer 1 for real graphics) makes that scratch data render as
    // widespread garbage on Battlantis (measured: 68.55% of pixels showing
    // Layer 1 content in a Verilator run). Both games load the same
    // bitstream, so this can't be a compile-time choice -- it's derived
    // from the ROM content itself, latched from the banked ROM's very
    // first downloaded byte (ioctl_addr==0), which is real 6809/6309
    // program code and reliably differs between the two games' actual
    // compiled ROMs (confirmed directly: Battlantis's is 8'h03, Rack 'Em
    // Up's is 8'h40). Defaults toward enabling Layer 1 (the real, generic
    // K007342 behavior) for anything that isn't specifically Battlantis's
    // own known signature, rather than defaulting off and needing a
    // signature for every future game that might reuse this core.
    // NOTE: no reset gating here, deliberately -- `reset` (declared
    // further below) is `sys_reset | ioctl_download`, high for the whole
    // duration of every ROM download, so an `if (reset) ... else if
    // (ioctl_download && ...)` structure would always take the reset
    // branch and the capture would never fire; a first attempt gating on
    // `sys_reset` alone instead of the combined `reset` still produced no
    // real change in behavior (Verilator's layer1_wins stayed identical
    // to the ungated version), consistent with (though not fully isolated
    // as definitely caused by) `sys_reset` also still being asserted
    // through the download window in this harness. Removed the reset
    // branch entirely instead of chasing the exact cause further -- this
    // matches the `banked_rom` write logic immediately above, which also
    // has no reset gate at all and is proven working. The register's
    // power-on value is irrelevant since this capture unconditionally
    // fires during the very same download that also populates
    // 2026-09-02: MAME battlnts.cpp screen_update confirms that BOTH Battlantis
    // and Rack 'Em Up / The Hustler (GX765/GX777) use ONLY Tilemap 0 (Layer 0)
    // with Category 0 (below sprites) and Category 1 (priority attr[7] above sprites).
    // Layer 1 is not used by either game. Enabling Layer 1 caused unwritten VRAM
    // in the Layer 1 address range (0x1000-0x1FFF) to fetch tile 0x00 (the donut glyph)
    // and composite it across the entire screen.
    wire layer1_enable = 1'b0;

    // Running XOR checksum of every byte written to the sprite ROM range
    // (0x20000-0x5FFFF) during the real download -- a single 8-bit
    // accumulator, replacing an earlier 16-entry address/expected-value
    // lookup table approach (528 bits of initialized ROM-like storage) that
    // caused an exceptionally long compile (>105 minutes vs the ~15 minute
    // norm every other compile this session hit, killed without finishing).
    // Reset on sys_reset only (NOT the ioctl_download-inclusive `reset`
    // wire), since this must keep accumulating throughout the whole
    // download period, not be held at zero during it.
    reg [7:0] download_xor_checksum = 8'h00;
    always @(posedge clk_sys) begin
        if (sdram_reset) begin
            download_xor_checksum <= 8'h00;
        end else if (ioctl_download && ioctl_wr) begin
            if (ioctl_addr >= 25'h20000 && ioctl_addr < 25'h60000) begin
                download_xor_checksum <= download_xor_checksum ^ ioctl_dout;
            end
        end
    end

`ifdef SIM_SPRITE_SDRAM_PROBE
    // TEMP (2026-08-30): trace Battlantis.sv's own top-level view of
    // ioctl_wr/ioctl_addr/ioctl_download/ioctl_dout for the one address the
    // sprite-SDRAM-vs-BRAM comparison found permanently missing from
    // sprite_rom_bram (absolute 0x20060) -- isolates whether the pulse is
    // already missing at this module's own boundary (upstream of k007420)
    // or only lost specifically inside k007420's own write-enable logic.
    always @(posedge clk_sys) begin
        if (ioctl_wr && ioctl_addr == 25'h20060) begin
            $display("[TOP-WRITE-TRACE] ioctl_wr addr=0x20060 data=0x%02x ioctl_download=%b t=%0t",
                      ioctl_dout, ioctl_download, $time);
        end
    end

    // TEMP (2026-08-30): total-pulse counter for the NAMED wire feeding
    // k007420 specifically, to cross-check against k007420.v's own
    // local_total_wr_count (which reads zero) -- if THIS side already
    // shows zero, the break is upstream of k007420 despite the top-level
    // ioctl_wr/ioctl_download trace above firing correctly; if this reads
    // the full 655360, the break is specifically at/inside the k007420
    // instance boundary.
    reg [31:0] sprite_gen_ioctl_wr_total_count = 32'd0;
    always @(posedge clk_sys) begin
        if (sprite_gen_ioctl_wr) begin
            sprite_gen_ioctl_wr_total_count <= sprite_gen_ioctl_wr_total_count + 32'd1;
        end
    end
`endif

    reg [7:0] fixed_rom_dout;
    reg [7:0] banked_rom_dout;

    always @(posedge clk_sys) begin
        fixed_rom_dout  <= fixed_rom[cpu_addr[14:0]];
        banked_rom_dout <= banked_rom[{rom_bank[1:0], cpu_addr[13:0]}];
    end
    wire [7:0] cpu_rom_dout = (cpu_addr >= 16'h8000) ? fixed_rom_dout : banked_rom_dout;

    // Continuous live SDRAM read-back probe (2026-08-12, Test 177): unlike
    // Box8's verify sweep (runs once, ~100ms after download, in a quiet
    // boot-time window with no other Port traffic) and unlike k007420's real
    // Port 3 traffic (which returns 0x00 for confirmed-real, confirmed
    // non-zero high addresses specifically during live per-pixel rendering),
    // this FSM repeatedly re-reads two independently-confirmed-real bytes
    // (0x3BC62 expect 0x56, 0x3F498 expect 0x90 -- the exact addresses first
    // established in Test 158, re-verified directly against the ROM file
    // just before adding this) via Port 1 (the CPU port, otherwise
    // completely unused this whole session -- cpu_sdram_req has been
    // hardwired to 0 throughout). It loops forever once test_done &&
    // verify_done, CONCURRENTLY with k007420's real Port 3 sprite traffic --
    // if these always read back correctly even while k007420 is actively
    // contending for the shared SDRAM/arbiter, that isolates the fault to
    // k007420's own request/response handling specifically, not to
    // SDRAM/arbiter's ability to correctly serve high addresses under real
    // contention.
    reg [1:0] probe_state = 0;
    reg       probe_req = 0;
    reg [24:0] probe_addr;
    reg       probe_which = 0; // 0 = 0x3BC62 (expect 0x56), 1 = 0x3F498 (expect 0x90)
    always @(posedge clk_sys) begin
        if (sys_reset) begin
            probe_state <= 0;
            probe_req   <= 0;
            probe_which <= 0;
        end else begin
            case (probe_state)
                0: begin
                    if (test_done && verify_done) begin
                        probe_addr  <= probe_which ? 25'h3F498 : 25'h3BC62;
                        probe_state <= 1;
                    end
                end
                1: begin
                    probe_req   <= 1;
                    probe_state <= 2;
                end
                2: begin
                    if (cpu_sdram_ready) begin
                        probe_req <= 0;
                        if (probe_which) begin
                        end else begin
                        end
                        probe_which <= ~probe_which;
                        probe_state <= 0;
                    end
                end
                default: probe_state <= 0;
            endcase
        end
    end

    wire cpu_sdram_req = probe_req;
    wire [24:0] cpu_sdram_addr = probe_addr;
    wire [7:0] cpu_sdram_dout_raw;
    wire cpu_sdram_ready;

    // Port 2 was hardwired idle for most of this session; driven first by
    // k007342's Stage 1 shadow SDRAM verifier (2026-08-13, proved Port 2
    // alone is reliable), then by the Tests 216-219 passive cache-hit-rate
    // simulator (proved a 2048-entry cache gets ~99.9-100% hit rate), and
    // now (2026-08-14, Test 220) by the REAL tile-cache fill state machine
    // -- see the "REAL TILE CACHE + SDRAM-BACKED FILL" comment block in
    // rtl/k007342.v for the current design. Port names below still say
    // "shadow_*" for historical/low-churn reasons (same req/addr/dout/ready
    // interface reused across all of these, only the internal driving logic
    // changed each time) -- read the k007342.v comment for what's actually
    // happening now, not the identifier names.
    wire tile_sdram_req;
`ifdef SIM_ISOLATE_PORT3_FROM_PORT2
    // 2026-08-30 (memory-budget investigation): Verilator-only isolation
    // switch (never defined for a real hardware build) -- forces Port 2
    // (background tile fetches) silent so the sprite_sdram_req probe
    // (SIM_SPRITE_SDRAM_PROBE, k007420.v) can be measured with zero Port
    // 2 contention, mirroring Test 207's own method (debugging_log.md)
    // that proved Port 2 alone is 100% reliable once isolated from Port
    // 3 -- testing here whether the mirror-image is also true for sprites.
    wire p2_mux_req = 1'b0;
`else
    wire p2_mux_req = tile_sdram_req;
`endif
    wire [24:0] tile_sdram_addr;
    wire [7:0] tile_sdram_dout;
    wire tile_sdram_ready;

    wire [17:0] shadow_verify_addr;
    wire [7:0]  shadow_verify_expected;
    wire [7:0]  shadow_verify_actual;
    wire        shadow_verify_match;
    wire [15:0] shadow_verify_pass_count;
    wire [15:0] shadow_verify_fail_count;
    wire [15:0] shadow_max_wait_cycles;
    wire        shadow_currently_stuck;
    wire [23:0] cache_sim_hit_count;
    wire [23:0] cache_sim_miss_count;
    wire        p3_active;

    wire sprite_sdram_req;
    wire [24:0] sprite_sdram_addr;
    wire [7:0] sprite_sdram_dout;
    wire sprite_sdram_ready;

// ==============================================================================
// LOCAL SDRAM LOOPBACK SELF-TEST (Gemini's proposal, 2026-08-10)
// ==============================================================================
// Runs once, entirely inside the FPGA, right after PLL lock and BEFORE any
// IOCTL download starts, completely bypassing HPS. V1 (single write+read)
// PASSED on hardware, proving the physical chip/controller/arbiter all work.
// The p0_busy one-cycle-late race fix (sdram_arbiter.sv) was applied after
// that but did NOT resolve the real symptom -- so this is now V2: four rapid
// back-to-back writes at incrementing addresses (mimicking the real IOCTL
// download's cadence), then four sequential reads. If THIS fails, the
// arbiter itself chokes on streaming (would be visible even in this
// FPGA-only test). If it still passes, the bug is something specific to the
// real external HPS interface that no internal test can replicate.
reg [3:0] test_state = 0;
reg [1:0] write_cnt = 0;
reg [1:0] read_cnt = 0;

reg test_p0_req = 0;
reg [24:0] test_p0_addr;
reg [7:0] test_p0_din;

reg test_p3_req = 0;
reg [24:0] test_p3_addr;
reg [7:0] test_read_data [0:3];
reg test_done = 0;
reg test_success = 0;
reg [3:0] byte_ok = 4'b0000; // per-byte pass/fail, bit i = test_read_data[i] matched

always @(posedge clk_sys) begin
    if (~locked) begin
        test_state   <= 0;
        write_cnt    <= 0;
        read_cnt     <= 0;
        test_p0_req  <= 0;
        test_p3_req  <= 0;
        test_done    <= 0;
        test_success <= 0;
        byte_ok      <= 4'b0000;
    end else begin
        case (test_state)
            0: begin // Wait for SDRAM controller's own startup sequence
                if (sdram_ready) begin
                    test_p0_addr <= 25'h12345;
                    test_p0_din  <= 8'h11;
                    write_cnt    <= 0;
                    test_state   <= 1;
                end
            end

            // Back-to-back fast writes -- as soon as p0_ready pulses, strobe
            // the next write immediately (no idle gap between them).
            1: begin
                test_p0_req <= 1;
                test_state  <= 2;
            end
            2: begin
                if (p0_ready) begin
                    test_p0_req <= 0;
                    if (write_cnt == 2'd3) begin
                        test_state  <= 3;
                        test_p3_addr <= 25'h12345;
                        read_cnt    <= 0;
                    end else begin
                        write_cnt    <= write_cnt + 2'd1;
                        test_p0_addr <= test_p0_addr + 25'd1;
                        test_p0_din  <= (write_cnt == 2'd0) ? 8'h22 :
                                        (write_cnt == 2'd1) ? 8'h33 : 8'h44;
                        test_state   <= 1;
                    end
                end
            end

            // Sequential reads
            3: begin
                test_p3_req <= 1;
                test_state  <= 4;
            end
            4: begin
                if (sprite_sdram_ready) begin
                    test_p3_req <= 0;
                    test_read_data[read_cnt] <= sprite_sdram_dout;
                    if (read_cnt == 2'd3) begin
                        test_done  <= 1;
                        test_state <= 5;
                    end else begin
                        read_cnt     <= read_cnt + 2'd1;
                        test_p3_addr <= test_p3_addr + 25'd1;
                        test_state   <= 3;
                    end
                end
            end

            5: begin
                // Per-byte results, not just the aggregate -- two plausible timing
                // fixes (p0_busy race, write-recovery cooldown) didn't change the
                // aggregate pass/fail at all, so we need to see WHICH byte(s)
                // actually come back wrong, and how, before guessing a third fix.
                byte_ok[0] <= (test_read_data[0] == 8'h11);
                byte_ok[1] <= (test_read_data[1] == 8'h22);
                byte_ok[2] <= (test_read_data[2] == 8'h33);
                byte_ok[3] <= (test_read_data[3] == 8'h44);
                test_success <= (test_read_data[0] == 8'h11) &&
                                (test_read_data[1] == 8'h22) &&
                                (test_read_data[2] == 8'h33) &&
                                (test_read_data[3] == 8'h44);
                test_state <= 6;
            end

            6: begin
                // Idle / test finished
            end
        endcase
    end
end

// ==============================================================================
// POST-DOWNLOAD REAL-ADDRESS WRITE VERIFICATION (2026-08-11)
// ==============================================================================
// Distinguishes a WRITE-side failure (these specific bytes never correctly
// reached SDRAM during the real 256KB IOCTL download) from a READ-side
// failure (data's fine in SDRAM, something about fetching it later under
// real gameplay traffic goes wrong) -- Tests 151/154/155 in the debug log
// proved the arbiter/sdram.sv logic is correct via simulation (including
// using these EXACT real ROM bytes and addresses), but that only rules out
// a logic bug; it says nothing about whether the real download actually
// wrote these bytes correctly on real hardware in the first place.
// `reset` (= sys_reset | ioctl_download, see its own declaration) drops the
// instant the real download finishes, before any other Port 3 traffic --
// borrows Port 3 for a sweep of 16 reads at that moment, one confirmed-
// non-zero real byte sampled every 16KB across the FULL 256KB sprite ROM
// (found via direct inspection of battlnts_roms/777c05.13e), to see how
// WIDESPREAD any write-side corruption actually is -- a first 2-address
// version (0x3BC62 expect 0x56, 0x3F498 expect 0x90) came back RED on BOTH,
// immediately post-download before any other Port 3 traffic, ruling out
// "fine at write time, degrades under later read load" and pointing at the
// write side (or something address-pattern-dependent that also affects
// this clean isolated read-back, not just noisy real gameplay reads).
// LIGHTWEIGHT VERSION (2026-08-11): the original 16-entry address/expected-
// value lookup table version above caused an exceptionally long compile
// (>105 minutes vs the ~15 minute norm, killed without finishing) --
// replaced with a sequential full-sweep XOR checksum instead. Walks every
// single byte of the 256KB sprite ROM range through Port 3 (0x20000-
// 0x5FFFF, ~262144 reads, taking on the order of 100ms of real time once at
// boot -- imperceptible), XOR-accumulating each byte, and compares the
// final checksum against download_xor_checksum (accumulated the same way
// during the real write). Register/comparator cost: one 8-bit accumulator
// and one 18-bit sweep counter, vs. 528 bits of initialized lookup tables
// plus a 16-way case comparator before. Less localized than the 16-sample
// version (won't say WHICH byte is wrong), but answers the same yes/no
// "is the SDRAM write broadly correct" question much more cheaply, and
// covers the ENTIRE range instead of 16 samples.
reg [2:0] verify_state = 0;
reg verify_req = 0;
reg [24:0] verify_addr;
reg [17:0] verify_sweep_idx;
reg [7:0] verify_xor_checksum;
reg verify_done = 0;

always @(posedge clk_sys) begin
    if (reset) begin
        verify_state <= 0;
        verify_req   <= 0;
        verify_done  <= 0;
        verify_sweep_idx <= 0;
        verify_xor_checksum <= 8'h00;
    end else begin
        case (verify_state)
            0: begin
                if (test_done) begin
                    verify_sweep_idx <= 0;
                    verify_xor_checksum <= 8'h00;
                    verify_addr  <= 25'h20000;
                    verify_state <= 1;
                end
            end
            1: begin
                verify_req   <= 1;
                verify_state <= 2;
            end
            2: begin
                if (sprite_sdram_ready) begin
                    verify_req <= 0;
                    verify_xor_checksum <= verify_xor_checksum ^ sprite_sdram_dout;
                    if (verify_sweep_idx == 18'h3FFFF) begin
                        verify_done  <= 1;
                        verify_state <= 6;
                    end else begin
                        verify_sweep_idx <= verify_sweep_idx + 1'd1;
                        verify_addr      <= 25'h20000 + {7'd0, verify_sweep_idx} + 25'd1;
                        verify_state     <= 1;
                    end
                end
            end
            6: begin
                // Idle / verification finished
            end
        endcase
    end
end

wire p3_owner_test   = !test_done;
wire p3_owner_verify = test_done && !verify_done;

// Test 206 isolation test (2026-08-13, diagnostic-only, temporary): Port 2
// (k007342 shadow SDRAM verification, Test 204/205) showed a stable ~38%
// mismatch rate once real gameplay started exercising it -- but Port 2 had
// been completely idle all session until that deploy, so the arbiter's
// round-robin P2-vs-P3-simultaneous-request path (sdram_arbiter.sv lines
// 134-146) had never actually been exercised before. Setting this to 1
// forces p3_mux_req permanently low (after the boot-time self-test/checksum
// sweep finish their own Port 3 use), taking Port 3 completely out of the
// picture so Port 2 gets exclusive SDRAM access. If shadow_verify_fail_count
// drops to ~0 with Port 3 silent, the ~38% rate was an arbiter concurrency
// bug, not a fundamental SDRAM reliability limit. Expected side effect:
// sprites that need SDRAM (outside the BRAM cache) will fail to render for
// the duration of this test -- acceptable, this is diagnostic-only and must
// be reverted before any real gameplay build.
//
// Test 207 result: 0/160 frames showed any failure with Port 3 isolated --
// confirmed the ~38% mismatch rate (Test 206) was caused by simultaneous
// Port 2 + Port 3 SDRAM contention, not a fundamental SDRAM limit. Reverted
// to 1'b0 here (Test 208) to bring Port 3 back live, now testing whether
// sdram_arbiter.sv's new RECOVERY_CYCLES delay (added between the arbiter's
// cooldown state and its next dispatch) fixes the concurrent-access failures.
localparam ISOLATE_PORT2_FROM_PORT3 = 1'b0;

wire p3_mux_req  = (ISOLATE_PORT2_FROM_PORT3 && test_done && verify_done) ? 1'b0 :
                    p3_owner_test ? test_p3_req  : (p3_owner_verify ? verify_req  : sprite_sdram_req);
wire [24:0] p3_mux_addr = p3_owner_test ? test_p3_addr : (p3_owner_verify ? verify_addr : sprite_sdram_addr);

wire p0_ready;
sdram_arbiter arbiter (
    .clk(clk_sys),
    .reset(sdram_reset),

    // Port 0: IOCTL (Write Only) -- muxed with the local self-test above
    // until a real download starts (test always finishes first: it only
    // needs ~2 transactions after sdram_ready, IOCTL doesn't begin until
    // HPS mounts/streams the core, far later)
    .p0_req(ioctl_download ? ioctl_wr : test_p0_req),
    .p0_addr(ioctl_download ? ioctl_addr : test_p0_addr),
    .p0_din(ioctl_download ? ioctl_dout : test_p0_din),
    .p0_ready(p0_ready),
    .p0_busy(ioctl_wait),

    // Port 1: Main CPU (Read Only)
    .p1_req(cpu_sdram_req),
    .p1_addr(cpu_sdram_addr),
    .p1_dout(cpu_sdram_dout_raw),
    .p1_ready(cpu_sdram_ready),

    // Port 2: Tilemap (Unused - Available)
    .p2_req(p2_mux_req),
    .p2_addr(tile_sdram_addr),
    .p2_dout(tile_sdram_dout),
    .p2_ready(tile_sdram_ready),

    // Port 3: Sprites -- 3-way muxed: self-test first (test_done), then the
    // post-download real-address write verification above (verify_done),
    // then finally the real sprite engine.
    .p3_req(p3_mux_req),
    .p3_addr(p3_mux_addr),
    .p3_dout(sprite_sdram_dout),
    .p3_ready(sprite_sdram_ready),
    .p3_active(p3_active),

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
wire sdram_clk_shifted; // phase-shifted 48MHz for SDRAM_CLK, see pll_0002.v / sdram.sv

pll pll(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys), // Needs to be 48MHz
	.outclk_1(sdram_clk_shifted),
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
wire cpu_q = (cpu_clk_div == 2'b01 || cpu_clk_div == 2'b10); // High for phase 1,2
wire cpu_e = (cpu_clk_div == 2'b10 || cpu_clk_div == 2'b11); // High for phase 2,3

// Debug: Pause CPU (2026-08-15, status[30]) -- freezes game logic so the
// tile kill-switch bisection above can be done at leisure on a static
// frame instead of chasing moving sprites. Uses the MC6809 core's own
// nHALT pin (a real, cycle-accurate 6809 debug feature -- HALT preserves
// all internal CPU state, unlike gating its clock enables) and gates the
// Z80 sound CPU's clock enable directly (no exposed HALT pin on that
// wrapper, but stopping its ce pulse has the same freezing effect). Video
// timing (h_cnt/v_cnt) and the sprite/tile renderers keep running
// normally so the picture stays live and stable -- they just keep
// re-scanning the same frozen OAM/VRAM contents every frame, which is
// exactly what's wanted for a paused view.
// 2026-09-02: combined with a real Pause button (m_pause_edge, see its
// declaration near m_coin1/m_start1 below) via the same XOR-composition
// idiom this file already uses for effective_flip (flip_monitor ^
// flip_screen_req) -- the OSD toggle and the physical button both flip
// the same effective pause state independently, composing correctly.
reg pause_button_toggle;
always @(posedge clk_sys) if (m_pause_edge) pause_button_toggle <= ~pause_button_toggle;
wire pause_cpu = status[30] ^ pause_button_toggle;

wire k007342_irq; // Interrupt from K007342, driven on vblank when interrupts enabled
wire cpu_bs, cpu_ba; // Bus Status / Bus Available -- see k007342_irq_ack below

// 2026-08-27/28, Rack 'Em Up bring-up: the plain mc6809i core can't decode
// genuine HD6309 native-mode opcodes (OIM/AIM/EIM/TIM etc.) that Rack 'Em
// Up's ROM uses but Battlantis's own ROM never needed, even though both
// games' real boards use the same HD6309E.
//
// SIM_USE_JTKCPU swaps in Jotego's jtkcpu core (via the mc6809is adapter).
// Investigated at length and ultimately abandoned for this purpose: jtkcpu
// turns out to emulate Konami's own *proprietary* 052001/052526 CPU chips
// (its own README says so directly), which use a completely different,
// Konami-internal opcode encoding -- confirmed directly by tracing real ROM
// bytes through it (e.g. real byte $4F, which is CLRA on genuine 6809/6309
// hardware, dispatches as jtkcpu's own internal "CMPY_IDX" instead, since
// jtkcpu's case(op) table just doesn't use real Hitachi opcode values at
// all). Rack 'Em Up's real board uses a genuine, unmodified HD6309 -- not
// a Konami custom CPU -- so jtkcpu was never going to correctly execute
// its ROM regardless of any RTL bugs fixed along the way. Kept available
// under its own switch since a real 052001/052526-based title (several
// exist per jtkcpu's own game list, e.g. Haunted Castle, Ajax) could
// genuinely need it later.
//
// hd6309i (rtl/hd6309/, Roger Taylor's native-mode extension of Greg
// Miller's own mc6809 core -- the same upstream project this file's
// mc6809i already came from) decodes genuine Hitachi HD6309 opcodes and
// shares mc6809i's E/Q bus protocol closely enough to reuse the exact same
// cpu_e/cpu_q wiring below, no special adapter/wait-state module needed
// the way jtkcpu's cen2-driven bus required.
//
// 2026-08-28: promoted hd6309i from simulation-only (`ifdef SIM_USE_HD6309)
// to the real default here (both simulation and real Quartus synthesis).
// Verified extensively in Verilator first: Battlantis's own full run
// diffs byte-identical against mc6809i (module interfaces match exactly,
// confirmed via direct source comparison), and fixing a genuine hd6309i
// bug (NMILatched had no reset path, causing a phantom NMI to be serviced
// on the CPU's very first post-reset fetch -- see rtl/hd6309/hd6309i.v's
// own comment at its declaration) was what let Rack 'Em Up's real
// HD6309-native-mode ROM finally boot past its first ~4,800 instructions
// in simulation. mc6809i itself is untouched and kept available as an
// explicit rollback path (`define LEGACY_MC6809) if hd6309i turns up a
// real-synthesis-specific issue simulation didn't catch (timing closure,
// a Quartus-specific inference quirk, etc.) -- not expected, since both
// cores share the same non-native-mode logic, but not yet confirmed on
// real hardware either.
`ifdef SIM_USE_JTKCPU
reg [15:0] mrdy_addr_prev_hd6309;
always @(posedge clk_sys) mrdy_addr_prev_hd6309 <= cpu_addr;
wire mrdy_hd6309 = (cpu_addr == mrdy_addr_prev_hd6309);

mc6809is mc6809_inst (
    .D(cpu_din),
    .DOut(cpu_dout),
    .ADDR(cpu_addr),
    .RnW(cpu_rw),
    .E(),
    .Q(),
    .BS(cpu_bs),
    .BA(cpu_ba),
    .nIRQ(~k007342_irq),
    .nFIRQ(1'b1),
    .nNMI(1'b1),
    .CLK_SYS(clk_sys),
    .CEN_12M(clk_12m),
    .nHALT(~pause_cpu),
    .nRESET(~reset),
    .MRDY(mrdy_hd6309),
    .nDMABREQ(1'b1)
);
`elsif LEGACY_MC6809
// Explicit rollback path to the pre-2026-08-28 real-hardware default --
// see the comment above this ifdef chain. Not expected to be needed.
mc6809i mc6809_inst (
    .D(cpu_din),
    .DOut(cpu_dout),
    .ADDR(cpu_addr),
    .RnW(cpu_rw),
    .E(cpu_e),
    .Q(cpu_q),
    .BS(cpu_bs),
    .BA(cpu_ba),
    .nIRQ(~k007342_irq),
    .nFIRQ(1'b1),
    .nNMI(1'b1),
    .AVMA(),
    .BUSY(),
    .LIC(),
    .nRESET(~reset),
    .nDMABREQ(1'b1),
    .nHALT(~pause_cpu)
);
`else
hd6309i mc6809_inst (
    .D(cpu_din),
    .DOut(cpu_dout),
    .ADDR(cpu_addr),
    .RnW(cpu_rw),
    .E(cpu_e),
    .Q(cpu_q),
    .BS(cpu_bs),
    .BA(cpu_ba),
    .nIRQ(~k007342_irq),
    .nFIRQ(1'b1),
    .nNMI(1'b1),
    .AVMA(),
    .BUSY(),
    .LIC(),
    .nRESET(~reset),
    .nDMABREQ(1'b1),
    .nHALT(~pause_cpu)
);
`endif



// IRQ is generated and managed internally by k007342.
// k007342_irq is asserted on vblank when int_enabled=1, cleared on irq_ack.

// sys_reset combines the framework's hardware RESET input, the OSD's Reset
// option (status[0], from T[0]/R[0] in CONF_STR), and the joystick reset
// button (buttons[1]) — standard MiSTer template pattern (see Template.sv:120).
// This was previously undriven (an implicit net), so none of these ever
// actually reset the core - only ioctl_download (ROM loading) did.
//
// 2026-08-27: the OSD Test/Game mode option (status[15], named test_opt
// further down where dip_switch_3 is built) is a persistent selection, not
// a momentary button like status[0]/buttons[1] above, so it can't be ORed
// into sys_reset directly (that would hold the whole core in reset for as
// long as Test mode stayed selected). Instead, detect a change in its value
// and hold a synthetic reset pulse for ~1M clk_sys cycles, comparable in
// length to a human OSD button press, so picking a new mode gives the game
// a clean boot into it rather than switching the DIP mid-run.
reg test_opt_d;
reg [19:0] test_opt_reset_cnt;
always @(posedge clk_sys) begin
    test_opt_d <= status[15];
    if (status[15] != test_opt_d)
        test_opt_reset_cnt <= 20'hFFFFF;
    else if (test_opt_reset_cnt != 0)
        test_opt_reset_cnt <= test_opt_reset_cnt - 1'b1;
end
wire test_opt_reset = |test_opt_reset_cnt;

wire sys_reset = RESET | status[0] | buttons[1] | test_opt_reset;
wire reset = sys_reset | ioctl_download;

// 2026-08-20, task #8 round 77: TESTED AND REVERTED. `reset` above has no
// PLL-lock gating and no synchronizer at all -- same class of gap round
// 67 (this session, jtopl_isolation_test.sv) found and fixed on the
// isolation test's own reset network, which made previously-unstable
// envelope updates 100% reload-reliable there. Tried the same fix here,
// scoped to only battlantis_sound's own reset (not the pervasive global
// `reset` used by video/CPU/sprites, to avoid any risk of regressing
// gameplay): a separate, properly synchronized reset (async-assert on the
// raw condition or PLL unlock, synchronous 2-stage deassert). Verified on
// real hardware: no change -- ch0_car_eg_changed/ch0car_eg_in_I_changed/
// ch0car_joint_III all still RED, audio_gt256/gt4096 still RED. Reverted.
// Makes sense in hindsight: round 67's fix addressed RELOAD-to-reload
// instability (a different symptom, different boots giving different
// results on the isolation test), not a single-boot persistent freeze
// like Battlantis shows consistently across every boot this session.

// Fix (2026-08-15, Test 230, confirmed on real hardware): the SDRAM
// arbiter's reset was wired to bare sys_reset, and the MiSTer framework
// holds its RESET output asserted for the entire ioctl_download window (see
// sys/sysmem.sv:45's `~init_reset_n | ~hps_h2f_reset_n | reset_core_req`,
// where hps_h2f_reset_n stays low throughout download) -- not just initial
// core bring-up, as most MiSTer cores (including this one, until now)
// assume. This held the arbiter frozen for the whole download, so Port 0
// never processed a single write to SDRAM -- tile ROM (loaded last, after
// CPU/audio/sprite ROM) was never written at all, hence permanently black
// backgrounds, while BRAM-resident sprites/CPU ROM (gated only on
// ioctl_download && ioctl_wr, no reset dependency) were unaffected. Fix:
// exclude ioctl_download from the arbiter's effective reset -- a real
// hardware/OSD/joystick reset still works, but the download window itself
// can no longer hold it in reset.
wire sdram_reset = sys_reset & ~ioctl_download;

// CLK_VIDEO and CE_PIXEL are driven directly by arcade_video module below

reg [10:0] h_cnt = 0;
reg [9:0] v_cnt = 0;
wire h_sync, v_sync;

always @(posedge clk_sys) begin
    if (ce_pix) begin
        if (h_cnt == 383) begin // H-total = 384 (6MHz / 384 = 15.625 kHz)
            h_cnt <= 0;
            // TEMPORARY DIAGNOSTIC REVERT (2026-08-16, task #15 boot-hang
            // bisection) -- back to V-total=262 (was 264, the technically
            // correct value matching MAME exactly) to test whether the
            // V-total change is implicated in the boot hang. Restore to
            // 263 wraparound (264 total) once this is ruled in or out.
            v_cnt <= (v_cnt == 261) ? 10'd0 : v_cnt + 10'd1;
        end else begin
            h_cnt <= h_cnt + 11'd1;
        end
    end
end

// ==============================================================================
// K007342 TILEMAP GENERATOR (0x0000 - 0x1FFF)
// ==============================================================================

wire [7:0] k007342_dout;
wire [7:0] k007342_pixel;
wire k007342_priority;
wire k007342_we = cpu_rw == 1'b0 && (cpu_addr <= 16'h1FFF || (cpu_addr >= 16'h2600 && cpu_addr <= 16'h2607));
wire k007342_re = cpu_rw == 1'b1 && (cpu_addr <= 16'h1FFF || (cpu_addr >= 16'h2600 && cpu_addr <= 16'h2607));
wire k007342_scroll_we = cpu_rw == 1'b0 && (cpu_addr >= 16'h2200 && cpu_addr <= 16'h23FF);
wire [7:0] k007342_scroll_dout;

reg k007342_vram_bank; // Bankswitch for VRAM attributes


wire vblank;
wire k007342_int_enabled;
wire sprite_wrap_y;
wire flip_screen_req; // Task #17 revival: real K007342 reg 0x00 bit4, see k007342.v's port comment

// irq_ack: K007342 internal IRQ flag is cleared when CPU acknowledges the interrupt.
// The 6809 does this by reading the interrupt vector (0xFFF8-0xFFFF during IRQ service).
//
// 2026-08-27, task #15 root cause: the previous version of this signal --
// `cpu_e & cpu_rw & (cpu_addr >= 16'hFFF8)` -- checked only the address bus
// value, which mc6809i.v also parks at $FFFF (a genuinely valid, non-
// don't-care bus cycle, AVMA=1) as the DEFAULT value for any internal cycle
// that doesn't need a real memory address, including every single
// LEAX/LEAY/LEAS/LEAU execution (opcodes $30-$33; this ROM uses `LEAX -1,X`
// constantly in tight delay/counter loops). This meant every LEA
// instruction spuriously acked the K007342's IRQ flag within a handful of
// cycles of it being set, well before the CPU's own interrupt synchronizer
// (IRQSample->IRQSample2->IRQLatched, clocked on negedge E) had a
// reliable chance to see it -- a genuine, unpredictable race that
// depended on exactly which instruction happened to be executing at each
// vblank instant. Measured in Verilator (Round 152-156, project_history/
// TASKS.md) as a ~75%-vs-99% vblank-service-rate gap against a MAME
// reference, closely matching the independently-measured ~36-43%
// real-hardware slowdown.
//
// Fix: mc6809i.v already computes BS/BA (Bus Status/Bus Available)
// correctly per the real 6809's own documented semantics -- BS=1 with
// BA=0 is specifically the "Interrupt or Reset Acknowledge" cycle
// signature (set only in the real ACK Interrupt/ACK RESET branches, left
// at its default 0 everywhere else, including the LEA opcode's own
// $FFFF-default cycle). Qualifying on this instead of the bare address
// range eliminates the LEA false-trigger entirely, and as a side effect
// also stops matching the SWI/NMI/RESET vector fetches the old $FFF8+
// range covered but was never intended to (a real interrupt-acknowledge
// cycle only asserts BS/~BA for the vector this CPU is genuinely
// servicing).
wire k007342_irq_ack = cpu_bs & ~cpu_ba;

k007342 k007342_inst (
    .clk(clk_sys),
    .reset(reset),
    .layer1_enable(layer1_enable),

    .vblank(vblank),
    .int_enabled(k007342_int_enabled),
    .sprite_wrap_y(sprite_wrap_y),
    .flip_screen_req(flip_screen_req),
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
    .pixel_color(k007342_pixel),
    .pixel_priority(k007342_priority),

    .shadow_sdram_req(tile_sdram_req),
    .shadow_sdram_addr(tile_sdram_addr),
    .shadow_sdram_dout(tile_sdram_dout),
    .shadow_sdram_ready(tile_sdram_ready),
    .shadow_verify_addr_out(shadow_verify_addr),
    .shadow_verify_expected_out(shadow_verify_expected),
    .shadow_verify_actual_out(shadow_verify_actual),
    .shadow_verify_match_out(shadow_verify_match),
    .shadow_verify_pass_count_out(shadow_verify_pass_count),
    .shadow_verify_fail_count_out(shadow_verify_fail_count),
    .shadow_max_wait_cycles_out(shadow_max_wait_cycles),
    .shadow_currently_stuck_out(shadow_currently_stuck),
    .cache_sim_hit_count_out(cache_sim_hit_count),
    .cache_sim_miss_count_out(cache_sim_miss_count),
    .port3_busy(p3_active)
);

// ==============================================================================
// K007420 SPRITE GENERATOR (0x2000 - 0x21FF)
// ==============================================================================

wire [7:0] k007420_dout;
wire [7:0] k007420_pixel;
wire k007420_active;

wire k007420_we = cpu_rw == 1'b0 && (cpu_addr >= 16'h2000 && cpu_addr <= 16'h21FF);



wire [15:0] sprite_diag_req_count;
wire [15:0] sprite_diag_ready_count;
wire [17:0] sprite_max_sdram_addr;
wire sprite_frame_has_nonzero;
wire [6:0] sprite_max_addr_idx;
wire [7:0] sprite_max_addr_code_lsb;
wire [7:0] sprite_max_addr_attr;
wire [7:0] sprite_max_addr_flags;
wire [7:0] sprite_bram_debug;
wire [17:0] sprite_last_fetch_addr;
wire sprite_last_fetch_nonzero;
wire [6:0] sprite_last_fetch_idx;
wire [7:0] sprite_last_fetch_code_lsb;
wire [7:0] sprite_last_fetch_attr;
wire [7:0] sprite_last_fetch_flags;
wire [17:0] sprite_last_bram_addr;
wire [6:0] sprite_last_bram_idx;
wire [7:0] sprite_last_bram_code_lsb;
wire [7:0] sprite_last_bram_attr;
wire [7:0] sprite_last_bram_flags;
wire        sprite_zoom_wrap_hit;
wire [6:0]  sprite_zoom_wrap_sprite_idx;
wire [9:0]  sprite_zoom_wrap_zoom_raw;
wire [9:0]  sprite_zoom_wrap_spr_y;
wire [7:0]  sprite_zoom_wrap_draw_x;
wire [8:0]  sprite_zoom_wrap_v_cnt;
wire [12:0] sprite_zoom_wrap_tile_idx;
wire sprite_last_bram_was_sdram;
wire [15:0] sprite_max_bram_addr_used;
wire [17:0] sprite_small_sdram_addr;
wire [6:0] sprite_small_sdram_idx;
wire [7:0] sprite_small_sdram_code_lsb;
wire [7:0] sprite_small_sdram_attr;
wire [7:0] sprite_small_sdram_flags;
wire sprite_small_sdram_nonzero;

// TEMP (2026-08-30): named wire instead of an inline AND expression, to
// test a possible Verilator CSE/scheduling quirk -- k007342_inst (same
// clk_sys, same `.ioctl_wr(ioctl_download & ioctl_wr)` inline expression,
// ~100 lines earlier) correctly sees every download write, but k007420's
// own scope never sees this condition become true, confirmed multiple
// independent ways (see TASKS.md's 2026-08-30 memory-budget entries).
wire sprite_gen_ioctl_wr = ioctl_download & ioctl_wr;

k007420 sprite_gen (
    .clk(clk_sys),
    .reset(reset),
    
    .spritebank(sprite_bank), // Pass sprite_bank to k007420
    .wrap_y(sprite_wrap_y),

    .cpu_addr(cpu_addr[8:0]),
    .cpu_din(cpu_dout),
    .cpu_dout(k007420_dout),
    .cpu_we(k007420_we),
    
    .ce_pix(ce_pix),
    .h_cnt(h_cnt[8:0]),
    .v_cnt(v_cnt[8:0]),
    
    .ioctl_wr(sprite_gen_ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),

    .sprite_color(k007420_pixel),
    .sprite_active(k007420_active),
    
    .sprite_sdram_req(sprite_sdram_req),
    .sprite_sdram_addr(sprite_sdram_addr),
    .sprite_sdram_dout(sprite_sdram_dout),
    .sprite_sdram_ready(sprite_sdram_ready),
    .sprite_traffic_active(test_done && verify_done),

    .diag_sdram_req_count(sprite_diag_req_count),
    .diag_sdram_ready_count(sprite_diag_ready_count),
    .max_sdram_addr_out(sprite_max_sdram_addr),
    .frame_has_nonzero_out(sprite_frame_has_nonzero),
    .max_addr_sprite_idx_out(sprite_max_addr_idx),
    .max_addr_code_lsb_out(sprite_max_addr_code_lsb),
    .max_addr_attr_out(sprite_max_addr_attr),
    .max_addr_flags_out(sprite_max_addr_flags),
    .bram_debug_out(sprite_bram_debug),
    .last_fetch_addr_out(sprite_last_fetch_addr),
    .last_fetch_nonzero_out(sprite_last_fetch_nonzero),
    .last_fetch_sprite_idx_out(sprite_last_fetch_idx),
    .last_fetch_code_lsb_out(sprite_last_fetch_code_lsb),
    .last_fetch_attr_out(sprite_last_fetch_attr),
    .last_fetch_flags_out(sprite_last_fetch_flags),
    .last_bram_addr_out(sprite_last_bram_addr),
    .last_bram_sprite_idx_out(sprite_last_bram_idx),
    .last_bram_code_lsb_out(sprite_last_bram_code_lsb),
    .last_bram_attr_out(sprite_last_bram_attr),
    .last_bram_flags_out(sprite_last_bram_flags),
    .zoom_wrap_hit_out(sprite_zoom_wrap_hit),
    .zoom_wrap_sprite_idx_out(sprite_zoom_wrap_sprite_idx),
    .zoom_wrap_zoom_raw_out(sprite_zoom_wrap_zoom_raw),
    .zoom_wrap_spr_y_out(sprite_zoom_wrap_spr_y),
    .zoom_wrap_draw_x_out(sprite_zoom_wrap_draw_x),
    .zoom_wrap_v_cnt_out(sprite_zoom_wrap_v_cnt),
    .zoom_wrap_tile_idx_out(sprite_zoom_wrap_tile_idx),
    .last_bram_was_sdram_out(sprite_last_bram_was_sdram),
    .max_bram_addr_used_out(sprite_max_bram_addr_used),
    .small_sdram_addr_out(sprite_small_sdram_addr),
    .small_sdram_idx_out(sprite_small_sdram_idx),
    .small_sdram_code_lsb_out(sprite_small_sdram_code_lsb),
    .small_sdram_attr_out(sprite_small_sdram_attr),
    .small_sdram_flags_out(sprite_small_sdram_flags),
    .small_sdram_nonzero_out(sprite_small_sdram_nonzero)
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
// Round 192 (2026-09-03) fix: was `bg_pixel[7]`, reading priority back out
// of the same byte used for the palette lookup. Now that k007342 carries
// priority on its own dedicated `pixel_priority` output (bit 7 of
// bg_pixel/pixel_color is hardcoded 0), read it from there directly.
wire bg_priority    = k007342_priority;
// Round 192 (2026-09-03) re-check of Round 191's sprite kill-switch test:
// this round's own top-level pixel_color tap caught pixel_color diverging
// from k007342's own computed background value at the GAME OVER box's
// affected screen position, which can only happen via sprite_pixel -- so
// a sprite may genuinely be present there despite Round 191's kill-switch
// test showing no change in the final rendered color. Re-testing with the
// same kill-switch pattern, now instrumented with the new pixel_color tap,
// to see directly whether sprite_visible is true at that exact position
// and, if forced off, whether pixel_color pins to k007342's own value.
// Simulation-only, gated on the VERILATOR builtin ifdef predefine below;
// zero effect on any real hardware/Quartus build.
`ifdef VERILATOR
reg dbg_force_sprite_off /* verilator public_flat_rw */;
`else
wire dbg_force_sprite_off = 1'b0;
`endif
wire sprite_visible = !dbg_force_sprite_off && k007420_active && sprite_pixel[3:0] != 4'd0;

// Per-tile priority: k007342_mame.cpp:278 sets tileinfo.category = (color & 0x80) >> 7,
// and battlnts_mame.cpp's screen_update() draws category-1 tiles in a SECOND
// pass with TILEMAP_DRAW_OPAQUE (battlnts_mame.cpp line 118) -- OPAQUE means
// every pixel of that tile is blitted unconditionally, including pen index 0,
// completely overwriting whatever the sprite pass left there. A priority tile
// is a solid, fully-opaque rectangular cut over sprites, not transparency-
// aware. Round 193 (2026-09-03) briefly changed this to let sprites show
// through a priority tile's own transparent (pix==0) pixels, ported from
// Gemini's fix in the sibling RackEmUp_template repo (commit 8d17fe4) -- but
// the project's own real-hardware Stage 11 capture (project_history/TASKS.md,
// same day) directly contradicts that: the clean reference frame shows the
// Red Dragon "cleanly, simply occluded wherever the opaque box sits -- a
// plain rectangular cut", not partially showing through. Reverted back to
// the original unconditional block; the real fix for the dragon/GAME OVER
// corruption is k007342.v's disp0_attr/disp1_attr priority-timing latch
// (still in place), which was mistakenly bundled with this incorrect change.
wire show_sprite = sprite_visible && !bg_priority;

// pixel_color: which palette index to look up.
wire [7:0] pixel_color = show_sprite ? sprite_pixel : bg_pixel;

// Palette RAM lookup: each entry is 2 bytes (xBGR_555 Big-Endian format)
// 16-bit word = {even_byte, odd_byte} = {xBBBBBGG, GGGRRRRR}
// Even byte (addr[0]=0): { x, B[4:0], G[4:3] } = bits [15:8] of 16-bit word
// Odd byte  (addr[0]=1): { G[2:0], R[4:0] }   = bits [7:0] of 16-bit word
reg [7:0] pal_byte_even, pal_byte_odd;

// 2026-09-02, task #77: explicit 10-bit combinational address wire
// instead of an inline concatenation as the array index -- the
// concatenation form still triggered Quartus's "index expression is not
// wide enough" warning (10027) despite being exactly 10 bits wide
// (1 + 8 + 1), since Quartus's linter evaluates a literal-bit-mixed
// concatenation's width less precisely than a plain sized wire. Kept as
// a wire (not a register) so the read below still happens on the same
// clock edge as the original inline form -- same value, same timing,
// same real K007342 palette layout (256 colors x 2 bytes = 512 of the
// 1024 declared entries reachable from the display path, matching real
// silicon).
wire [9:0] pal_addr_even = {1'b0, pixel_color, 1'b0};
wire [9:0] pal_addr_odd  = {1'b0, pixel_color, 1'b1};

always @(posedge clk_sys) begin
    if (ce_pix) begin
        pal_byte_even     <= palette_ram[pal_addr_even];
        pal_byte_odd      <= palette_ram[pal_addr_odd];
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
  reg [7:0] sound_latch;
  reg sound_irq;

  // 2026-08-23, task #8 round 133: round 133's own live sound_latch readout
  // only samples once per screenshot (~1Hz) -- too coarse to rule out a
  // brief command 0x80 (the confirmed sole trigger for the ROM's fade-arm
  // routine, see battlantis_sound.v's jtopl2 instantiation comments) being
  // sent and immediately overwritten between two samples. This sticky
  // latch sidesteps the sampling-rate question entirely: once command 0x80
  // is ever written to the mailbox, it stays GREEN for the rest of the
  // session regardless of how fast sound_latch changes afterward, so a
  // single screenshot at the title-to-announcement transition (~t=58-60s
  // per round 133's capture) can settle whether 0x80 genuinely never fires
  // there, without needing to out-race the real command rate.
  // 2026-08-23, task #8 round 133: the plain "ever since boot" sticky
  // latch above proved too coarse -- 0x80 fires very early (title-screen
  // boot init) and stays latched GREEN long before the title-to-
  // announcement transition we actually care about, so it can't answer
  // "was 0x80 sent again right before THIS SPECIFIC instrument-load
  // command." Screenshot-based sampling is hard-capped at ~1Hz regardless
  // of how fast screenshots are requested (confirmed directly -- a 0.5s
  // poll loop still only produced whole-second-spaced captures), so
  // catching a possibly sub-second command can't rely on sampling speed
  // either. Instead: track whether 0x80 was sent since the PREVIOUS
  // instrument-load command (bit7 set, 0x81-0x9a, matching the ROM
  // dispatcher's own `AND 0x7f` branch), and freeze that answer into a
  // separate register at the exact moment the NEXT instrument-load
  // command arrives -- readable at leisure afterward, no timing race.
  reg cmd80_since_last_bigload;
  reg cmd80_seen_before_last_bigload;

  always @(posedge clk_sys) begin
      sound_irq <= 1'b0;
      if (reset) begin
          rom_bank <= 2'b00;
          sprite_bank <= 1'b0;
          k007342_vram_bank <= 1'b0;
          sound_latch <= 8'd0;
          cmd80_since_last_bigload <= 1'b0;
          cmd80_seen_before_last_bigload <= 1'b0;
      end else if (cpu_we) begin
          if (cpu_addr == 16'h2e08) begin
              k007342_vram_bank <= 1'b0; // Battlantis has single flat 8KB VRAM (no VRAM banking)
              rom_bank <= cpu_dout[7:6]; // ROM bank index is in bits 7 and 6
          end
          if (cpu_addr >= 16'h2400 && cpu_addr <= 16'h27FF) palette_ram[cpu_addr[9:0]] <= cpu_dout;
          if (cpu_addr == 16'h2e0c) sprite_bank <= cpu_dout[0];
          if (cpu_addr == 16'h2e14) begin
              sound_latch <= cpu_dout;
              if (cpu_dout == 8'h80) begin
                  cmd80_since_last_bigload <= 1'b1;
              end else if (cpu_dout[7] && cpu_dout < 8'h9b) begin
                  cmd80_seen_before_last_bigload <= cmd80_since_last_bigload;
                  cmd80_since_last_bigload <= 1'b0;
              end
          end
          if (cpu_addr == 16'h2e18) begin
              sound_irq <= 1'b1;
          end
      end
  end

  // 2026-08-23, task #8 round 133: REAL FIX -- hardware-confirmed (via
  // cmd80_seen_before_last_bigload, frozen at the exact moment each
  // instrument-load command's own IRQ trigger fires, independent of any
  // screenshot sampling rate) that the main 6809 CPU's own game logic
  // does not send command 0x80 (the sound ROM's sole trigger for its
  // fade-arm routine at ROM 0x00F3, see battlantis_sound.v's jtopl2
  // instantiation comments) before the specific instrument-load command
  // that starts the title-to-stage-announcement transition, even though
  // every other observed transition correctly does. Rather than patch
  // the main CPU's own ROM (a separate, unanalyzed program, and ROM code
  // insertion is much riskier than the pure data-byte patches used
  // elsewhere in this investigation -- inserting instructions shifts
  // every subsequent address), this intercepts the mailbox hand-off
  // entirely in RTL: whenever a new instrument-load command's own IRQ
  // trigger fires without a preceding 0x80, transparently sequence a
  // synthetic 0x80 dispatch to the sound Z80 first (using the exact
  // same real mailbox/interrupt mechanism the main CPU itself uses, so
  // the sound ROM's own already-verified-correct fade-arm routine runs
  // exactly as it would for a genuine command), then release the real
  // command once the Z80 has actually consumed the injected one --
  // confirmed via `z80_irq_ack`'s own rising edge, not a fixed delay, so
  // this works regardless of how long the Z80 takes to service it. This
  // is general and self-healing: it fixes this confirmed gap without
  // needing to hardcode which specific transition is broken, and would
  // equally protect against any other similar gap elsewhere in the game
  // (every OTHER observed transition already sends 0x80 on its own, so
  // this stays a no-op there).
  //
  // Known limitation, accepted as a low-probability edge case rather
  // than adding a full command queue: if a second real command arrives
  // while an injected 0x80 is still awaiting acknowledgement, it will be
  // missed. Real commands are observed to be spaced apart by at least
  // hundreds of milliseconds (round 133's own capture), while the
  // injected dispatch completes within a handful of Z80 cycles, so this
  // window is vanishingly narrow in practice.
  reg z80_irq_ack_prev_inj;
  always @(posedge clk_sys) z80_irq_ack_prev_inj <= z80_irq_ack;
  wire z80_irq_ack_edge_inj = z80_irq_ack && !z80_irq_ack_prev_inj;

  localparam INJ_IDLE = 1'b0, INJ_WAIT_ACK = 1'b1;
  reg       inj_state;
  reg [7:0] inj_pending_cmd;
  reg [7:0] sound_latch_to_z80;
  reg       sound_irq_to_z80;
  // 2026-08-23, task #8 round 133: `inj_ever_fired` alone has the exact
  // same flaw round 133's own first `cmd80_ever_sent` attempt had -- it
  // engaged once very early (a different, unrelated boot-time gap) and
  // stays GREEN forever after, so it can't confirm the injector fired
  // specifically for the title-to-announcement transition. This mirrors
  // `cmd80_seen_before_last_bigload`'s own freeze-per-transition
  // technique: records whether the injector was used for the MOST
  // RECENT instrument-load command specifically, stable until overwritten
  // by the next one -- readable at leisure, no race against timing.

  always @(posedge clk_sys or posedge reset) begin
      if (reset) begin
          inj_state <= INJ_IDLE;
          sound_latch_to_z80 <= 8'd0;
          sound_irq_to_z80 <= 1'b0;
          inj_pending_cmd <= 8'd0;
      end else begin
          sound_irq_to_z80 <= 1'b0; // single-cycle pulse by default
          case (inj_state)
              INJ_IDLE: begin
                  if (sound_irq) begin
                      if (sound_latch[7] && sound_latch < 8'h9b && !cmd80_seen_before_last_bigload) begin
                          // instrument-load command with no preceding stop --
                          // hold it back and dispatch a synthetic 0x80 first.
                          inj_pending_cmd <= sound_latch;
                          sound_latch_to_z80 <= 8'h80;
                          sound_irq_to_z80 <= 1'b1;
                          inj_state <= INJ_WAIT_ACK;
                      end else begin
                          sound_latch_to_z80 <= sound_latch;
                          sound_irq_to_z80 <= 1'b1;
                      end
                  end
              end
              INJ_WAIT_ACK: begin
                  if (z80_irq_ack_edge_inj) begin
                      sound_latch_to_z80 <= inj_pending_cmd;
                      sound_irq_to_z80 <= 1'b1;
                      inj_state <= INJ_IDLE;
                  end
              end
          endcase
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
// Reset-time fallback fixed 2026-08-20 (task #9): re-derived MAME's real
// DSW2 defaults bit-by-bit from extra/battlnts_mame.cpp directly -- 0x5A,
// not the previous 8'hA6, which was wrong on 4 of 5 fields (Cabinet,
// Bonus Life, Difficulty, Demo Sounds; only Lives happened to be correct).
// This fallback fires on every fresh-SD-card boot, before the OSD has ever
// written a real status word.
wire [7:0] dip_switch_2 = (status[16:0] == 17'd0) ? 8'h5A : { demo_opt, diff_opt, bonus_opt, cab_opt, lives_opt };

// DSW3: bit 0: Coin1, bit 1: Coin2, bit 2: Test/Service (momentary button,
// separate from the bit 7 Service Mode DIP below -- KONAMI8_SYSTEM_10's
// standard layout per battlnts_mame.cpp's own "coinsw, testsw, startsw"
// comment on the DSW3 port-read), bit 3: Start1, bit 4: Start2.
// Bit 2 was previously hardcoded inactive (tied high via 2'b11 alongside
// coin2), meaning there was no way to advance past service mode's initial
// screen (e.g. a monitor alignment/geometry pattern) once the Mode DIP
// below put the board into test mode on reset -- confirmed via user report
// of the board reaching that screen and going no further. joystick_0[6]
// was originally repurposed for this (Start then lived on bit 7), but see
// the 2026-08-29 comment right below -- Start and Test have since traded
// bit positions, so this physical Test/Service button now reads bit 7.
// 2026-08-29: swapped which physical bit is Start vs Test. CONF_STR's J1
// line now names exactly 3 buttons (Fire, Coin, Start occupying bits
// 4/5/6 in order, no gaps) after an attempted "skip a name with an empty
// slot" CONF_STR syntax left Start unreachable -- rather than trust that
// unverified syntax again, Start and Test simply trade bit positions so
// the named list maps cleanly with zero gaps. Test (a momentary Test/
// Service button, redundant with the OSD's own "Mode: Game/Test" option)
// moves to the now-unnamed bit 7, unreachable via "Define joystick" but
// still settable via MiSTer's more advanced/manual key binding if ever
// needed.
wire p1_btn1  = ~joystick_0[4]; // Fire (Battlantis) / Shoot (Rack 'Em Up)
wire p1_btn2  = ~joystick_0[5]; // Aim / English (Rack 'Em Up)
wire p2_btn1  = ~joystick_1[4];
wire p2_btn2  = ~joystick_1[5];

wire m_coin1  = joystick_0[6] | joystick_1[6]; // Select/Coin (bit 6)
wire m_start1 = joystick_0[7];                 // Start 1 (bit 7)
wire m_start2 = joystick_1[7];                 // Start 2 (bit 7)
wire m_pause  = joystick_0[8] | joystick_1[8]; // Pause (bit 8)
wire m_test   = joystick_0[9];                 // Test/Service (bit 9)
reg  m_pause_prev;
always @(posedge clk_sys) m_pause_prev <= m_pause;
wire m_pause_edge = m_pause && !m_pause_prev;
// Flip Screen OSD option removed (2026-08-27): its underlying K007342
// reg 0x00 bit4 dynamic flip behavior was never implemented (Task #17,
// deprioritized) and user hardware testing confirmed toggling it had no
// visible effect -- redundant with the working "Flip Monitor" option
// anyway. Kept as a hardcoded 0 so dip_switch_3's real bit layout
// (matching the factory DIP switch) stays unchanged.
wire flip_opt = 1'b0; // 0=Off/Normal (factory default, DIP not exposed in OSD)
wire ctrl_opt = status[14]; // 0=Single (0x40), 1=Dual (0x00)
wire test_opt = status[15]; // 0=Game (0x00), 1=Test (0x80)
wire cont_opt = status[16]; // 0=5 Times (0x00, factory default per manual/MAME), 1=3 Times (0x80)
wire [7:0] dip_switch_3 = (status[16:0] == 17'd0) ? {1'b1, 2'b11, ~m_start2, ~m_start1, 1'b1, ~m_test, ~m_coin1} : {~test_opt, ~ctrl_opt, ~flip_opt, ~m_start2, ~m_start1, 1'b1, ~m_test, ~m_coin1};

// Bit 7 (MAME PORT_DIPNAME 0x80 on the P1 port, not DSW3) is the
// Allow_Continue DIP -- was previously hardcoded to 1'b1 (always "3
// Times"), leaving the "Continues" OSD option wired to nothing.
// Bit 5 is Button 2 (Aim / English in Rack 'Em Up, unused in Battlantis).
wire [7:0] player_1_inputs = {cont_opt, 1'b1, p1_btn2, p1_btn1, ~joystick_0[3], ~joystick_0[2], ~joystick_0[0], ~joystick_0[1]};
// 2026-08-29, player feedback: was hardcoded to 8'hFF ("Unused for now"),
// meaning Player 2 had no functional input at all even with "Upright
// Controls: Dual" selected and a second controller plugged into
// joystick_1 -- that OSD option only ever flipped a DIP bit the game
// reads, it never actually enabled real P2 input. Confirmed via
// extra/battlnts_mame.cpp: P2's own input port uses the same
// KONAMI8_B1-style joystick+button macro as P1 (just the "_UNK" variant,
// meaning its bit 7 has no special DIP-override meaning the way P1's
// Allow_Continue bit does -- just a plain unused/inactive bit), so this
// mirrors player_1_inputs' proven-correct bit layout exactly, substituting
// joystick_1 for joystick_0 and a hardcoded inactive 1 for the unused bit 7.
wire [7:0] player_2_inputs = {1'b1,     1'b1, p2_btn2, p2_btn1, ~joystick_1[3], ~joystick_1[2], ~joystick_1[0], ~joystick_1[1]};

// 4KB Work RAM (0x3000 - 0x3FFF)
(* ramstyle = "M10K" *) reg [7:0] work_ram [0:4095];
reg [7:0] work_ram_dout;
always @(posedge clk_sys) begin
    if (cpu_we && (cpu_addr >= 16'h3000 && cpu_addr <= 16'h3FFF)) begin
        work_ram[cpu_addr[11:0]] <= cpu_dout;
    end
    work_ram_dout <= work_ram[cpu_addr[11:0]];
end

// HD6309 native-mode (SETMD) detector TEMPORARILY DISABLED (2026-08-16)
// for boot-hang bisection (task #15) -- see git history / debugging_log.md
// entry 22 for the full original reasoning, and task #15 for restoring it
// once the hang is isolated. setmd_seen kept as a constant so
// diag_box_setmd_seen's reference below doesn't need touching.

// K007342 IRQ delivery sticky check (2026-08-16, boot-hang investigation)
// -- reuses the same box slot/format as the (temporarily disabled) SETMD
// detector above. Tests whether k007342_irq (wired to the CPU's nIRQ pin)
// EVER pulses high since reset, given the CPU appears to be halted with
// K007342's int_enabled=1 but irq observed low on every live sample so
// far (Gemini-assisted read: consistent with the CPU legitimately parked
// in a SYNC/CWAI wait-for-interrupt state that's never being woken).
always @(posedge clk_sys) begin
end

// Task #15 (2026-08-25): direct hardware-level test of the "coalesced
// vblank" hypothesis -- since k007342_irq is a single bit (not a counter),
// if the CPU's per-frame workload ever takes longer than one real frame
// period, a subsequent real vblank can arrive while the previous IRQ is
// still pending (unacknowledged), silently losing that tick from the
// CPU's perspective. This tests the mechanism directly rather than
// continuing CPU-cycle-timing audits: does a NEW vblank rising edge ever
// occur while irq was ALREADY high on the immediately preceding cycle
// (i.e. not yet acked since the last one)? GREEN = confirmed at least
// once (matches the existing "ever" convention, e.g.
// reset_pulse_too_short_ever above); RED = never observed in the capture
// window, which would refute this specific mechanism.
//
// 2026-09-02, task #77 warning cleanup: `vblank_coalesced_ever` is never
// read by anything in the real, synthesizable design -- Quartus correctly
// flags it as dead code from ITS perspective. But it's still a genuinely
// live, actively-used signal from the *simulation* side: sim_main.cpp's
// own Task #15 vblank-service-rate diagnostic (the "[TASK15]
// missed_vblank_count" tracking this whole session's Verilator work has
// relied on) reads it through tb_top.sv's `dbg_vblank_coalesced_ever`/
// `dbg_vblank_rising` debug taps, which don't exist in a real hardware
// build at all. Deleting this block outright (tried first, then reverted
// after the very next Verilator rebuild failed with "Can't find
// definition of 'vblank_coalesced_ever'") would have silently broken that
// diagnostic. Guarding it behind `SIM_SPRITE_SDRAM_PROBE` -- already
// defined for every Verilator build via filelist.f, never defined for
// real hardware -- keeps the diagnostic fully working in simulation while
// genuinely fixing the warning on real hardware, where this code no
// longer exists as it did before at all.
`ifdef SIM_SPRITE_SDRAM_PROBE
reg vblank_prev = 1'b0;
reg k007342_irq_prev = 1'b0;
always @(posedge clk_sys) begin
    vblank_prev <= vblank;
    k007342_irq_prev <= k007342_irq;
end
wire vblank_rising = vblank && !vblank_prev;

reg vblank_coalesced_ever;
always @(posedge clk_sys) begin
    if (reset) vblank_coalesced_ever <= 1'b0;
    else if (vblank_rising && k007342_irq_prev) vblank_coalesced_ever <= 1'b1;
end
`endif

// Z80 Clock Enable Generator (2026-08-16 fix: was 48MHz/13 = ~3.69MHz,
// labeled "3.58MHz" chasing the NTSC-colorburst red herring MAME's own
// driver comment flags as uncertain ("3579545? no such XTAL on board").
// Real hardware per MAME: HD6309E audio CPU config uses 24_MHz_XTAL/6 =
// exactly 4.0MHz. 48MHz/12 = 4.0MHz exactly.
// (2026-08-16: the sound-clock revert tested here as a boot-hang isolation
// step came back negative -- hang persisted identically with the old
// 48MHz/13 divider too -- so this fix is confirmed NOT implicated and is
// restored to its correct value. See task #15 for the ongoing hang search.)
reg [3:0] z80_clk_cnt;
always @(posedge clk_sys) begin
    z80_clk_cnt <= (z80_clk_cnt == 4'd11) ? 4'd0 : z80_clk_cnt + 1'b1;
end
wire ce_z80 = (z80_clk_cnt == 4'd0) && !pause_cpu;

// YM3812 (OPL2) Clock Enable Generator -- per MAME each YM3812 has its OWN
// independent clock, 24_MHz_XTAL/8 = 3.0MHz, separate from the Z80's
// 4.0MHz. 48MHz/16 = 3.0MHz exactly.
reg [3:0] ym3812_clk_cnt;
always @(posedge clk_sys) begin
    ym3812_clk_cnt <= (ym3812_clk_cnt == 4'd15) ? 4'd0 : ym3812_clk_cnt + 1'b1;
end
wire ce_ym3812 = (ym3812_clk_cnt == 4'd0) && !pause_cpu;

wire ioctl_sound_we = ioctl_download && ioctl_wr && (ioctl_addr >= 25'h18000 && ioctl_addr < 25'h20000);
wire [14:0] ioctl_sound_addr = ioctl_addr[14:0];
wire signed [15:0] audio_l, audio_r;
wire z80_fetching, z80_irq_ack, ym_written, z80_halted, z80_pc_hit_ei, z80_pc_hit_csumfail;
wire z80_pc_hit_0038;
wire z80_pc_past_delay, z80_pc_past_ramtest, z80_pc_past_checksum;
wire z80_fetch_count_reached_8;
wire z80_ch0_op2_tl_ever_loud;
wire z80_ch0_tl_loud_at_keyon;
wire z80_pc_hit_0000, z80_pc_hit_0000_wrong_data;
wire z80_ch0_ar_zero_at_keyon;
wire z80_pc_hit_000e_wrong_data;
wire z80_ch0_eg_type_at_keyon;
wire z80_ch0_ksl_nonzero_at_keyon;
wire z80_ch0_ksr_at_keyon;
wire z80_ch0_dr_zero_at_keyon;
wire z80_ch0_sl_rr_zero_at_keyon;
wire z80_ym1_snd_mag_gt256_ever;
wire z80_ym1_ch0_keyon_held_100ms;
wire z80_ym1_ch0_ar_fast_at_keyon;
wire z80_ch0_test_reg_nonzero_at_keyon;
wire z80_ch0_con_additive_at_keyon;
wire z80_hl_reached_8800, z80_a_hit_88_at_jrnz, z80_z_wrong_when_a_88;
wire z80_executed_ex_af;
wire z80_key_on_triggered;
wire z80_ch0_fnum_nonzero;
wire z80_ch0_op2_tl_not_max;
wire z80_ym1_snd_ever_nonzero;
wire z80_audio_mag_gt256_ever;
wire z80_audio_mag_gt4096_ever;
wire z80_ch0_freq_infrasonic_at_keyon;
wire z80_ch0_fb_nonzero_at_keyon;
wire z80_ch0_car_eg_lt256_ever;
wire z80_ch0_car_eg_lt64_ever;
wire z80_ch0_car_eg_ever_changed;
wire z80_eg_cnt_ever_changed;
wire z80_ch0car_keyon_now_ever;
wire z80_ch0car_sum_up_ever;
wire z80_ch0car_eg_in_I_ever_changed;
wire z80_ch0car_step_ever;
wire z80_ch0car_state_attack_ever;
wire z80_ch0car_attack_step_sumup_ever;
wire z80_ch0car_joint_hit_reg_ever;
wire z80_ch0car_joint_hit_III_ever;
wire z80_ch0car_arate_was_15_ever;
wire z80_ch0car_rate_was_63_ever;
wire [8:0] z80_ym1_ch_key_on_state;
wire [8:0] z80_ym1_ch_audible_live;
wire [8:0] z80_ym1_ch_stuck_confirmed;
wire [71:0] z80_ym1_ch_stuck_sl_rr_snapshot;
wire [7:0] z80_ch0_car_tl_live;
wire z80_ch0_car_tl_written_ever;
wire [7:0] z80_ch0_car_sl_rr_live;
wire z80_ch0_con_live;
wire z80_ch0_am_live;
wire z80_ch0_egtyp_live;
wire z80_ch0_internal_retrig_no_keyon;
wire [9:0] z80_ch7_eg_v_live;
wire [9:0] z80_ch8_eg_v_live;
wire [2:0] z80_ch7_state_live;
wire [5:0] z80_ch7_rate_live;
wire [3:0] z80_ch7_keycode_live;
wire       z80_ch7_ksr_live;
wire [2:0] z80_ch8_state_live;
wire [5:0] z80_ch8_rate_live;
wire [3:0] z80_ch8_keycode_live;
wire       z80_ch8_ksr_live;
wire [7:0] z80_ym1_reg_b0_recency_100ms;
wire [8:0] z80_ym1_ch_keyon_held_100ms;
wire z80_audio_nonzero_while_all_keyoff_ever;
wire z80_last_ym1_addr_was_83_ever;
wire [7:0] z80_ch0_sl_rr_at_stuck_audio_snapshot;
wire [7:0] z80_ram_8115_fade_level_live;
wire z80_ram_8116_fade_active_live;
wire z80_audio_nonzero_while_all_keyoff_live;
wire [7:0] z80_stuck_audio_duration_100ms;
wire z80_stuck_envelope_confirmed_ever;
wire [8:0] z80_ym2_ch_key_on_state;
wire z80_audio_nonzero_while_ym2_all_keyoff_live;
wire [7:0] z80_stuck_audio_ym2_duration_100ms;
wire [8:0] z80_ym2_ch_audible_live;
wire z80_stuck_envelope_ym2_confirmed_ever;
wire [3:0] z80_stuck_channel_index_snapshot;
wire [7:0] z80_stuck_channel_sl_rr_snapshot;
wire z80_stuck_channel_sl_rr_was_written;
wire [12:0] z80_ym2_ch7_freq_live;
wire [12:0] z80_ym2_ch8_freq_live;
wire z80_ym2_retrig_while_audible_ch7;
wire z80_ym2_retrig_while_audible_ch8;
wire [8:0] z80_ym2_ch_stuck_confirmed;
wire z80_ym1_ch_audible_ever_differed;
wire [2:0] z80_ch4_state_live;
wire [5:0] z80_ch4_rate_live;
wire [3:0] z80_ch4_keycode_live;
wire z80_ch4_ksr_live;
wire [2:0] z80_ch0_state_live;
wire [5:0] z80_ch0_rate_live;
wire [3:0] z80_ch0_keycode_live;
wire z80_ch0_ksr_live;
wire [3:0] z80_ch4_reg_b4_expected_keycode;
wire z80_ch4_reg_b4_written_ever;
wire z80_ch4_reg_2c_expected_ksr;
wire z80_ch4_reg_2c_written_ever;
wire z80_dyn_instr_captured;
wire z80_dyn_instr_is_defective;

battlantis_sound battlantis_sound (
    .clk(clk_sys),
    .rst(reset),
    .ce_z80(ce_z80),
    .ce_ym3812(ce_ym3812),
    .snd_latch(sound_latch_to_z80),
    .snd_irq(sound_irq_to_z80),
    .ioctl_sound_addr(ioctl_sound_addr),
    .ioctl_sound_data(ioctl_dout[7:0]),
    .ioctl_sound_we(ioctl_sound_we),
    .audio_l(audio_l),
    .audio_r(audio_r),
    .z80_fetching(z80_fetching),
    .irq_ack(z80_irq_ack),
    .ym_written(ym_written),
    .z80_halted(z80_halted),
    .pc_hit_ei_364(z80_pc_hit_ei),
    .pc_hit_0038(z80_pc_hit_0038),
    .pc_hit_csumfail_2be(z80_pc_hit_csumfail),
    .pc_past_delay_loop(z80_pc_past_delay),
    .pc_past_ramtest_loop(z80_pc_past_ramtest),
    .pc_past_checksum_loop(z80_pc_past_checksum),
    .ch0_op2_tl_ever_loud(z80_ch0_op2_tl_ever_loud),
    .ch0_tl_loud_at_keyon(z80_ch0_tl_loud_at_keyon),
    .pc_hit_0000(z80_pc_hit_0000),
    .pc_hit_0000_wrong_data(z80_pc_hit_0000_wrong_data),
    .ch0_ar_zero_at_keyon(z80_ch0_ar_zero_at_keyon),
    .ch0_eg_type_at_keyon(z80_ch0_eg_type_at_keyon),
    .ch0_ksl_nonzero_at_keyon(z80_ch0_ksl_nonzero_at_keyon),
    .ch0_ksr_at_keyon(z80_ch0_ksr_at_keyon),
    .ch0_dr_zero_at_keyon(z80_ch0_dr_zero_at_keyon),
    .ch0_sl_rr_zero_at_keyon(z80_ch0_sl_rr_zero_at_keyon),
    .ym1_snd_mag_gt256_ever(z80_ym1_snd_mag_gt256_ever),
    .ym1_ch0_keyon_held_100ms(z80_ym1_ch0_keyon_held_100ms),
    .ym1_ch0_ar_fast_at_keyon(z80_ym1_ch0_ar_fast_at_keyon),
    .ch0_test_reg_nonzero_at_keyon(z80_ch0_test_reg_nonzero_at_keyon),
    .pc_hit_000e_wrong_data(z80_pc_hit_000e_wrong_data),
    .ch0_con_additive_at_keyon(z80_ch0_con_additive_at_keyon),
    .hl_reached_8800(z80_hl_reached_8800),
    .a_hit_88_at_jrnz(z80_a_hit_88_at_jrnz),
    .z_wrong_when_a_88(z80_z_wrong_when_a_88),
    .executed_ex_af(z80_executed_ex_af),
    .key_on_triggered(z80_key_on_triggered),
    .ch0_fnum_nonzero(z80_ch0_fnum_nonzero),
    .ch0_op2_tl_not_max(z80_ch0_op2_tl_not_max),
    .ym1_snd_ever_nonzero(z80_ym1_snd_ever_nonzero),
    .audio_mag_gt256_ever(z80_audio_mag_gt256_ever),
    .audio_mag_gt4096_ever(z80_audio_mag_gt4096_ever),
    .z80_fetch_count_reached_8(z80_fetch_count_reached_8),
    .ch0_freq_infrasonic_at_keyon(z80_ch0_freq_infrasonic_at_keyon),
    .ch0_fb_nonzero_at_keyon(z80_ch0_fb_nonzero_at_keyon),
    .ch0_car_eg_lt256_ever(z80_ch0_car_eg_lt256_ever),
    .ch0_car_eg_lt64_ever(z80_ch0_car_eg_lt64_ever),
    .ch0_car_eg_ever_changed(z80_ch0_car_eg_ever_changed),
    .eg_cnt_ever_changed(z80_eg_cnt_ever_changed),
    .ch0car_keyon_now_ever(z80_ch0car_keyon_now_ever),
    .ch0car_sum_up_ever(z80_ch0car_sum_up_ever),
    .ch0car_eg_in_I_ever_changed(z80_ch0car_eg_in_I_ever_changed),
    .ch0car_step_ever(z80_ch0car_step_ever),
    .ch0car_state_attack_ever(z80_ch0car_state_attack_ever),
    .ch0car_attack_step_sumup_ever(z80_ch0car_attack_step_sumup_ever),
    .ch0car_joint_hit_reg_ever_out(z80_ch0car_joint_hit_reg_ever),
    .ch0car_joint_hit_III_ever_out(z80_ch0car_joint_hit_III_ever),
    .ch0car_arate_was_15_ever(z80_ch0car_arate_was_15_ever),
    .ch0car_rate_was_63_ever(z80_ch0car_rate_was_63_ever),
    .ym1_ch_key_on_state(z80_ym1_ch_key_on_state),
    .ym1_ch_audible_live(z80_ym1_ch_audible_live),
    .ym1_ch_stuck_confirmed(z80_ym1_ch_stuck_confirmed),
    .ym1_ch_stuck_sl_rr_snapshot(z80_ym1_ch_stuck_sl_rr_snapshot),
    .ch0_car_tl_live(z80_ch0_car_tl_live),
    .ch0_car_tl_written_ever(z80_ch0_car_tl_written_ever),
    .ch0_car_sl_rr_live(z80_ch0_car_sl_rr_live),
    .ch0_con_live(z80_ch0_con_live),
    .ch0_am_live(z80_ch0_am_live),
    .ch0_egtyp_live(z80_ch0_egtyp_live),
    .ch0_internal_retrig_no_keyon(z80_ch0_internal_retrig_no_keyon),
    .ch7_eg_v_live(z80_ch7_eg_v_live),
    .ch8_eg_v_live(z80_ch8_eg_v_live),
    .ch7_state_live(z80_ch7_state_live),
    .ch7_rate_live(z80_ch7_rate_live),
    .ch7_keycode_live(z80_ch7_keycode_live),
    .ch7_ksr_live(z80_ch7_ksr_live),
    .ch8_state_live(z80_ch8_state_live),
    .ch8_rate_live(z80_ch8_rate_live),
    .ch8_keycode_live(z80_ch8_keycode_live),
    .ch8_ksr_live(z80_ch8_ksr_live),
    .ym1_reg_b0_recency_100ms(z80_ym1_reg_b0_recency_100ms),
    .ym1_ch_keyon_held_100ms(z80_ym1_ch_keyon_held_100ms),
    .audio_nonzero_while_all_keyoff_ever(z80_audio_nonzero_while_all_keyoff_ever),
    .last_ym1_addr_was_83_ever(z80_last_ym1_addr_was_83_ever),
    .ch0_sl_rr_at_stuck_audio_snapshot(z80_ch0_sl_rr_at_stuck_audio_snapshot),
    .ram_8115_fade_level_live(z80_ram_8115_fade_level_live),
    .ram_8116_fade_active_live(z80_ram_8116_fade_active_live),
    .audio_nonzero_while_all_keyoff_live_out(z80_audio_nonzero_while_all_keyoff_live),
    .stuck_audio_duration_100ms(z80_stuck_audio_duration_100ms),
    .stuck_envelope_confirmed_ever(z80_stuck_envelope_confirmed_ever),
    .ym2_ch_key_on_state(z80_ym2_ch_key_on_state),
    .audio_nonzero_while_ym2_all_keyoff_live_out(z80_audio_nonzero_while_ym2_all_keyoff_live),
    .stuck_audio_ym2_duration_100ms(z80_stuck_audio_ym2_duration_100ms),
    .ym2_ch_audible_live(z80_ym2_ch_audible_live),
    .stuck_envelope_ym2_confirmed_ever(z80_stuck_envelope_ym2_confirmed_ever),
    .stuck_channel_index_snapshot(z80_stuck_channel_index_snapshot),
    .stuck_channel_sl_rr_snapshot(z80_stuck_channel_sl_rr_snapshot),
    .stuck_channel_sl_rr_was_written(z80_stuck_channel_sl_rr_was_written),
    .ym2_ch7_freq_live(z80_ym2_ch7_freq_live),
    .ym2_ch8_freq_live(z80_ym2_ch8_freq_live),
    .ym2_retrig_while_audible_ch7(z80_ym2_retrig_while_audible_ch7),
    .ym2_retrig_while_audible_ch8(z80_ym2_retrig_while_audible_ch8),
    .ym2_ch_stuck_confirmed(z80_ym2_ch_stuck_confirmed),
    .ym1_ch_audible_ever_differed(z80_ym1_ch_audible_ever_differed),
    .ch4_state_live(z80_ch4_state_live),
    .ch0_state_live(z80_ch0_state_live),
    .ch0_rate_live(z80_ch0_rate_live),
    .ch0_keycode_live(z80_ch0_keycode_live),
    .ch0_ksr_live(z80_ch0_ksr_live),
    .ch4_rate_live(z80_ch4_rate_live),
    .ch4_keycode_live(z80_ch4_keycode_live),
    .ch4_ksr_live(z80_ch4_ksr_live),
    .ch4_reg_b4_expected_keycode(z80_ch4_reg_b4_expected_keycode),
    .ch4_reg_b4_written_ever(z80_ch4_reg_b4_written_ever),
    .ch4_reg_2c_expected_ksr(z80_ch4_reg_2c_expected_ksr),
    .ch4_reg_2c_written_ever(z80_ch4_reg_2c_written_ever),
    .dyn_instr_captured(z80_dyn_instr_captured),
    .dyn_instr_is_defective(z80_dyn_instr_is_defective)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

// Sound-chain isolation diagnostic (2026-08-16, task #8) -- five sticky
// checks to pinpoint where in ROM-load -> Z80-execution -> IRQ-ack ->
// YM-write -> audio-mix chain the silence originates, since static
// inspection alone hasn't found a wiring bug anywhere in the chain.
//
// Gating history, two wrong attempts before this one: (1) gated on the
// combined `reset` wire (sys_reset | ioctl_download) -- structurally could
// never read GREEN, since ioctl_sound_we only pulses while ioctl_download
// is high. (2) gated on `sys_reset & ~ioctl_download`, reasoning sys_reset
// itself (not just the combined `reset` wire) stays asserted for the whole
// download per this file's own sdram_reset precedent -- STILL wrong:
// traced hps_io.sv directly and confirmed `ioctl_wr` can never pulse
// unless `ioctl_download` is simultaneously true at the source (its own
// `wr <= 1` is itself gated `if(ioctl_download)`), which rules out a
// mid-download gap entirely. The real problem is a race at the *end* of
// download: if `sys_reset` (folding in the framework's `RESET`) lingers
// high for even a few cycles after `ioctl_download` drops -- plausible,
// since HPS typically releases RESET slightly after the download itself
// ends -- the `sys_reset & ~ioctl_download` clear condition goes true
// right at that transition and wipes out whatever was just captured
// during the download, before it can ever be read back. Confirmed
// consistent with every observation: the download-time-only signals
// (sound_rom_loaded_seen, ioctl_addr_passed_18000/_20000 below) all read
// RED, while the post-download runtime signals here (z80_fetching_ever,
// ym_written_ever) read correctly, since they're set long after any such
// transient has passed.
//
// Fix: stop trying to time a clear relative to sys_reset/ioctl_download's
// *end* at all -- clear only on the rising edge of ioctl_download (the
// *start* of a fresh download), which can never coincide with anything
// captured during that same download.
reg ioctl_download_prev;
always @(posedge clk_sys) ioctl_download_prev <= ioctl_download;
wire ioctl_download_rising = ioctl_download && !ioctl_download_prev;

reg reset_pulsed_after_boot;
reg reset_src_hw_after_boot;      // RESET (framework hardware reset input)
reg reset_src_status0_after_boot; // status[0] (OSD "Reset" toggle)
// 2026-08-19, task #8 round 34: refines the status[0] check specifically
// -- round 33 found status[0] (not RESET, not buttons[1]) pulsing after
// test_done, but a single load_core reload right before the capture
// window could plausibly cause a one-time status[0] blip as part of the
// framework's own core-loading process, not a genuine ongoing gameplay
// issue. Adds a real settle delay (10 real seconds @ 48MHz = 480,000,000
// clk cycles) after test_done before arming this specific check, so any
// pulse from the initial load/boot settling process is cleanly excluded
// -- only a status[0] pulse occurring well into already-established,
// stable gameplay would now set the flag.
reg [28:0] settle_cnt;
reg        settle_done;
localparam [28:0] SETTLE_THRESHOLD = 29'd480_000_000; // 10s @ 48MHz
// 2026-08-19, task #8 round 36: the reset-source thread (rounds 30-35)
// ruled out RESET/status[0]/buttons[1] all recurring during real gameplay,
// closing the "spurious reset keeps yanking jtopl2 back to zero" theory.
// Redirects to the other still-unverified assumption behind the round
// 29-31 simulation-vs-hardware magnitude gap: ce_z80/ce_ym3812 are both
// gated off by `pause_cpu` (status[30], the OSD's own "Pause Game"
// toggle) -- the existing diag_box_pause_cpu only ever samples its LIVE,
// current value at the single instant of capture, which would completely
// miss an intermittent flicker. If pause_cpu is pulsing on/off during real
// gameplay (not just "stuck on"), it would stretch real wall-clock time
// far beyond the internal jtopl2 clock time the round-29 simulation
// assumed, which would fully explain why a note confirmed held 100ms+ of
// real time (round 30) still hasn't reached the simulation's ~150ms
// envelope peak -- most of that 100ms may not correspond to real ce_ym3812
// ticks at all. This is a genuine "ever seen high" sticky latch, distinct
// from the existing live check.
reg pause_cpu_ever_high_after_boot;
// 2026-08-19, task #8 round 42: round 41 found jtopl_sh_rst.v (used by
// jtopl_eg.v for its own per-slot storage) needs `rst` held for the full
// 18 cenop cycles (=1152 clk_sys cycles=24us) to completely flush its
// serial reset chain -- if held for less, the chain is only partially
// reset and never self-corrects. Rounds 32/35 already confirmed `reset`
// genuinely pulses again once, briefly, after boot (concluded a one-time
// load-time artifact, not recurring) -- but that pulse's DURATION was
// never checked. This measures it directly: counts real clk_sys cycles
// while `test_done && reset` is held, and on the falling edge, latches
// whether that duration was nonzero but shorter than the 24us threshold.
reg [11:0] post_boot_reset_dur_cnt;
reg        post_boot_reset_active_prev;
reg        reset_pulse_too_short_ever;
localparam [11:0] EG_FLUSH_THRESHOLD_CYCLES = 12'd1152; // 24us @ 48MHz
// 2026-08-19, task #8 round 37: sticky wrapper for
// ch0_freq_infrasonic_at_keyon -- see rtl/battlantis_sound.v's port
// declaration comment for the full reasoning (real frequency check, never
// verified before now).
always @(posedge clk_sys) begin
    if (ioctl_download_rising) begin
        reset_pulsed_after_boot <= 1'b0;
        reset_src_hw_after_boot <= 1'b0;
        reset_src_status0_after_boot <= 1'b0;
        settle_cnt <= 29'd0;
        settle_done <= 1'b0;
        pause_cpu_ever_high_after_boot <= 1'b0;
        post_boot_reset_dur_cnt <= 12'd0;
        post_boot_reset_active_prev <= 1'b0;
        reset_pulse_too_short_ever <= 1'b0;
    end else begin
        if (test_done && reset) reset_pulsed_after_boot <= 1'b1;
        if (test_done && RESET) reset_src_hw_after_boot <= 1'b1;
        if (test_done && !settle_done) begin
            if (settle_cnt >= SETTLE_THRESHOLD) settle_done <= 1'b1;
            else settle_cnt <= settle_cnt + 1'b1;
        end
        if (settle_done && status[0]) reset_src_status0_after_boot <= 1'b1;
        if (test_done && pause_cpu) pause_cpu_ever_high_after_boot <= 1'b1;
        post_boot_reset_active_prev <= test_done && reset;
        if (test_done && reset) begin
            if (post_boot_reset_dur_cnt != 12'hFFF) post_boot_reset_dur_cnt <= post_boot_reset_dur_cnt + 1'b1;
        end else begin
            if (post_boot_reset_active_prev && post_boot_reset_dur_cnt != 12'd0 &&
                post_boot_reset_dur_cnt < EG_FLUSH_THRESHOLD_CYCLES)
                reset_pulse_too_short_ever <= 1'b1;
            post_boot_reset_dur_cnt <= 12'd0;
        end
    end
end

// ioctl_addr threshold diagnostic (2026-08-16, re-added correctly gated):
// distinguishes "the download's address stream never reaches the sound
// ROM's 0x18000-0x1FFFF window" from "it reaches/passes it but the write
// strobe specifically never lands there". Gated on ioctl_download_rising
// (see the corrected-gate explanation above) -- two earlier re-adds, gated
// on bare sys_reset and then sys_reset & ~ioctl_download, were ALSO
// silently always-RED regardless of truth, for the identical reason.
always @(posedge clk_sys) begin
    if (ioctl_download_rising) begin
    end else if (ioctl_download && ioctl_wr) begin
    end
end

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
// Task #17 revival: combine the manual "Flip Monitor" OSD toggle with the
// game's own automatic cocktail-cabinet flip request (flip_screen_req,
// K007342 reg 0x00 bit4) via XOR -- the same way real hardware composes a
// physical/DIP flip source with a software-driven one onto a single CRT
// flip signal (flipping both cancels back to normal; either alone flips).
wire effective_flip = flip_monitor ^ flip_screen_req;
wire rotate_ccw = effective_flip;
wire flip       = effective_flip;
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

// --- DIAGNOSTIC OVERLAY (cleaned up 2026-08-15) ---
// Pruned every box/row tied to the old sprite-SDRAM path (diag_box,
// diag_box2, diag_box4, diag_box7, diag_box8, the probe boxes, diag_box_last,
// diag_box_visible_sdram, diag_box_spritebank, diag_box_small_nonzero, rows
// 4-17, row 18, rows 21-23, row 24/diag_box_solo_active) now that k007420's
// sprite engine is 100% static BRAM with no SDRAM fetch path left to
// diagnose, plus two dead constants confirmed hardcoded in k007342.v
// (shadow_verify_match_out=1'b0 always, shadow_verify_fail_count_out=16'd0
// always) -- diag_box_shadow_match and row 29.
//
// Second pass (2026-08-15, post-fix): the black-background investigation
// itself is now resolved (see Battlantis.sv's sdram_reset comment and
// project_history/debugging_log.md section 21) -- removed every
// investigation-specific diagnostic built for it (ioctl_reached_tile_rom,
// max_ioctl_addr_seen[_nodl], sys_reset_low_during_download, and the
// detailed tile-cache telemetry in the old rows 19/20/25/26/27/30) rather
// than leave now-answered questions cluttering the screen. What remains is
// the original small health-check row: local SDRAM loopback self-test
// (diag_box3), a 4-byte loopback test (diag_byte0-3), and a live check that
// the tile-cache fill state machine isn't stuck (diag_box_shadow_stuck) --
// confined to a single row near the top-left corner.
wire diag_box3 = test_done && (h_cnt >= 40 && h_cnt < 56) && (v_cnt >= 16) && (v_cnt < 32);
// 2026-08-23, task #8 round 131: see dyn_instr_captured/dyn_instr_is_defective's
// port comment in battlantis_sound.v -- borrowing this mostly-empty top row's
// free space rather than crowding the packed lower rows.
// 2026-08-23, task #8 round 133: live readout of the raw mailbox command
// byte (`sound_latch`, the main CPU's own 0x2E14 write, latched just above
// this diagnostic block) -- ROM disassembly of the sound Z80's dispatch
// entry (0x0079-0x009A) found the software fade-arm routine (0x00F3) is
// reached ONLY via `CP 0x80; JR z,0x00f3` -- command byte 0x80 is the
// single, exact trigger. Round 133's own live capture already showed the
// fade mechanism never arms during the whole title-screen-to-stage-1
// span, meaning command 0x80 is apparently never sent there -- this
// exposes the actual byte value live so a screenshot burst across that
// exact transition can show what IS sent instead, to determine whether
// 0x80 is genuinely missing (an authoring gap) or reached some other way.
wire diag_box_soundlatch_bit7 = test_done && verify_done && (h_cnt >= 120 && h_cnt < 134) && (v_cnt >= 16) && (v_cnt < 32);
wire diag_box_soundlatch_bit6 = test_done && verify_done && (h_cnt >= 136 && h_cnt < 150) && (v_cnt >= 16) && (v_cnt < 32);
wire diag_box_soundlatch_bit5 = test_done && verify_done && (h_cnt >= 152 && h_cnt < 166) && (v_cnt >= 16) && (v_cnt < 32);
wire diag_box_soundlatch_bit4 = test_done && verify_done && (h_cnt >= 168 && h_cnt < 182) && (v_cnt >= 16) && (v_cnt < 32);
wire diag_box_soundlatch_bit3 = test_done && verify_done && (h_cnt >= 184 && h_cnt < 198) && (v_cnt >= 16) && (v_cnt < 32);
wire diag_box_soundlatch_bit2 = test_done && verify_done && (h_cnt >= 200 && h_cnt < 214) && (v_cnt >= 16) && (v_cnt < 32);
wire diag_box_soundlatch_bit1 = test_done && verify_done && (h_cnt >= 216 && h_cnt < 230) && (v_cnt >= 16) && (v_cnt < 32);
wire diag_box_soundlatch_bit0 = test_done && verify_done && (h_cnt >= 232 && h_cnt < 246) && (v_cnt >= 16) && (v_cnt < 32);
// 2026-08-28: Rack 'Em Up real-hardware-only tile-cache garbage
// investigation (task #79) used this overlay's `OVERLAY_HIDDEN` mechanism
// for a live, on-screen `cache_sim_miss_count` readout, since Verilator's
// own hit-rate numbers didn't predict the severity seen on real hardware.
// That investigation is complete -- the result (miss count stays low on
// BOTH games, ruling out a bandwidth-bottleneck theory; a Verilator-side
// cross-layer aliasing check found the real mechanism instead) is fully
// written up in project_history/TASKS.md's Rack 'Em Up section and task
// #79. The diagnostic boxes themselves (a broken small 9-box attempt, plus
// a working large-box miss-count readout) have been removed now that
// they've served their purpose -- see that TASKS.md entry if this
// specific live on-screen technique is needed again for the eventual fix.

wire diag_row2_v = (v_cnt >= 36) && (v_cnt < 52);
// 2026-08-19, task #8 round 31: retires diag_box_pc_csumfail (long
// confirmed GREEN, boot execution extensively re-verified since) to
// free this slot. See rtl/battlantis_sound.v's port declaration
// comment for ym1_ch0_ar_fast_at_keyon.
// 2026-08-19, task #8 round 51: retires diag_box_ch0_ar_fast (settled,
// superseded by round 44's direct hand-calculation confirming rate is
// structurally nonzero) to free this slot. See rtl/battlantis_sound.v's
// port declaration comment for ch0car_step_ever.
// 2026-08-17, Gemini consult (task #8) round 2: pc_hit_0038/pc_out_of_bounds
// both came back GREEN on real hardware, refuting the garbage-execution
// theory -- these two disambiguate whether the CPU's fetch stream ever
// includes the real reset vector at all, and if so whether the ROM byte
// read there is correct. Reusing row3's unused h60-96 space.
// 2026-08-19, task #8 round 39: retires diag_box_pc_0000_wrongdata (long
// confirmed GREEN, superseded -- the T80 accumulator bug this whole
// boot-trap thread traced back to has been fixed and re-verified many
// rounds since) to free this slot. See rtl/battlantis_sound.v's port
// declaration comment for ch0_fb_nonzero_at_keyon.
// 2026-08-17, Gemini consult round 3: "runaway data pointer" theory --
// bisects whether the CPU ever exits the RAM-clear loop at all.
// 2026-08-18, task #8 round 20: retires pc_hit_0011 (long confirmed
// GREEN since the T80 fix) to free this slot -- see
// rtl/battlantis_sound.v's port declaration comment for
// ch0_ar_zero_at_keyon.
// 2026-08-19, task #8 round 44: retires diag_box_ch0_ar_zero (settled,
// part of the now-closed register-level thread) to free this slot. See
// rtl/battlantis_sound.v's port declaration comment for
// ch0car_keyon_now_ever.
// 2026-08-17, round 4: isolating why the RAM-clear loop's CP 0x88 exit
// condition never fires -- checks the comparison operand byte at 0x000E.
// 2026-08-18, task #8 round 22: retires pc_hit_000e (long confirmed
// GREEN) to free this slot -- see rtl/battlantis_sound.v's port
// declaration comment for ch0_eg_type_at_keyon.
// 2026-08-19, task #8 round 43: retires diag_box_ch0_egtyp (settled, part
// of the now-closed register-level thread) to free this slot. See
// rtl/battlantis_sound.v's port declaration comment for
// eg_cnt_ever_changed.
// 2026-08-17, round 6: boot_chain_corrupted=GREEN exonerated the data
// path end-to-end -- these test T80's internal LD A,H / CP flag logic
// directly (A and Zero-flag readback added to cpu_z80.v/T80s.vhd).
// 2026-08-19, task #8 round 40: retires diag_box_hl_8800 and
// diag_box_a_hit_88 (both long confirmed and re-verified across many
// rounds since the T80 accumulator bug fix -- GREEN/RED as expected for a
// working loop, per round 7's own analysis) to free two slots. See
// rtl/battlantis_sound.v's port declaration comment for
// ch0_car_eg_lt256_ever/ch0_car_eg_lt64_ever.
// 2026-08-17, round 7: Gemini's Alternate/AF' theory -- tests whether
// EX AF,AF' (opcode 0x08) ever executes anywhere in the boot sequence.
// 2026-08-19, task #8 round 33: third source-breakdown slot -- retires
// diag_box_ex_af (long confirmed GREEN/never-executed, re-verified many
// rounds since) to free this slot. See the round 33 note above
// diag_box_reset_src_hw/diag_box_reset_src_status0.
// 2026-08-17, task #8 correction: distinguishes a real OPL2 note-trigger
// from the boot code's own silence-safe init sequence.
// 2026-08-22, task #8 round 121: reuses row3's freed slot (its original
// boot-trap boxes above all settled and were retired during the round-115
// overlay cleanup). Originally showed round 121b's duration-gated
// per-channel "stuck 5.0s+" sticky latch, which round 123 found is an
// unreliable proxy: it only proves a 5+ second window existed AT SOME
// POINT, not that it coincides with the real audible whine (round 122/123
// showed channel 0's own such window closes well before the whine's own
// independently-measured t=18-24s start, most likely an unrelated,
// probably-benign event like the title screen's own closing note fading
// out normally). Round 124 switches this row back to round 121a's raw
// live "audible right now" bit (rtl/battlantis_sound.v's
// ym1_ch_audible_live, already computed for all 9 channels, no new RTL
// needed) -- noisy in general (every channel legitimately dips below the
// audible threshold during ordinary note playback), but meant to be
// sampled specifically DURING the known t=18-24s whine window and read
// directly alongside the existing per-channel Key-On row
// (diag_box_keyon_ch0-8, row6, same h_cnt pitch): any channel reading
// GREEN here with Key-On also RED at that exact moment is a real,
// unambiguous candidate for the true source.
wire diag_row3_v = (v_cnt >= 56) && (v_cnt < 72);
wire diag_box_chaudible_ch0 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 16 ) && diag_row3_v;
wire diag_box_chaudible_ch1 = test_done && verify_done && (h_cnt >= 20  && h_cnt < 36 ) && diag_row3_v;
wire diag_box_chaudible_ch2 = test_done && verify_done && (h_cnt >= 40  && h_cnt < 56 ) && diag_row3_v;
wire diag_box_chaudible_ch3 = test_done && verify_done && (h_cnt >= 60  && h_cnt < 76 ) && diag_row3_v;
wire diag_box_chaudible_ch4 = test_done && verify_done && (h_cnt >= 80  && h_cnt < 96 ) && diag_row3_v;
wire diag_box_chaudible_ch5 = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row3_v;
wire diag_box_chaudible_ch6 = test_done && verify_done && (h_cnt >= 120 && h_cnt < 136) && diag_row3_v;
wire diag_box_chaudible_ch7 = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row3_v;
wire diag_box_chaudible_ch8 = test_done && verify_done && (h_cnt >= 160 && h_cnt < 176) && diag_row3_v;

// 2026-08-23, task #8 round 128: fills row3's remaining free space
// (h180-250, same 7px-box/9px-pitch convention as round 113's stuckch_
// sl_rr_bit* boxes) with channel 0's LIVE (not frozen) carrier SL/RR
// register -- see rtl/battlantis_sound.v's ch0_car_sl_rr_live comment.
wire diag_box_ch0_slrr_live_bit7 = test_done && verify_done && (h_cnt >= 180 && h_cnt < 187) && diag_row3_v;
wire diag_box_ch0_slrr_live_bit6 = test_done && verify_done && (h_cnt >= 189 && h_cnt < 196) && diag_row3_v;
wire diag_box_ch0_slrr_live_bit5 = test_done && verify_done && (h_cnt >= 198 && h_cnt < 205) && diag_row3_v;
wire diag_box_ch0_slrr_live_bit4 = test_done && verify_done && (h_cnt >= 207 && h_cnt < 214) && diag_row3_v;
wire diag_box_ch0_slrr_live_bit3 = test_done && verify_done && (h_cnt >= 216 && h_cnt < 223) && diag_row3_v;
wire diag_box_ch0_slrr_live_bit2 = test_done && verify_done && (h_cnt >= 225 && h_cnt < 232) && diag_row3_v;
wire diag_box_ch0_slrr_live_bit1 = test_done && verify_done && (h_cnt >= 234 && h_cnt < 241) && diag_row3_v;
wire diag_box_ch0_slrr_live_bit0 = test_done && verify_done && (h_cnt >= 243 && h_cnt < 250) && diag_row3_v;

wire diag_row4_v = (v_cnt >= 76) && (v_cnt < 92);
// 2026-08-20, task #8 round 71: new row -- see
// rtl/battlantis_sound.v's ch0car_arate_was_15_ever/
// ch0car_rate_was_63_ever port comments for the full reasoning. Tests
// Gemini's jtopl_eg_pure.v bypass hypothesis directly on this real,
// confirmed-reproducing hardware: does channel 0's carrier ever actually
// get arate_I==15 / rate==63 at all, on the exact note that's supposed to
// use the maximum-attack instant-envelope-zero bypass.
// 2026-08-22, task #8 round 121c: reuses row5's freed slot (its original
// AR=15/rate=63 investigation settled and was retired during the round-115
// overlay cleanup) for channel 0's own carrier SL/RR register snapshot,
// captured at the exact instant channel 0's own new per-channel
// stuck-confirmed edge fires (see rtl/battlantis_sound.v's
// ym1_ch_stuck_sl_rr_snapshot port comment) -- channel 0 is the real
// candidate found by round 121c's timing sweep (confirmed at exactly
// t=18s, matching round 119's independent real-audio measurement of the
// whine's own start time, while every other channel's confirm bit turned
// out to be a reset/boot-silence artifact firing at t=0).

// 2026-08-22, task #8 round 122: extends row5 with two further checks
// (rather than opening a new row, per the user's "organize your tests"
// steer) -- channel 0's own live carrier Total Level register (0x43) plus
// whether it's ever been written, to check the OTHER direction from the
// jtopl2 timing math per the user's own suggestion: does the real ROM
// driver ever explicitly mute channel 0 (independent of the envelope's own
// natural release) around the transition that this core might be failing
// to apply. Also an independent cross-check of the existing per-channel
// Key-On tracking itself (register 0xB0 write-recency, watched completely
// separately from ym1_ch_key_on_state_reg[0]'s own bit5-extraction logic)
// -- confirms whether the existing tracking is trustworthy before treating
// the ~30x timing gap as a genuine jtopl2 bug.
// 2026-08-22, task #8 round 123: repurposes the now-settled ch0_tl_written
// slot (confirmed GREEN, TL genuinely written -- see round 122) for the
// live (not sticky) "is channel 0 audible right now" bit -- per the user's
// own observation that a single screenshot of ANY signal, live or sticky,
// only shows one instant; what's actually needed is the same multi-sample
// technique already used for ch0_state_live/ch0_rate_live (round 121d),
// re-applied to this bit to see whether it TRANSITIONS 1->0 (matching the
// ~0.5s decay the round-122 timing model predicts) or stays 1 the entire
// multi-second window (confirming a genuine jtopl2 timing anomaly).

// 2026-08-24, task #8 round 144: row 5 repurposed again -- round 143's
// raw eg_V readout already answered its own question (both channels
// repeatedly park at a specific mid-scale value, 96/~504, instead of
// decaying to 1023/silent -- documented in TASKS.md round 143). This
// round traces WHY: channels 7/8's own live internal envelope state,
// rate, and keycode (see rtl/battlantis_sound.v's ch7_state_live/
// ch8_state_live port comment), the same methodology that found round
// 68's original AR=15 fix. KSR is captured in the port but not displayed
// here (box-budget reasons only -- state/rate/keycode already narrow
// down the responsible bucket).
wire diag_row5_v = (v_cnt >= 96) && (v_cnt < 112);
wire diag_box_ch7st_bit2 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 7  ) && diag_row5_v;
wire diag_box_ch7st_bit1 = test_done && verify_done && (h_cnt >= 9   && h_cnt < 16 ) && diag_row5_v;
wire diag_box_ch7st_bit0 = test_done && verify_done && (h_cnt >= 18  && h_cnt < 25 ) && diag_row5_v;
wire diag_box_ch7rt_bit5 = test_done && verify_done && (h_cnt >= 27  && h_cnt < 34 ) && diag_row5_v;
wire diag_box_ch7rt_bit4 = test_done && verify_done && (h_cnt >= 36  && h_cnt < 43 ) && diag_row5_v;
wire diag_box_ch7rt_bit3 = test_done && verify_done && (h_cnt >= 45  && h_cnt < 52 ) && diag_row5_v;
wire diag_box_ch7rt_bit2 = test_done && verify_done && (h_cnt >= 54  && h_cnt < 61 ) && diag_row5_v;
wire diag_box_ch7rt_bit1 = test_done && verify_done && (h_cnt >= 63  && h_cnt < 70 ) && diag_row5_v;
wire diag_box_ch7rt_bit0 = test_done && verify_done && (h_cnt >= 72  && h_cnt < 79 ) && diag_row5_v;
wire diag_box_ch7kc_bit3 = test_done && verify_done && (h_cnt >= 81  && h_cnt < 88 ) && diag_row5_v;
wire diag_box_ch7kc_bit2 = test_done && verify_done && (h_cnt >= 90  && h_cnt < 97 ) && diag_row5_v;
wire diag_box_ch7kc_bit1 = test_done && verify_done && (h_cnt >= 99  && h_cnt < 106) && diag_row5_v;
wire diag_box_ch7kc_bit0 = test_done && verify_done && (h_cnt >= 108 && h_cnt < 115) && diag_row5_v;

wire diag_box_ch8st_bit2 = test_done && verify_done && (h_cnt >= 130 && h_cnt < 137) && diag_row5_v;
wire diag_box_ch8st_bit1 = test_done && verify_done && (h_cnt >= 139 && h_cnt < 146) && diag_row5_v;
wire diag_box_ch8st_bit0 = test_done && verify_done && (h_cnt >= 148 && h_cnt < 155) && diag_row5_v;
wire diag_box_ch8rt_bit5 = test_done && verify_done && (h_cnt >= 157 && h_cnt < 164) && diag_row5_v;
wire diag_box_ch8rt_bit4 = test_done && verify_done && (h_cnt >= 166 && h_cnt < 173) && diag_row5_v;
wire diag_box_ch8rt_bit3 = test_done && verify_done && (h_cnt >= 175 && h_cnt < 182) && diag_row5_v;
wire diag_box_ch8rt_bit2 = test_done && verify_done && (h_cnt >= 184 && h_cnt < 191) && diag_row5_v;
wire diag_box_ch8rt_bit1 = test_done && verify_done && (h_cnt >= 193 && h_cnt < 200) && diag_row5_v;
wire diag_box_ch8rt_bit0 = test_done && verify_done && (h_cnt >= 202 && h_cnt < 209) && diag_row5_v;
wire diag_box_ch8kc_bit3 = test_done && verify_done && (h_cnt >= 211 && h_cnt < 218) && diag_row5_v;
wire diag_box_ch8kc_bit2 = test_done && verify_done && (h_cnt >= 220 && h_cnt < 227) && diag_row5_v;
wire diag_box_ch8kc_bit1 = test_done && verify_done && (h_cnt >= 229 && h_cnt < 236) && diag_row5_v;
wire diag_box_ch8kc_bit0 = test_done && verify_done && (h_cnt >= 238 && h_cnt < 245) && diag_row5_v;

wire diag_row6_v = (v_cnt >= 116) && (v_cnt < 132);
// 2026-08-21, task #8 round 103: live per-channel Key-On state. See
// rtl/battlantis_sound.v's ym1_ch_key_on_state port comment -- live
// per-channel (0-8) Key-On state to find which channel is stuck causing
// the constant high-pitched whine reported post-fix.
wire diag_box_keyon_ch0 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 16 ) && diag_row6_v;
wire diag_box_keyon_ch1 = test_done && verify_done && (h_cnt >= 20  && h_cnt < 36 ) && diag_row6_v;
wire diag_box_keyon_ch2 = test_done && verify_done && (h_cnt >= 40  && h_cnt < 56 ) && diag_row6_v;
wire diag_box_keyon_ch3 = test_done && verify_done && (h_cnt >= 60  && h_cnt < 76 ) && diag_row6_v;
wire diag_box_keyon_ch4 = test_done && verify_done && (h_cnt >= 80  && h_cnt < 96 ) && diag_row6_v;
wire diag_box_keyon_ch5 = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row6_v;
wire diag_box_keyon_ch6 = test_done && verify_done && (h_cnt >= 120 && h_cnt < 136) && diag_row6_v;
wire diag_box_keyon_ch7 = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row6_v;
wire diag_box_keyon_ch8 = test_done && verify_done && (h_cnt >= 160 && h_cnt < 176) && diag_row6_v;
// 2026-08-21, task #8 round 104: see rtl/battlantis_sound.v's
// ym1_ch_keyon_held_100ms port comment -- sticky "held 100ms+ without a
// rewrite" per channel, more decisive than the live snapshot above.
wire diag_box_held_ch0 = test_done && verify_done && (h_cnt >= 180 && h_cnt < 196) && diag_row6_v;
wire diag_box_held_ch1 = test_done && verify_done && (h_cnt >= 200 && h_cnt < 216) && diag_row6_v;
wire diag_box_held_ch2 = test_done && verify_done && (h_cnt >= 220 && h_cnt < 236) && diag_row6_v;
wire diag_row7_v = (v_cnt >= 136) && (v_cnt < 152);
wire diag_box_held_ch3 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 16 ) && diag_row7_v;
wire diag_box_held_ch4 = test_done && verify_done && (h_cnt >= 20  && h_cnt < 36 ) && diag_row7_v;
wire diag_box_held_ch5 = test_done && verify_done && (h_cnt >= 40  && h_cnt < 56 ) && diag_row7_v;
wire diag_box_held_ch6 = test_done && verify_done && (h_cnt >= 60  && h_cnt < 76 ) && diag_row7_v;
wire diag_box_held_ch7 = test_done && verify_done && (h_cnt >= 80  && h_cnt < 96 ) && diag_row7_v;
wire diag_box_held_ch8 = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row7_v;
// 2026-08-21, task #8 round 105: see rtl/battlantis_sound.v's
// audio_nonzero_while_all_keyoff_ever port comment.
// 2026-08-21, task #8 round 106: see rtl/battlantis_sound.v's
// last_ym1_addr_was_83_ever port comment.
// 2026-08-21, task #8 round 107: new row, row7 nearly full. See
// rtl/battlantis_sound.v's ch0_sl_rr_at_stuck_audio_snapshot port
// comment -- live 8-bit readout, latched at the moment the stuck-audio
// condition first occurs.
// 2026-08-21, task #8 round 109: new row. See rtl/battlantis_sound.v's
// ram_8115_fade_level_live/ram_8116_fade_active_live port comment --
// live readout of the Z80 driver's own software fade-to-silence state,
// to distinguish a fade that never starts/never completes (Z80/RAM-side
// bug) from a fade that completes correctly but our OPL2 core doesn't
// obey the resulting TL/Key-Off writes (downstream bug).
// 2026-08-23, task #8 round 139: row 8 repurposed (previously channel-0-
// specific live envelope state/rate/keycode/KSR, retired -- see the
// project TASKS.md round 137 entry). Round 121's own per-channel stuck-
// confirmed breakdown (ym1_ch_stuck_confirmed) existed all along but was
// never actually wired to a display -- this is the precise, per-channel
// answer to "which channel is genuinely still audible 5+ seconds after
// every channel went Key-Off," instead of the coarser "last touched
// channel" heuristic that round 138 showed is no longer reliable now that
// its original obvious target (0x02ad) is fixed.
wire diag_row8_v = (v_cnt >= 156) && (v_cnt < 172);
wire diag_box_ym1_stuckconf_ch0 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 16 ) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch1 = test_done && verify_done && (h_cnt >= 20  && h_cnt < 36 ) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch2 = test_done && verify_done && (h_cnt >= 40  && h_cnt < 56 ) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch3 = test_done && verify_done && (h_cnt >= 60  && h_cnt < 76 ) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch4 = test_done && verify_done && (h_cnt >= 80  && h_cnt < 96 ) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch5 = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch6 = test_done && verify_done && (h_cnt >= 120 && h_cnt < 136) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch7 = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row8_v;
wire diag_box_ym1_stuckconf_ch8 = test_done && verify_done && (h_cnt >= 160 && h_cnt < 176) && diag_row8_v;

// 2026-08-23, task #8 round 139: row 12 repurposed (previously channel-4-
// specific live envelope state/rate/keycode/KSR, retired -- same reasoning
// as row 8 above). ym2's own per-channel stuck-confirmed breakdown --
// this never existed before round 139 at all (only the global
// stuck_envelope_ym2_confirmed_ever did).
wire diag_row12_v = (v_cnt >= 236) && (v_cnt < 240);
wire diag_box_ym2_stuckconf_ch0 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 14 ) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch1 = test_done && verify_done && (h_cnt >= 18  && h_cnt < 32 ) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch2 = test_done && verify_done && (h_cnt >= 36  && h_cnt < 50 ) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch3 = test_done && verify_done && (h_cnt >= 54  && h_cnt < 68 ) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch4 = test_done && verify_done && (h_cnt >= 72  && h_cnt < 86 ) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch5 = test_done && verify_done && (h_cnt >= 90  && h_cnt < 104) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch6 = test_done && verify_done && (h_cnt >= 108 && h_cnt < 122) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch7 = test_done && verify_done && (h_cnt >= 126 && h_cnt < 140) && diag_row12_v;
wire diag_box_ym2_stuckconf_ch8 = test_done && verify_done && (h_cnt >= 144 && h_cnt < 158) && diag_row12_v;

wire diag_row9_v = (v_cnt >= 176) && (v_cnt < 192);
wire diag_box_fade_bit7 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 16 ) && diag_row9_v;
wire diag_box_fade_bit6 = test_done && verify_done && (h_cnt >= 20  && h_cnt < 36 ) && diag_row9_v;
wire diag_box_fade_bit5 = test_done && verify_done && (h_cnt >= 40  && h_cnt < 56 ) && diag_row9_v;
wire diag_box_fade_bit4 = test_done && verify_done && (h_cnt >= 60  && h_cnt < 76 ) && diag_row9_v;
wire diag_box_fade_bit3 = test_done && verify_done && (h_cnt >= 80  && h_cnt < 96 ) && diag_row9_v;
wire diag_box_fade_bit2 = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row9_v;
wire diag_box_fade_bit1 = test_done && verify_done && (h_cnt >= 120 && h_cnt < 136) && diag_row9_v;
wire diag_box_fade_bit0 = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row9_v;
wire diag_box_fade_active = test_done && verify_done && (h_cnt >= 160 && h_cnt < 176) && diag_row9_v;

// 2026-08-21, task #8 round 110: see rtl/battlantis_sound.v's
// audio_nonzero_while_all_keyoff_live_out port comment -- live (not
// sticky) readout, so a screenshot burst can catch the exact frame the
// stuck-envelope condition fires and line it up against the per-channel
// Key-On row (diag_row6_v) to identify which channel is stuck.
wire diag_box_audio_alloff_live = test_done && verify_done && (h_cnt >= 180 && h_cnt < 196) && diag_row9_v;

// 2026-08-22, task #8 round 114: see rtl/battlantis_sound.v's
// stuck_channel_sl_rr_was_written port comment -- reuses row9's own
// unused h200-216 space (its boxes only span h0-196). RED = the channel
// implicated by round 113's snapshot never actually had its SL/RR
// register written this session (the 0x00 reading was an artifact of an
// unwritten register, not real data). GREEN = it genuinely was written,
// so the captured SL/RR value can be trusted.
wire diag_box_stuckch_sl_rr_written = test_done && verify_done && (h_cnt >= 200 && h_cnt < 216) && diag_row9_v;

// 2026-08-22, task #8 round 116b: see rtl/battlantis_sound.v's
// ym1_reg_b4_latch/ym1_reg_2c_latch comments -- reuses row9's remaining
// h216-256 space (its boxes only span h0-216). Compares the ROM's own
// actual Block/FNUM/KSR register writes for channel 4 against round 115's
// live keycode/ksr readout, to determine whether keycode=0/ksr=0 is what
// the ROM intended or a genuine misread/misrouted-slot bug. Round 116's
// first attempt used 4px-wide boxes here and many samples came back
// unreadable on real hardware (too thin for reliable capture) -- widened
// to the proven 7px-box/9px-pitch from rounds 111-114, which meant
// collapsing the 4 keycode bits into a single "nonzero" OR (round 115's
// row12 already shows the exact live keycode value at full width, so this
// only needs to answer "does the ROM's own write imply zero or nonzero").
wire diag_box_ch4_expkc_nz = test_done && verify_done && (h_cnt >= 216 && h_cnt < 223) && diag_row9_v;
wire diag_box_ch4_expksr = test_done && verify_done && (h_cnt >= 225 && h_cnt < 232) && diag_row9_v;
wire diag_box_ch4_b4written = test_done && verify_done && (h_cnt >= 234 && h_cnt < 241) && diag_row9_v;
wire diag_box_ch4_2cwritten = test_done && verify_done && (h_cnt >= 243 && h_cnt < 250) && diag_row9_v;

// 2026-08-22, task #8 round 111: see rtl/battlantis_sound.v's
// stuck_audio_duration_100ms / stuck_envelope_confirmed_ever port comments
// -- round 110's live flag flickered GREEN throughout an entire
// attract-mode demo capture, not just at the reported transition, which
// (per real YM3812 release-time behavior, Gemini-consulted and cross-
// checked) is consistent with normal, non-instantaneous OPL2 release decay
// rather than a stuck-forever envelope. diag_box_stuckdur_bit* displays the
// live duration-in-100ms-ticks counter (supporting detail, resets to 0
// once real silence is reached); diag_box_stuck_confirmed is the reliable
// single-screenshot verdict -- a sticky latch that only fires once that
// live duration has run continuously for 5.0 seconds, comfortably beyond
// any ordinary release tail.
wire diag_row10_v = (v_cnt >= 196) && (v_cnt < 212);
wire diag_box_stuckdur_bit7 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 16 ) && diag_row10_v;
wire diag_box_stuckdur_bit6 = test_done && verify_done && (h_cnt >= 20  && h_cnt < 36 ) && diag_row10_v;
wire diag_box_stuckdur_bit5 = test_done && verify_done && (h_cnt >= 40  && h_cnt < 56 ) && diag_row10_v;
wire diag_box_stuckdur_bit4 = test_done && verify_done && (h_cnt >= 60  && h_cnt < 76 ) && diag_row10_v;
wire diag_box_stuckdur_bit3 = test_done && verify_done && (h_cnt >= 80  && h_cnt < 96 ) && diag_row10_v;
wire diag_box_stuckdur_bit2 = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row10_v;
wire diag_box_stuckdur_bit1 = test_done && verify_done && (h_cnt >= 120 && h_cnt < 136) && diag_row10_v;
wire diag_box_stuckdur_bit0 = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row10_v;
wire diag_box_stuck_confirmed = test_done && verify_done && (h_cnt >= 160 && h_cnt < 176) && diag_row10_v;

// 2026-08-22, task #8 round 113: see rtl/battlantis_sound.v's
// stuck_channel_sl_rr_snapshot port comment. Reuses row10's own unused
// h180-256 space (its 9 boxes only span h0-176) rather than adding a new
// row, keeping the overlay's total footprint from growing further -- 8
// boxes at a tighter 7px-box/9px-pitch fit exactly. Shows the last-active
// channel's own carrier SL/RR register value at the instant the stuck
// envelope was confirmed; which channel that was is already visible by
// cross-referencing row6 (per-channel Key-On) in the same captured frame,
// so no separate channel-index box is needed here.
wire diag_box_stuckch_sl_rr_bit7 = test_done && verify_done && (h_cnt >= 180 && h_cnt < 187) && diag_row10_v;
wire diag_box_stuckch_sl_rr_bit6 = test_done && verify_done && (h_cnt >= 189 && h_cnt < 196) && diag_row10_v;
wire diag_box_stuckch_sl_rr_bit5 = test_done && verify_done && (h_cnt >= 198 && h_cnt < 205) && diag_row10_v;
wire diag_box_stuckch_sl_rr_bit4 = test_done && verify_done && (h_cnt >= 207 && h_cnt < 214) && diag_row10_v;
wire diag_box_stuckch_sl_rr_bit3 = test_done && verify_done && (h_cnt >= 216 && h_cnt < 223) && diag_row10_v;
wire diag_box_stuckch_sl_rr_bit2 = test_done && verify_done && (h_cnt >= 225 && h_cnt < 232) && diag_row10_v;
wire diag_box_stuckch_sl_rr_bit1 = test_done && verify_done && (h_cnt >= 234 && h_cnt < 241) && diag_row10_v;
wire diag_box_stuckch_sl_rr_bit0 = test_done && verify_done && (h_cnt >= 243 && h_cnt < 250) && diag_row10_v;

// 2026-08-22, task #8 round 112: chip 2 (ym2) mirror of rows 6 and 10 --
// see rtl/battlantis_sound.v's ym2_ch_key_on_state_reg comment. Rounds
// 103-111's entire stuck-envelope investigation only ever instrumented
// chip 1; this closes that gap so the whine can be ruled in or out on
// chip 2 the same way round 111 just ruled it out on chip 1. Only one more
// 16-line row fits below row10 before running off the visible frame
// (active_area caps at v_cnt<240), so this packs all 18 boxes (9 Key-On +
// 8 duration bits + 1 confirmed) into a single row using a narrower 10px
// box / 14px pitch (vs. the usual 16/20) instead of spanning two rows.
wire diag_row11_v = (v_cnt >= 216) && (v_cnt < 232);
wire diag_box_ym2_keyon_ch0 = test_done && verify_done && (h_cnt >= 0   && h_cnt < 10 ) && diag_row11_v;
wire diag_box_ym2_keyon_ch1 = test_done && verify_done && (h_cnt >= 14  && h_cnt < 24 ) && diag_row11_v;
wire diag_box_ym2_keyon_ch2 = test_done && verify_done && (h_cnt >= 28  && h_cnt < 38 ) && diag_row11_v;
wire diag_box_ym2_keyon_ch3 = test_done && verify_done && (h_cnt >= 42  && h_cnt < 52 ) && diag_row11_v;
wire diag_box_ym2_keyon_ch4 = test_done && verify_done && (h_cnt >= 56  && h_cnt < 66 ) && diag_row11_v;
wire diag_box_ym2_keyon_ch5 = test_done && verify_done && (h_cnt >= 70  && h_cnt < 80 ) && diag_row11_v;
wire diag_box_ym2_keyon_ch6 = test_done && verify_done && (h_cnt >= 84  && h_cnt < 94 ) && diag_row11_v;
wire diag_box_ym2_keyon_ch7 = test_done && verify_done && (h_cnt >= 98  && h_cnt < 108) && diag_row11_v;
wire diag_box_ym2_keyon_ch8 = test_done && verify_done && (h_cnt >= 112 && h_cnt < 122) && diag_row11_v;
// 2026-08-23, task #8 round 129: retires ym2_stuckdur_bit7-0/
// ym2_stuck_confirmed (the coarse "all-Key-Off + mixed-audio-nonzero for
// 5.0s+ at some point" check, round 111's methodology mirrored to ym2 in
// round 112) -- round 123 found this exact methodology on ym1 only proves
// a 5+ second window existed AT SOME POINT, not that it's the real event,
// and three separate wide per-channel sweeps on ym1 found no genuinely
// sustained audible-while-Key-Off channel anywhere. Replaces this slot
// with ym2's own per-channel live audible bit (never previously wired --
// round 112 only mirrored the coarse check, not round 121's finer tap),
// to check the one genuinely untested gap: does ym2 (same register
// writes as ym1, per round 118's ROM disassembly, but never independently
// verified with this finer diagnostic) show something ym1 didn't.
wire diag_box_ym2_audible_ch0 = test_done && verify_done && (h_cnt >= 126 && h_cnt < 136) && diag_row11_v;
wire diag_box_ym2_audible_ch1 = test_done && verify_done && (h_cnt >= 140 && h_cnt < 150) && diag_row11_v;
wire diag_box_ym2_audible_ch2 = test_done && verify_done && (h_cnt >= 154 && h_cnt < 164) && diag_row11_v;
wire diag_box_ym2_audible_ch3 = test_done && verify_done && (h_cnt >= 168 && h_cnt < 178) && diag_row11_v;
wire diag_box_ym2_audible_ch4 = test_done && verify_done && (h_cnt >= 182 && h_cnt < 192) && diag_row11_v;
wire diag_box_ym2_audible_ch5 = test_done && verify_done && (h_cnt >= 196 && h_cnt < 206) && diag_row11_v;
wire diag_box_ym2_audible_ch6 = test_done && verify_done && (h_cnt >= 210 && h_cnt < 220) && diag_row11_v;
wire diag_box_ym2_audible_ch7 = test_done && verify_done && (h_cnt >= 224 && h_cnt < 234) && diag_row11_v;
wire diag_box_ym2_audible_ch8 = test_done && verify_done && (h_cnt >= 238 && h_cnt < 248) && diag_row11_v;

// 2026-08-22, task #8 round 115: see rtl/battlantis_sound.v's
// ym1_dbg_ch4car_valid_I comment. Only 4 visible scanlines remain below
// row11 before the frame's own bottom edge (active_area caps at
// v_cnt<240), so this row is deliberately short (v_cnt 236-239) -- still
// enough for a single reliable pixel sample per box. 14 boxes (state[2:0],
// rate[5:0], keycode[3:0], ksr) at a 14px-box/18px-pitch fit exactly
// within the 256px width. Live/continuously-refreshed, not edge-gated --
// readable at any point during the confirmed multi-second hang.

// 2026-08-22, task #8 round 121d: reuses row8's freed slot (round 107's
// channel-0-specific SL/RR snapshot box, superseded by round 113's generic
// array, was retired here during the round-115 overlay cleanup) for
// channel 0's own live internal envelope state/rate/keycode/ksr, mirroring
// row12's ch4_state_live/ch4_rate_live/ch4_keycode_live/ch4_ksr_live boxes
// exactly -- channel 0 is round 121c's real confirmed stuck channel
// (matching the whine's actual t=18s start time), with its own carrier
// SL/RR snapshot reading 0x17 (SL=1, RR=7) -- a real, deliberate-looking
// value, not an obviously "broken" RR=0. This checks whether jtopl2's own
// keycode/ksr scaling still computes an anomalously slow rate for this
// genuinely different RR.

// 2026-08-20, task #8 round 71 follow-up: arate_was_15 came back RED --
// the real note's Attack Rate is NOT 15 after all, contradicting the
// assumption rounds 63-70's isolation-test work was built on. Rounds
// 20/31 already computed (but never displayed) whether AR is exactly 0
// and whether it's in the fast half (>=8) -- reusing those existing,
// zero-new-logic signals narrows the real value down directly.
// 2026-08-19, task #8 round 32: real hardware confirmed Key-On held
// 100ms+, Attack Rate fast, Total Level loud (rounds 30/31), and the
// isolated jtopl2 simulation reached a real, loud peak with comparable
// values even with realistic concurrent multi-channel write traffic
// interleaved (round 32's simulation experiment, no RTL change --
// concurrent-channel writes were ruled out as the explanation). This
// checks a genuinely different, cheap-to-verify assumption: does `reset`
// (fed directly into every module including battlantis_sound's jtopl2
// instances via .rst()) ever pulse again AFTER initial boot/verification
// completes (test_done)? A spurious mid-gameplay reset would directly
// explain "envelope never completes its climb despite every other
// parameter confirmed correct" -- jtopl2 would just keep getting reset
// back to its post-Key-On starting attenuation before ever climbing far,
// over and over. Retires diag_box_past_delay (long confirmed GREEN,
// boot loop exit re-verified many rounds since) to free this slot.
wire diag_box_reset_after_boot = test_done && verify_done && (h_cnt >= 0 && h_cnt < 16) && diag_row4_v;
// 2026-08-19, task #8 round 33: round 32 confirmed `reset` (=
// sys_reset | ioctl_download) genuinely pulses again after boot during
// real gameplay -- breaking sys_reset (= RESET | status[0] | buttons[1])
// down into its three individual sources to identify which one is
// actually firing, rather than guessing. `buttons[1]` in particular
// comes from hps_io's own `cfg` bits (a framework config signal, NOT
// live gameplay/joystick input -- confirmed via sys/hps_io.sv), so a
// hit there would point at something in the framework/session
// interaction rather than in-game player input. Retires
// diag_box_past_ramtest and diag_box_past_checksum (both long confirmed
// GREEN, boot loop exits re-verified many rounds since) to free two
// slots.
wire diag_box_reset_src_hw = test_done && verify_done && (h_cnt >= 20 && h_cnt < 36) && diag_row4_v;
wire diag_box_reset_src_status0 = test_done && verify_done && (h_cnt >= 40 && h_cnt < 56) && diag_row4_v;
// LIVE (non-sticky) check, 2026-08-17: directly shows pause_cpu's current
// value, to settle without guesswork whether the OSD's own "Debug: Pause
// CPU" (status[30]) menu item is stuck on from an earlier session -- that
// alone would gate ce_z80/ce_ym3812 off and could fully explain the Z80
// appearing stuck, with no RTL bug involved at all. Deliberately live, not
// sticky, since we want to know the CURRENT state, not "was it ever seen".
wire diag_box_pause_cpu = test_done && verify_done && (h_cnt >= 60 && h_cnt < 76) && diag_row4_v;
// 2026-08-19, task #8 round 36: sticky "ever seen pause_cpu high after
// boot" check -- see the pause_cpu_ever_high_after_boot declaration comment
// above for the full reasoning. Retires diag_box_fetch8 (long confirmed
// GREEN, an early coarse "Z80 fetched at least 8 opcodes" sanity check,
// superseded many rounds ago by far stronger evidence the Z80 boots and
// runs correctly) to free this slot.
wire diag_box_pause_cpu_ever = test_done && verify_done && (h_cnt >= 80 && h_cnt < 96) && diag_row4_v;
// 2026-08-17, Gemini consult (task #8): tests the "CPU trapped executing
// garbage near the reset vector" hypothesis directly -- see the comment
// block above pc_hit_0038's port declaration in rtl/battlantis_sound.v for
// the full reasoning (ym_written_ever=GREEN is a real contradiction unless
// this is happening, since every real code path to a YM3812 write requires
// passing pc_past_checksum_loop first, which reads RED).
// 2026-08-18, task #8 round 17: retires pc_hit_0038 (long confirmed
// RED/expected) to free this slot, per the diagnostic-overlay-retirement
// discipline -- row4 was full. See rtl/battlantis_sound.v's port
// declaration comment for ch0_op2_tl_ever_loud.
// 2026-08-19, task #8 round 52: retires diag_box_ch0_tl_loud (settled,
// part of the now-closed register-level thread, superseded by round 18's
// more precise ch0_tl_at_keyon) to free this slot. See
// rtl/battlantis_sound.v's port declaration comment for
// ch0car_state_attack_ever.
// 2026-08-18, task #8 round 18: retires pc_out_of_bounds (long confirmed
// RED/expected) to free this slot -- see rtl/battlantis_sound.v's port
// declaration comment for ch0_tl_loud_at_keyon.
// 2026-08-17, Gemini consult round 5: omnibus check covering every
// remaining unverified byte in the boot-chain span (0x0007-0x0010) at
// once, rather than one more ~20min compile per byte.
// 2026-08-18, task #8 round 19: retires boot_chain_corrupted (long
// confirmed GREEN/exonerated) to free this slot -- see
// rtl/battlantis_sound.v's port declaration comment for
// ch0_con_additive_at_keyon.
// 2026-08-19, task #8 round 42: retires diag_box_ch0_con (settled, part of
// the now-closed register-level thread, same source register 0xC0 as the
// newer FB check) to free this slot. See the reset_pulse_too_short_ever
// declaration comment below.
wire diag_box_reset_pulse_short = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row4_v;
// 2026-08-18, task #8 round 13: was YM1 channel 0's F-Number ever nonzero.
// 2026-08-18, task #8 round 14: was channel 0's carrier ever unmuted.
// 2026-08-18, task #8 round 15: jtopl2's raw output, before our mixing.
// 2026-08-18, task #8 round 16: magnitude checks on the final mixed
// audio_l/audio_r (post-mixing) -- distinguishes a real, audible-amplitude
// waveform from a single-sample glitch that only barely clears "!= 0".
wire diag_byte0 = test_done && (h_cnt >= 0  && h_cnt < 16) && diag_row2_v;
wire diag_byte1 = test_done && (h_cnt >= 20 && h_cnt < 36) && diag_row2_v;
wire diag_byte2 = test_done && (h_cnt >= 40 && h_cnt < 56) && diag_row2_v;
wire diag_byte3 = test_done && (h_cnt >= 60 && h_cnt < 76) && diag_row2_v;
wire diag_box_shadow_stuck = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row2_v;
wire diag_box_ym2_retrig_ch7 = test_done && verify_done && (h_cnt >= 120 && h_cnt < 136) && diag_row2_v;
wire diag_box_ym2_retrig_ch8 = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row2_v;
wire diag_box_ym1_audible_differed = test_done && verify_done && (h_cnt >= 160 && h_cnt < 176) && diag_row2_v;
// 2026-08-18, task #8 round 23: row2's h_cnt 80-96 slot was genuinely
// free (never used) -- no retirement needed this round. See
// rtl/battlantis_sound.v's port declaration comment for
// ch0_ksl_nonzero_at_keyon.
// 2026-08-19, task #8 round 53: retires diag_box_ch0_ksl (settled, part
// of the now-closed register-level thread) to free this slot. See
// rtl/battlantis_sound.v's port declaration comment for
// ch0car_attack_step_sumup_ever.
// 2026-08-20, task #8 round 63: retires diag_box_ch0car_joint (round 53's
// externally-routed version, long confirmed RED in exact agreement with
// round 55's registered version -- both already served their purpose of
// ruling out "diagnostic-wiring artifact"; rtl/battlantis_sound.v's own
// ch0car_attack_step_sumup_ever logic is left in place, just no longer
// displayed) to free this slot for a more decisive stage-III version. See
// rtl/jtopl/hdl/jtopl_eg.v's dbg_joint_hit_III port comment.
// The dragon-seam zoom question is answered (dragon's own zoom_raw==256,
// a clean ratio unaffected by the tile-boundary fix either way), so the
// diag_box_zoom_nonstd/diag_row_zoom pair that answered it is retired.
// The blank_oam_* and kill-switch/solo-sprite readouts that lived here in
// turn are retired too (2026-08-15) -- both underlying tools' questions
// are answered: solo-sprite isolation proved a monster's shadow is baked
// into that single OAM entry's own tile data (isolating one index never
// separates body from shadow), so neither tool separates the two further.
//
// 2026-08-16 (5th iteration, task #19): the four-corner check (4th
// iteration) proved the shield's own sub-tile index math is fine in the
// general case, and the wrap_y fix (K007342 reg 0x02 bit 7) then cleanly
// resolved the general full-screen-height shadow bug (confirmed via
// Grimlock's main sprite rendering cleanly post-fix). But the shield/
// crest and Spined Devil BOTH still show a shadow specifically while
// mid-zoom (clean when static/landed at 1:1 scale) -- a shared pattern
// pointing at the zoom pipeline itself, not per-sprite tile data. This
// iteration tests theory 1 (duplication): does sprite_wrap_y fire for a
// sprite that's actively mid-zoom? diag_box_zoom_wrap_hit is a small
// sticky indicator (red = hit, green = never fired since reset); once it
// fires, row 1 (v56-64) latches {sprite_idx, zoom_raw, spr_y} and row 2
// (v68-76) latches {draw_x, v_cnt, tile_idx (low 10 bits)} for that same
// event, so the exact sprite/position/zoom factor can be read back after
// the fact even if the moment itself was brief.
// diag_box_zoom_wrap_hit (task #19, answered/closed) and diag_box_setmd_seen
// (boot-hang IRQ question, answered) retired 2026-08-16 to make room --
// see git history / debugging_log.md if either needs resurrecting.
// New (2026-08-16): task #18's column-scroll-mode-usage check, task #8's
// 3-part "complete silence" localization, and 2 more sticky checks for
// whether ioctl_addr ever passes 0x18000/0x20000 during download.
// diag_box_col_scroll (task #18) retired 2026-08-16: read GREEN (never
// triggered) reliably across every session it was deployed -- closing as
// "not utilized by this game's program" rather than continuing to carry it.
// 2026-08-18, task #8 round 25: retires the display of sound_rom_loaded_seen
// (fully settled boot-chain diagnostic, 100% green and verified) to free
// this slot for checking if the YM Test Register 0x01 is ever written
// with a nonzero value (mute/test state).
// 2026-08-18, task #8 round 26: retires the display of z80_fetching_ever
// (long superseded by far more specific downstream checks; the
// underlying signal stays, still used internally) to free this slot.
// See rtl/battlantis_sound.v's port declaration comment for
// ch0_dr_zero_at_keyon.
// 2026-08-19, task #8 round 49: retires diag_box_ch0_dr (settled, part
// of the now-closed register-level thread) to free this slot. See
// rtl/battlantis_sound.v's port declaration comment for
// ch0car_eg_in_I_ever_changed.
// 2026-08-18, task #8 round 27: retires the display of z80_irq_ack_ever
// (same pre-round-12 vintage, long superseded; irq_ack itself stays,
// still used internally) to free this slot. See
// rtl/battlantis_sound.v's port declaration comment for
// ch0_sl_rr_zero_at_keyon.
// 2026-08-19, task #8 round 41: retires diag_box_ch0_sl_rr (long
// confirmed, part of the now-closed register-level investigation
// thread, rounds 13-39) to free this slot. See rtl/battlantis_sound.v's
// port declaration comment for ch0_car_eg_ever_changed.
// 2026-08-18, task #8 round 28: retires the display of ym_written_ever
// (same pre-round-12 vintage as z80_fetching/irq_ack, long superseded;
// the underlying signal stays, still used internally) to free this
// slot. See rtl/battlantis_sound.v's port declaration comment for
// ym1_snd_mag_gt256_ever.
// 2026-08-19, task #8 round 48: retires diag_box_ym1_mag (settled, part
// of the now-closed register-level thread -- superseded by round 40's
// ch0_car_eg_lt256/lt64 which check the same underlying question more
// precisely) to free this slot for the round 48 retry of sum_up_II.
// 2026-08-18, task #8 round 24: retires the display of
// sound_output_ever_nonzero (fully superseded by the more precise round
// 15/16 checks -- ym1_snd_ever_nonzero, audio_mag_gt256/4096, which
// test the same underlying question with far better precision) to free
// this slot. See rtl/battlantis_sound.v's port declaration comment for
// ch0_ksr_at_keyon. The underlying sound_output_ever_nonzero computation
// is left in place, just no longer displayed.
// 2026-08-19, task #8 round 47: retires diag_box_ch0_ksr (settled, part
// of the now-closed register-level thread) to free this slot for a
// re-test of pc_hit_0038 -- see rtl/battlantis_sound.v's port
// declaration comment for the full reasoning.
// 2026-08-19, task #8 round 55: retires diag_box_ch0_freq_infrasonic
// (round 37's theory long ruled out RED, fully closed thread) to free
// this slot for the real, registered version of round 53's joint check.
// See rtl/battlantis_sound.v's ch0car_joint_hit_reg_ever_out port comment.
// 2026-08-19, task #8 round 30: retires the display of
// ioctl_addr_passed_20000 (long confirmed GREEN -- ROM loading has never
// been in question since boot/execution was verified many rounds ago)
// to free this slot. See rtl/battlantis_sound.v's port declaration
// comment for ym1_ch0_keyon_held_100ms.
// Live CPU trace rows TEMPORARILY REMOVED (2026-08-16) for boot-hang
// bisection (task #15) -- see git history / debugging_log.md entry 22 for
// the original reasoning. Two attempts at reading multi-bit values (8px
// and 16px column widths) both failed to decode correctly against known
// ROM contents, so this is being stripped as part of isolating the actual
// hang cause per Gemini's flagged concern about added combinational
// fan-out into the video mux. Restore from git history once the hang is
// isolated, if this wasn't the cause.
wire diag_row_flags_on = 1'b0;
wire diag_row_flags_bit = 1'b0;
wire diag_row2_flags_on = 1'b0;
wire diag_row2_flags_bit = 1'b0;

// 2026-08-24, task #8 round 148: master overlay hide switch, per the
// user's direct request ("Hard to tell because there is so much on the
// screen") -- the diagnostic overlay had grown too dense to actually see
// or play the game through. This does NOT touch test_done/verify_done or
// any of the underlying diagnostic computation (both remain live and
// harmless, including their real, non-overlay uses like SDRAM port
// arbitration) -- it only short-circuits the three final video mux chains
// to pass the plain, undecorated video straight through. Flip to 1'b0 to
// re-enable the overlay for a future debugging session.
// 2026-08-28: was temporarily enabled for task #79's live cache-miss
// diagnostic (see project_history/TASKS.md's Rack 'Em Up section for the
// full investigation and result); those diagnostic boxes have since been
// removed now that they've served their purpose, and this is back to its
// normal hidden default. Note every OTHER existing diag_box_* wire in
// this file is gated on test_done/verify_done, which are dead (never
// assigned anywhere) -- they stay invisible regardless of this setting.
localparam OVERLAY_HIDDEN = 1'b1;
wire [7:0] final_vga_r = OVERLAY_HIDDEN ? vga_r :
                         diag_box3 ? (test_success ? 8'h00 : 8'hFF) :
                          diag_byte0 ? (byte_ok[0] ? 8'h00 : 8'hFF) :
                          diag_byte1 ? (byte_ok[1] ? 8'h00 : 8'hFF) :
                          diag_byte2 ? (byte_ok[2] ? 8'h00 : 8'hFF) :
                          diag_byte3 ? (byte_ok[3] ? 8'h00 : 8'hFF) :
                          diag_box_shadow_stuck ? (shadow_currently_stuck ? 8'hFF : 8'h00) :
                          diag_box_ym2_retrig_ch7 ? (z80_ym2_retrig_while_audible_ch7 ? 8'h00 : 8'hFF) : // RED=ch7 was always freshly-silent before every Key-On this session/GREEN=at least once it was reused before its own envelope finished decaying
                          diag_box_ym2_retrig_ch8 ? (z80_ym2_retrig_while_audible_ch8 ? 8'h00 : 8'hFF) :
                          diag_box_ym1_audible_differed ? (z80_ym1_ch_audible_ever_differed ? 8'h00 : 8'hFF) : // GREEN=channels genuinely differ at full clock speed (sampling artifact)/RED=they never differ even at full speed (real wiring bug)
                          diag_box_ym1_stuckconf_ch0 ? (z80_ym1_ch_stuck_confirmed[0] ? 8'h00 : 8'hFF) : // GREEN=this ym1 channel was confirmed stuck (still audible 5s+ after its own Key-Off) at least once this session
                          diag_box_ym1_stuckconf_ch1 ? (z80_ym1_ch_stuck_confirmed[1] ? 8'h00 : 8'hFF) :
                          diag_box_ym1_stuckconf_ch2 ? (z80_ym1_ch_stuck_confirmed[2] ? 8'h00 : 8'hFF) :
                          diag_box_ym1_stuckconf_ch3 ? (z80_ym1_ch_stuck_confirmed[3] ? 8'h00 : 8'hFF) :
                          diag_box_ym1_stuckconf_ch4 ? (z80_ym1_ch_stuck_confirmed[4] ? 8'h00 : 8'hFF) :
                          diag_box_ym1_stuckconf_ch5 ? (z80_ym1_ch_stuck_confirmed[5] ? 8'h00 : 8'hFF) :
                          diag_box_ym1_stuckconf_ch6 ? (z80_ym1_ch_stuck_confirmed[6] ? 8'h00 : 8'hFF) :
                          diag_box_ym1_stuckconf_ch7 ? (z80_ym1_ch_stuck_confirmed[7] ? 8'h00 : 8'hFF) :
                          diag_box_ym1_stuckconf_ch8 ? (z80_ym1_ch_stuck_confirmed[8] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch0 ? (z80_ym2_ch_stuck_confirmed[0] ? 8'h00 : 8'hFF) : // GREEN=this ym2 channel was confirmed stuck at least once this session
                          diag_box_ym2_stuckconf_ch1 ? (z80_ym2_ch_stuck_confirmed[1] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch2 ? (z80_ym2_ch_stuck_confirmed[2] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch3 ? (z80_ym2_ch_stuck_confirmed[3] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch4 ? (z80_ym2_ch_stuck_confirmed[4] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch5 ? (z80_ym2_ch_stuck_confirmed[5] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch6 ? (z80_ym2_ch_stuck_confirmed[6] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch7 ? (z80_ym2_ch_stuck_confirmed[7] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_stuckconf_ch8 ? (z80_ym2_ch_stuck_confirmed[8] ? 8'h00 : 8'hFF) :
                          diag_box_reset_after_boot ? (reset_pulsed_after_boot ? 8'h00 : 8'hFF) : // RED = reset never pulsed again after boot -- ruled out
                          diag_box_reset_src_hw ? (reset_src_hw_after_boot ? 8'h00 : 8'hFF) : // RED = framework RESET never pulsed after boot -- ruled out
                          diag_box_reset_src_status0 ? (reset_src_status0_after_boot ? 8'h00 : 8'hFF) : // RED = OSD status[0] never pulsed 10s+ into stable gameplay -- ruled out (was a load-time artifact, not ongoing)
                          diag_box_pause_cpu ? (pause_cpu ? 8'hFF : 8'h00) : // RED = pause_cpu is CURRENTLY high (bad -- CPU clocks are gated off)
                          diag_box_pause_cpu_ever ? (pause_cpu_ever_high_after_boot ? 8'hFF : 8'h00) : // RED = pause_cpu was EVER seen high after boot (bad -- would explain intermittent clock gating)
                          diag_box_reset_pulse_short ? (reset_pulse_too_short_ever ? 8'h00 : 8'hFF) : // RED = no post-boot reset pulse was ever shorter than the 24us jtopl_sh_rst needs (rules this out)
                          diag_box_ch7st_bit2 ? (z80_ch7_state_live[2] ? 8'h00 : 8'hFF) : // channel 7 live envelope state (3b), rate (6b), keycode (4b)
                          diag_box_ch7st_bit1 ? (z80_ch7_state_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_ch7st_bit0 ? (z80_ch7_state_live[0] ? 8'h00 : 8'hFF) :
                          diag_box_ch7rt_bit5 ? (z80_ch7_rate_live[5]  ? 8'h00 : 8'hFF) :
                          diag_box_ch7rt_bit4 ? (z80_ch7_rate_live[4]  ? 8'h00 : 8'hFF) :
                          diag_box_ch7rt_bit3 ? (z80_ch7_rate_live[3]  ? 8'h00 : 8'hFF) :
                          diag_box_ch7rt_bit2 ? (z80_ch7_rate_live[2]  ? 8'h00 : 8'hFF) :
                          diag_box_ch7rt_bit1 ? (z80_ch7_rate_live[1]  ? 8'h00 : 8'hFF) :
                          diag_box_ch7rt_bit0 ? (z80_ch7_rate_live[0]  ? 8'h00 : 8'hFF) :
                          diag_box_ch7kc_bit3 ? (z80_ch7_keycode_live[3] ? 8'h00 : 8'hFF) :
                          diag_box_ch7kc_bit2 ? (z80_ch7_keycode_live[2] ? 8'h00 : 8'hFF) :
                          diag_box_ch7kc_bit1 ? (z80_ch7_keycode_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_ch7kc_bit0 ? (z80_ch7_keycode_live[0] ? 8'h00 : 8'hFF) :
                          diag_box_ch8st_bit2 ? (z80_ch8_state_live[2] ? 8'h00 : 8'hFF) : // channel 8 live envelope state (3b), rate (6b), keycode (4b)
                          diag_box_ch8st_bit1 ? (z80_ch8_state_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_ch8st_bit0 ? (z80_ch8_state_live[0] ? 8'h00 : 8'hFF) :
                          diag_box_ch8rt_bit5 ? (z80_ch8_rate_live[5]  ? 8'h00 : 8'hFF) :
                          diag_box_ch8rt_bit4 ? (z80_ch8_rate_live[4]  ? 8'h00 : 8'hFF) :
                          diag_box_ch8rt_bit3 ? (z80_ch8_rate_live[3]  ? 8'h00 : 8'hFF) :
                          diag_box_ch8rt_bit2 ? (z80_ch8_rate_live[2]  ? 8'h00 : 8'hFF) :
                          diag_box_ch8rt_bit1 ? (z80_ch8_rate_live[1]  ? 8'h00 : 8'hFF) :
                          diag_box_ch8rt_bit0 ? (z80_ch8_rate_live[0]  ? 8'h00 : 8'hFF) :
                          diag_box_ch8kc_bit3 ? (z80_ch8_keycode_live[3] ? 8'h00 : 8'hFF) :
                          diag_box_ch8kc_bit2 ? (z80_ch8_keycode_live[2] ? 8'h00 : 8'hFF) :
                          diag_box_ch8kc_bit1 ? (z80_ch8_keycode_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_ch8kc_bit0 ? (z80_ch8_keycode_live[0] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch0 ? (z80_ym1_ch_key_on_state[0] ? 8'h00 : 8'hFF) : // live per-channel Key-On, RED=off/GREEN=on
                          diag_box_keyon_ch1 ? (z80_ym1_ch_key_on_state[1] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch2 ? (z80_ym1_ch_key_on_state[2] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch3 ? (z80_ym1_ch_key_on_state[3] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch4 ? (z80_ym1_ch_key_on_state[4] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch5 ? (z80_ym1_ch_key_on_state[5] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch6 ? (z80_ym1_ch_key_on_state[6] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch7 ? (z80_ym1_ch_key_on_state[7] ? 8'h00 : 8'hFF) :
                          diag_box_keyon_ch8 ? (z80_ym1_ch_key_on_state[8] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch0 ? (z80_ym1_ch_audible_live[0] ? 8'h00 : 8'hFF) : // RED=silent right now/GREEN=audible right now, this channel specifically
                          diag_box_chaudible_ch1 ? (z80_ym1_ch_audible_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch2 ? (z80_ym1_ch_audible_live[2] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch3 ? (z80_ym1_ch_audible_live[3] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch4 ? (z80_ym1_ch_audible_live[4] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch5 ? (z80_ym1_ch_audible_live[5] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch6 ? (z80_ym1_ch_audible_live[6] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch7 ? (z80_ym1_ch_audible_live[7] ? 8'h00 : 8'hFF) :
                          diag_box_chaudible_ch8 ? (z80_ym1_ch_audible_live[8] ? 8'h00 : 8'hFF) :
                          diag_box_ch0_slrr_live_bit7 ? (z80_ch0_car_sl_rr_live[7] ? 8'h00 : 8'hFF) : // channel 0's own LIVE carrier SL/RR register (not frozen at first confirm)
                          diag_box_ch0_slrr_live_bit6 ? (z80_ch0_car_sl_rr_live[6] ? 8'h00 : 8'hFF) :
                          diag_box_ch0_slrr_live_bit5 ? (z80_ch0_car_sl_rr_live[5] ? 8'h00 : 8'hFF) :
                          diag_box_ch0_slrr_live_bit4 ? (z80_ch0_car_sl_rr_live[4] ? 8'h00 : 8'hFF) :
                          diag_box_ch0_slrr_live_bit3 ? (z80_ch0_car_sl_rr_live[3] ? 8'h00 : 8'hFF) :
                          diag_box_ch0_slrr_live_bit2 ? (z80_ch0_car_sl_rr_live[2] ? 8'h00 : 8'hFF) :
                          diag_box_ch0_slrr_live_bit1 ? (z80_ch0_car_sl_rr_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_ch0_slrr_live_bit0 ? (z80_ch0_car_sl_rr_live[0] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch0 ? (z80_ym1_ch_keyon_held_100ms[0] ? 8'h00 : 8'hFF) : // RED = never held 100ms+, GREEN = held (possible stuck note)
                          diag_box_held_ch1 ? (z80_ym1_ch_keyon_held_100ms[1] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch2 ? (z80_ym1_ch_keyon_held_100ms[2] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch3 ? (z80_ym1_ch_keyon_held_100ms[3] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch4 ? (z80_ym1_ch_keyon_held_100ms[4] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch5 ? (z80_ym1_ch_keyon_held_100ms[5] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch6 ? (z80_ym1_ch_keyon_held_100ms[6] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch7 ? (z80_ym1_ch_keyon_held_100ms[7] ? 8'h00 : 8'hFF) :
                          diag_box_held_ch8 ? (z80_ym1_ch_keyon_held_100ms[8] ? 8'h00 : 8'hFF) :
                          diag_box_fade_bit7 ? (z80_ram_8115_fade_level_live[7] ? 8'h00 : 8'hFF) : // live readout of RAM 0x8115 (fade level, counts 0->0x1B then resets) -- RED=0/GREEN=1
                          diag_box_fade_bit6 ? (z80_ram_8115_fade_level_live[6] ? 8'h00 : 8'hFF) :
                          diag_box_fade_bit5 ? (z80_ram_8115_fade_level_live[5] ? 8'h00 : 8'hFF) :
                          diag_box_fade_bit4 ? (z80_ram_8115_fade_level_live[4] ? 8'h00 : 8'hFF) :
                          diag_box_fade_bit3 ? (z80_ram_8115_fade_level_live[3] ? 8'h00 : 8'hFF) :
                          diag_box_fade_bit2 ? (z80_ram_8115_fade_level_live[2] ? 8'h00 : 8'hFF) :
                          diag_box_fade_bit1 ? (z80_ram_8115_fade_level_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_fade_bit0 ? (z80_ram_8115_fade_level_live[0] ? 8'h00 : 8'hFF) :
                          diag_box_fade_active ? (z80_ram_8116_fade_active_live ? 8'h00 : 8'hFF) : // live readout of RAM 0x8116 (fade-active flag) -- RED=0(idle)/GREEN=1(fading)
                          diag_box_audio_alloff_live ? (z80_audio_nonzero_while_all_keyoff_live ? 8'h00 : 8'hFF) : // live readout -- RED=silent(correct)/GREEN=stuck audio while every channel reads Key-Off
                          diag_box_stuckch_sl_rr_written ? (z80_stuck_channel_sl_rr_was_written ? 8'h00 : 8'hFF) : // RED=implicated channel's SL/RR register never written (0x00 snapshot is an artifact)/GREEN=genuinely written (snapshot is trustworthy)
                          diag_box_ch4_expkc_nz ? ((z80_ch4_reg_b4_expected_keycode != 4'b0000) ? 8'h00 : 8'hFF) : // RED=ROM's register 0xB4 write implies keycode==0/GREEN=implies a nonzero keycode (round 115's row12 shows the exact live value)
                          diag_box_ch4_expksr ? (z80_ch4_reg_2c_expected_ksr ? 8'h00 : 8'hFF) : // KSR bit the ROM's own register 0x2C write actually implies for channel 4's carrier
                          diag_box_ch4_b4written ? (z80_ch4_reg_b4_written_ever ? 8'h00 : 8'hFF) : // RED=register 0xB4 never written (expected keycode above is an artifact)/GREEN=genuinely written
                          diag_box_ch4_2cwritten ? (z80_ch4_reg_2c_written_ever ? 8'h00 : 8'hFF) : // RED=register 0x2C never written (expected ksr above is an artifact)/GREEN=genuinely written
                          diag_box_stuckdur_bit7 ? (z80_stuck_audio_duration_100ms[7] ? 8'h00 : 8'hFF) : // live readout of the round-111 duration-in-100ms-ticks counter -- RED=0/GREEN=1
                          diag_box_stuckdur_bit6 ? (z80_stuck_audio_duration_100ms[6] ? 8'h00 : 8'hFF) :
                          diag_box_stuckdur_bit5 ? (z80_stuck_audio_duration_100ms[5] ? 8'h00 : 8'hFF) :
                          diag_box_stuckdur_bit4 ? (z80_stuck_audio_duration_100ms[4] ? 8'h00 : 8'hFF) :
                          diag_box_stuckdur_bit3 ? (z80_stuck_audio_duration_100ms[3] ? 8'h00 : 8'hFF) :
                          diag_box_stuckdur_bit2 ? (z80_stuck_audio_duration_100ms[2] ? 8'h00 : 8'hFF) :
                          diag_box_stuckdur_bit1 ? (z80_stuck_audio_duration_100ms[1] ? 8'h00 : 8'hFF) :
                          diag_box_stuckdur_bit0 ? (z80_stuck_audio_duration_100ms[0] ? 8'h00 : 8'hFF) :
                          diag_box_stuck_confirmed ? (z80_stuck_envelope_confirmed_ever ? 8'h00 : 8'hFF) : // live readout -- RED=never stuck 5.0s+/GREEN=CONFIRMED stuck envelope (definitive verdict)
                          diag_box_stuckch_sl_rr_bit7 ? (z80_stuck_channel_sl_rr_snapshot[7] ? 8'h00 : 8'hFF) : // last-active channel's own carrier SL/RR value at the confirmed stuck-audio instant
                          diag_box_stuckch_sl_rr_bit6 ? (z80_stuck_channel_sl_rr_snapshot[6] ? 8'h00 : 8'hFF) :
                          diag_box_stuckch_sl_rr_bit5 ? (z80_stuck_channel_sl_rr_snapshot[5] ? 8'h00 : 8'hFF) :
                          diag_box_stuckch_sl_rr_bit4 ? (z80_stuck_channel_sl_rr_snapshot[4] ? 8'h00 : 8'hFF) :
                          diag_box_stuckch_sl_rr_bit3 ? (z80_stuck_channel_sl_rr_snapshot[3] ? 8'h00 : 8'hFF) :
                          diag_box_stuckch_sl_rr_bit2 ? (z80_stuck_channel_sl_rr_snapshot[2] ? 8'h00 : 8'hFF) :
                          diag_box_stuckch_sl_rr_bit1 ? (z80_stuck_channel_sl_rr_snapshot[1] ? 8'h00 : 8'hFF) :
                          diag_box_stuckch_sl_rr_bit0 ? (z80_stuck_channel_sl_rr_snapshot[0] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch0 ? (z80_ym2_ch_key_on_state[0] ? 8'h00 : 8'hFF) : // ym2 (chip 2) per-channel Key-On -- RED=off/GREEN=on
                          diag_box_ym2_keyon_ch1 ? (z80_ym2_ch_key_on_state[1] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch2 ? (z80_ym2_ch_key_on_state[2] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch3 ? (z80_ym2_ch_key_on_state[3] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch4 ? (z80_ym2_ch_key_on_state[4] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch5 ? (z80_ym2_ch_key_on_state[5] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch6 ? (z80_ym2_ch_key_on_state[6] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch7 ? (z80_ym2_ch_key_on_state[7] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_keyon_ch8 ? (z80_ym2_ch_key_on_state[8] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch0 ? (z80_ym2_ch_audible_live[0] ? 8'h00 : 8'hFF) : // ym2 (chip 2) live per-channel audible-now, independent of ym1
                          diag_box_ym2_audible_ch1 ? (z80_ym2_ch_audible_live[1] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch2 ? (z80_ym2_ch_audible_live[2] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch3 ? (z80_ym2_ch_audible_live[3] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch4 ? (z80_ym2_ch_audible_live[4] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch5 ? (z80_ym2_ch_audible_live[5] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch6 ? (z80_ym2_ch_audible_live[6] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch7 ? (z80_ym2_ch_audible_live[7] ? 8'h00 : 8'hFF) :
                          diag_box_ym2_audible_ch8 ? (z80_ym2_ch_audible_live[8] ? 8'h00 : 8'hFF) :
                          diag_box_soundlatch_bit7 ? (sound_latch[7] ? 8'h00 : 8'hFF) : // live readout of the raw mailbox command byte (sound_latch)
                          diag_box_soundlatch_bit6 ? (sound_latch[6] ? 8'h00 : 8'hFF) :
                          diag_box_soundlatch_bit5 ? (sound_latch[5] ? 8'h00 : 8'hFF) :
                          diag_box_soundlatch_bit4 ? (sound_latch[4] ? 8'h00 : 8'hFF) :
                          diag_box_soundlatch_bit3 ? (sound_latch[3] ? 8'h00 : 8'hFF) :
                          diag_box_soundlatch_bit2 ? (sound_latch[2] ? 8'h00 : 8'hFF) :
                          diag_box_soundlatch_bit1 ? (sound_latch[1] ? 8'h00 : 8'hFF) :
                          diag_box_soundlatch_bit0 ? (sound_latch[0] ? 8'h00 : 8'hFF) :
                          diag_row_flags_on ? (diag_row_flags_bit ? 8'h00 : 8'hFF) :
                          diag_row2_flags_on ? (diag_row2_flags_bit ? 8'h00 : 8'hFF) : vga_r;
wire [7:0] final_vga_g = OVERLAY_HIDDEN ? vga_g :
                         diag_box3 ? (test_success ? 8'hFF : 8'h00) :
                          diag_byte0 ? (byte_ok[0] ? 8'hFF : 8'h00) :
                          diag_byte1 ? (byte_ok[1] ? 8'hFF : 8'h00) :
                          diag_byte2 ? (byte_ok[2] ? 8'hFF : 8'h00) :
                          diag_byte3 ? (byte_ok[3] ? 8'hFF : 8'h00) :
                          diag_box_shadow_stuck ? (shadow_currently_stuck ? 8'h00 : 8'hFF) :
                          diag_box_ym2_retrig_ch7 ? (z80_ym2_retrig_while_audible_ch7 ? 8'hFF : 8'h00) :
                          diag_box_ym2_retrig_ch8 ? (z80_ym2_retrig_while_audible_ch8 ? 8'hFF : 8'h00) :
                          diag_box_ym1_audible_differed ? (z80_ym1_ch_audible_ever_differed ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch0 ? (z80_ym1_ch_stuck_confirmed[0] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch1 ? (z80_ym1_ch_stuck_confirmed[1] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch2 ? (z80_ym1_ch_stuck_confirmed[2] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch3 ? (z80_ym1_ch_stuck_confirmed[3] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch4 ? (z80_ym1_ch_stuck_confirmed[4] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch5 ? (z80_ym1_ch_stuck_confirmed[5] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch6 ? (z80_ym1_ch_stuck_confirmed[6] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch7 ? (z80_ym1_ch_stuck_confirmed[7] ? 8'hFF : 8'h00) :
                          diag_box_ym1_stuckconf_ch8 ? (z80_ym1_ch_stuck_confirmed[8] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch0 ? (z80_ym2_ch_stuck_confirmed[0] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch1 ? (z80_ym2_ch_stuck_confirmed[1] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch2 ? (z80_ym2_ch_stuck_confirmed[2] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch3 ? (z80_ym2_ch_stuck_confirmed[3] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch4 ? (z80_ym2_ch_stuck_confirmed[4] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch5 ? (z80_ym2_ch_stuck_confirmed[5] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch6 ? (z80_ym2_ch_stuck_confirmed[6] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch7 ? (z80_ym2_ch_stuck_confirmed[7] ? 8'hFF : 8'h00) :
                          diag_box_ym2_stuckconf_ch8 ? (z80_ym2_ch_stuck_confirmed[8] ? 8'hFF : 8'h00) :
                          diag_box_reset_after_boot ? (reset_pulsed_after_boot ? 8'hFF : 8'h00) : // GREEN = reset DID pulse again after boot -- found it, a spurious mid-gameplay reset could explain the envelope never completing
                          diag_box_reset_src_hw ? (reset_src_hw_after_boot ? 8'hFF : 8'h00) : // GREEN = framework RESET DID pulse after boot -- found it
                          diag_box_reset_src_status0 ? (reset_src_status0_after_boot ? 8'hFF : 8'h00) : // GREEN = OSD status[0] DID pulse 10s+ into stable gameplay -- genuinely ongoing, not just load-time
                          diag_box_pause_cpu ? (pause_cpu ? 8'h00 : 8'hFF) : // GREEN = pause_cpu is currently low (good -- CPU clocks running normally)
                          diag_box_pause_cpu_ever ? (pause_cpu_ever_high_after_boot ? 8'h00 : 8'hFF) : // GREEN = pause_cpu was never seen high after boot (rules out intermittent clock gating)
                          diag_box_reset_pulse_short ? (reset_pulse_too_short_ever ? 8'hFF : 8'h00) : // GREEN = at least one post-boot reset pulse WAS shorter than 24us -- found it, could explain a partially-flushed/scrambled envelope generator
                          diag_box_ch7st_bit2 ? (z80_ch7_state_live[2] ? 8'hFF : 8'h00) :
                          diag_box_ch7st_bit1 ? (z80_ch7_state_live[1] ? 8'hFF : 8'h00) :
                          diag_box_ch7st_bit0 ? (z80_ch7_state_live[0] ? 8'hFF : 8'h00) :
                          diag_box_ch7rt_bit5 ? (z80_ch7_rate_live[5]  ? 8'hFF : 8'h00) :
                          diag_box_ch7rt_bit4 ? (z80_ch7_rate_live[4]  ? 8'hFF : 8'h00) :
                          diag_box_ch7rt_bit3 ? (z80_ch7_rate_live[3]  ? 8'hFF : 8'h00) :
                          diag_box_ch7rt_bit2 ? (z80_ch7_rate_live[2]  ? 8'hFF : 8'h00) :
                          diag_box_ch7rt_bit1 ? (z80_ch7_rate_live[1]  ? 8'hFF : 8'h00) :
                          diag_box_ch7rt_bit0 ? (z80_ch7_rate_live[0]  ? 8'hFF : 8'h00) :
                          diag_box_ch7kc_bit3 ? (z80_ch7_keycode_live[3] ? 8'hFF : 8'h00) :
                          diag_box_ch7kc_bit2 ? (z80_ch7_keycode_live[2] ? 8'hFF : 8'h00) :
                          diag_box_ch7kc_bit1 ? (z80_ch7_keycode_live[1] ? 8'hFF : 8'h00) :
                          diag_box_ch7kc_bit0 ? (z80_ch7_keycode_live[0] ? 8'hFF : 8'h00) :
                          diag_box_ch8st_bit2 ? (z80_ch8_state_live[2] ? 8'hFF : 8'h00) :
                          diag_box_ch8st_bit1 ? (z80_ch8_state_live[1] ? 8'hFF : 8'h00) :
                          diag_box_ch8st_bit0 ? (z80_ch8_state_live[0] ? 8'hFF : 8'h00) :
                          diag_box_ch8rt_bit5 ? (z80_ch8_rate_live[5]  ? 8'hFF : 8'h00) :
                          diag_box_ch8rt_bit4 ? (z80_ch8_rate_live[4]  ? 8'hFF : 8'h00) :
                          diag_box_ch8rt_bit3 ? (z80_ch8_rate_live[3]  ? 8'hFF : 8'h00) :
                          diag_box_ch8rt_bit2 ? (z80_ch8_rate_live[2]  ? 8'hFF : 8'h00) :
                          diag_box_ch8rt_bit1 ? (z80_ch8_rate_live[1]  ? 8'hFF : 8'h00) :
                          diag_box_ch8rt_bit0 ? (z80_ch8_rate_live[0]  ? 8'hFF : 8'h00) :
                          diag_box_ch8kc_bit3 ? (z80_ch8_keycode_live[3] ? 8'hFF : 8'h00) :
                          diag_box_ch8kc_bit2 ? (z80_ch8_keycode_live[2] ? 8'hFF : 8'h00) :
                          diag_box_ch8kc_bit1 ? (z80_ch8_keycode_live[1] ? 8'hFF : 8'h00) :
                          diag_box_ch8kc_bit0 ? (z80_ch8_keycode_live[0] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch0 ? (z80_ym1_ch_key_on_state[0] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch1 ? (z80_ym1_ch_key_on_state[1] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch2 ? (z80_ym1_ch_key_on_state[2] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch3 ? (z80_ym1_ch_key_on_state[3] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch4 ? (z80_ym1_ch_key_on_state[4] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch5 ? (z80_ym1_ch_key_on_state[5] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch6 ? (z80_ym1_ch_key_on_state[6] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch7 ? (z80_ym1_ch_key_on_state[7] ? 8'hFF : 8'h00) :
                          diag_box_keyon_ch8 ? (z80_ym1_ch_key_on_state[8] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch0 ? (z80_ym1_ch_audible_live[0] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch1 ? (z80_ym1_ch_audible_live[1] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch2 ? (z80_ym1_ch_audible_live[2] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch3 ? (z80_ym1_ch_audible_live[3] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch4 ? (z80_ym1_ch_audible_live[4] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch5 ? (z80_ym1_ch_audible_live[5] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch6 ? (z80_ym1_ch_audible_live[6] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch7 ? (z80_ym1_ch_audible_live[7] ? 8'hFF : 8'h00) :
                          diag_box_chaudible_ch8 ? (z80_ym1_ch_audible_live[8] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit7 ? (z80_ch0_car_sl_rr_live[7] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit6 ? (z80_ch0_car_sl_rr_live[6] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit5 ? (z80_ch0_car_sl_rr_live[5] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit4 ? (z80_ch0_car_sl_rr_live[4] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit3 ? (z80_ch0_car_sl_rr_live[3] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit2 ? (z80_ch0_car_sl_rr_live[2] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit1 ? (z80_ch0_car_sl_rr_live[1] ? 8'hFF : 8'h00) :
                          diag_box_ch0_slrr_live_bit0 ? (z80_ch0_car_sl_rr_live[0] ? 8'hFF : 8'h00) :
                          diag_box_held_ch0 ? (z80_ym1_ch_keyon_held_100ms[0] ? 8'hFF : 8'h00) :
                          diag_box_held_ch1 ? (z80_ym1_ch_keyon_held_100ms[1] ? 8'hFF : 8'h00) :
                          diag_box_held_ch2 ? (z80_ym1_ch_keyon_held_100ms[2] ? 8'hFF : 8'h00) :
                          diag_box_held_ch3 ? (z80_ym1_ch_keyon_held_100ms[3] ? 8'hFF : 8'h00) :
                          diag_box_held_ch4 ? (z80_ym1_ch_keyon_held_100ms[4] ? 8'hFF : 8'h00) :
                          diag_box_held_ch5 ? (z80_ym1_ch_keyon_held_100ms[5] ? 8'hFF : 8'h00) :
                          diag_box_held_ch6 ? (z80_ym1_ch_keyon_held_100ms[6] ? 8'hFF : 8'h00) :
                          diag_box_held_ch7 ? (z80_ym1_ch_keyon_held_100ms[7] ? 8'hFF : 8'h00) :
                          diag_box_held_ch8 ? (z80_ym1_ch_keyon_held_100ms[8] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit7 ? (z80_ram_8115_fade_level_live[7] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit6 ? (z80_ram_8115_fade_level_live[6] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit5 ? (z80_ram_8115_fade_level_live[5] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit4 ? (z80_ram_8115_fade_level_live[4] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit3 ? (z80_ram_8115_fade_level_live[3] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit2 ? (z80_ram_8115_fade_level_live[2] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit1 ? (z80_ram_8115_fade_level_live[1] ? 8'hFF : 8'h00) :
                          diag_box_fade_bit0 ? (z80_ram_8115_fade_level_live[0] ? 8'hFF : 8'h00) :
                          diag_box_fade_active ? (z80_ram_8116_fade_active_live ? 8'hFF : 8'h00) :
                          diag_box_audio_alloff_live ? (z80_audio_nonzero_while_all_keyoff_live ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_written ? (z80_stuck_channel_sl_rr_was_written ? 8'hFF : 8'h00) :
                          diag_box_ch4_expkc_nz ? ((z80_ch4_reg_b4_expected_keycode != 4'b0000) ? 8'hFF : 8'h00) :
                          diag_box_ch4_expksr ? (z80_ch4_reg_2c_expected_ksr ? 8'hFF : 8'h00) :
                          diag_box_ch4_b4written ? (z80_ch4_reg_b4_written_ever ? 8'hFF : 8'h00) :
                          diag_box_ch4_2cwritten ? (z80_ch4_reg_2c_written_ever ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit7 ? (z80_stuck_audio_duration_100ms[7] ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit6 ? (z80_stuck_audio_duration_100ms[6] ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit5 ? (z80_stuck_audio_duration_100ms[5] ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit4 ? (z80_stuck_audio_duration_100ms[4] ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit3 ? (z80_stuck_audio_duration_100ms[3] ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit2 ? (z80_stuck_audio_duration_100ms[2] ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit1 ? (z80_stuck_audio_duration_100ms[1] ? 8'hFF : 8'h00) :
                          diag_box_stuckdur_bit0 ? (z80_stuck_audio_duration_100ms[0] ? 8'hFF : 8'h00) :
                          diag_box_stuck_confirmed ? (z80_stuck_envelope_confirmed_ever ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit7 ? (z80_stuck_channel_sl_rr_snapshot[7] ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit6 ? (z80_stuck_channel_sl_rr_snapshot[6] ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit5 ? (z80_stuck_channel_sl_rr_snapshot[5] ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit4 ? (z80_stuck_channel_sl_rr_snapshot[4] ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit3 ? (z80_stuck_channel_sl_rr_snapshot[3] ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit2 ? (z80_stuck_channel_sl_rr_snapshot[2] ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit1 ? (z80_stuck_channel_sl_rr_snapshot[1] ? 8'hFF : 8'h00) :
                          diag_box_stuckch_sl_rr_bit0 ? (z80_stuck_channel_sl_rr_snapshot[0] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch0 ? (z80_ym2_ch_key_on_state[0] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch1 ? (z80_ym2_ch_key_on_state[1] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch2 ? (z80_ym2_ch_key_on_state[2] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch3 ? (z80_ym2_ch_key_on_state[3] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch4 ? (z80_ym2_ch_key_on_state[4] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch5 ? (z80_ym2_ch_key_on_state[5] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch6 ? (z80_ym2_ch_key_on_state[6] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch7 ? (z80_ym2_ch_key_on_state[7] ? 8'hFF : 8'h00) :
                          diag_box_ym2_keyon_ch8 ? (z80_ym2_ch_key_on_state[8] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch0 ? (z80_ym2_ch_audible_live[0] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch1 ? (z80_ym2_ch_audible_live[1] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch2 ? (z80_ym2_ch_audible_live[2] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch3 ? (z80_ym2_ch_audible_live[3] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch4 ? (z80_ym2_ch_audible_live[4] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch5 ? (z80_ym2_ch_audible_live[5] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch6 ? (z80_ym2_ch_audible_live[6] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch7 ? (z80_ym2_ch_audible_live[7] ? 8'hFF : 8'h00) :
                          diag_box_ym2_audible_ch8 ? (z80_ym2_ch_audible_live[8] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit7 ? (sound_latch[7] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit6 ? (sound_latch[6] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit5 ? (sound_latch[5] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit4 ? (sound_latch[4] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit3 ? (sound_latch[3] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit2 ? (sound_latch[2] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit1 ? (sound_latch[1] ? 8'hFF : 8'h00) :
                          diag_box_soundlatch_bit0 ? (sound_latch[0] ? 8'hFF : 8'h00) :
                          diag_row_flags_on ? (diag_row_flags_bit ? 8'hFF : 8'h00) :
                          diag_row2_flags_on ? (diag_row2_flags_bit ? 8'hFF : 8'h00) : vga_g;
wire [7:0] final_vga_b = OVERLAY_HIDDEN ? vga_b : (diag_box3 || diag_byte0 || diag_byte1 || diag_byte2 || diag_byte3 || diag_box_shadow_stuck || diag_box_ym2_retrig_ch7 || diag_box_ym2_retrig_ch8 || diag_box_ym1_audible_differed || diag_box_ym1_stuckconf_ch0 || diag_box_ym1_stuckconf_ch1 || diag_box_ym1_stuckconf_ch2 || diag_box_ym1_stuckconf_ch3 || diag_box_ym1_stuckconf_ch4 || diag_box_ym1_stuckconf_ch5 || diag_box_ym1_stuckconf_ch6 || diag_box_ym1_stuckconf_ch7 || diag_box_ym1_stuckconf_ch8 || diag_box_ym2_stuckconf_ch0 || diag_box_ym2_stuckconf_ch1 || diag_box_ym2_stuckconf_ch2 || diag_box_ym2_stuckconf_ch3 || diag_box_ym2_stuckconf_ch4 || diag_box_ym2_stuckconf_ch5 || diag_box_ym2_stuckconf_ch6 || diag_box_ym2_stuckconf_ch7 || diag_box_ym2_stuckconf_ch8 || diag_box_reset_after_boot || diag_box_reset_src_hw || diag_box_reset_src_status0 || diag_box_pause_cpu || diag_box_pause_cpu_ever || diag_box_reset_pulse_short || diag_box_ch7st_bit2 || diag_box_ch7st_bit1 || diag_box_ch7st_bit0 || diag_box_ch7rt_bit5 || diag_box_ch7rt_bit4 || diag_box_ch7rt_bit3 || diag_box_ch7rt_bit2 || diag_box_ch7rt_bit1 || diag_box_ch7rt_bit0 || diag_box_ch7kc_bit3 || diag_box_ch7kc_bit2 || diag_box_ch7kc_bit1 || diag_box_ch7kc_bit0 || diag_box_ch8st_bit2 || diag_box_ch8st_bit1 || diag_box_ch8st_bit0 || diag_box_ch8rt_bit5 || diag_box_ch8rt_bit4 || diag_box_ch8rt_bit3 || diag_box_ch8rt_bit2 || diag_box_ch8rt_bit1 || diag_box_ch8rt_bit0 || diag_box_ch8kc_bit3 || diag_box_ch8kc_bit2 || diag_box_ch8kc_bit1 || diag_box_ch8kc_bit0 || diag_box_keyon_ch0 || diag_box_keyon_ch1 || diag_box_keyon_ch2 || diag_box_keyon_ch3 || diag_box_keyon_ch4 || diag_box_keyon_ch5 || diag_box_keyon_ch6 || diag_box_keyon_ch7 || diag_box_keyon_ch8 || diag_box_chaudible_ch0 || diag_box_chaudible_ch1 || diag_box_chaudible_ch2 || diag_box_chaudible_ch3 || diag_box_chaudible_ch4 || diag_box_chaudible_ch5 || diag_box_chaudible_ch6 || diag_box_chaudible_ch7 || diag_box_chaudible_ch8 || diag_box_ch0_slrr_live_bit7 || diag_box_ch0_slrr_live_bit6 || diag_box_ch0_slrr_live_bit5 || diag_box_ch0_slrr_live_bit4 || diag_box_ch0_slrr_live_bit3 || diag_box_ch0_slrr_live_bit2 || diag_box_ch0_slrr_live_bit1 || diag_box_ch0_slrr_live_bit0 || diag_box_held_ch0 || diag_box_held_ch1 || diag_box_held_ch2 || diag_box_held_ch3 || diag_box_held_ch4 || diag_box_held_ch5 || diag_box_held_ch6 || diag_box_held_ch7 || diag_box_held_ch8 || diag_box_fade_bit7 || diag_box_fade_bit6 || diag_box_fade_bit5 || diag_box_fade_bit4 || diag_box_fade_bit3 || diag_box_fade_bit2 || diag_box_fade_bit1 || diag_box_fade_bit0 || diag_box_fade_active || diag_box_audio_alloff_live || diag_box_stuckch_sl_rr_written || diag_box_stuckdur_bit7 || diag_box_stuckdur_bit6 || diag_box_stuckdur_bit5 || diag_box_stuckdur_bit4 || diag_box_stuckdur_bit3 || diag_box_stuckdur_bit2 || diag_box_stuckdur_bit1 || diag_box_stuckdur_bit0 || diag_box_stuck_confirmed || diag_box_stuckch_sl_rr_bit7 || diag_box_stuckch_sl_rr_bit6 || diag_box_stuckch_sl_rr_bit5 || diag_box_stuckch_sl_rr_bit4 || diag_box_stuckch_sl_rr_bit3 || diag_box_stuckch_sl_rr_bit2 || diag_box_stuckch_sl_rr_bit1 || diag_box_stuckch_sl_rr_bit0 || diag_box_ch4_expkc_nz || diag_box_ch4_expksr || diag_box_ch4_b4written || diag_box_ch4_2cwritten || diag_box_ym2_keyon_ch0 || diag_box_ym2_keyon_ch1 || diag_box_ym2_keyon_ch2 || diag_box_ym2_keyon_ch3 || diag_box_ym2_keyon_ch4 || diag_box_ym2_keyon_ch5 || diag_box_ym2_keyon_ch6 || diag_box_ym2_keyon_ch7 || diag_box_ym2_keyon_ch8 || diag_box_ym2_audible_ch0 || diag_box_ym2_audible_ch1 || diag_box_ym2_audible_ch2 || diag_box_ym2_audible_ch3 || diag_box_ym2_audible_ch4 || diag_box_ym2_audible_ch5 || diag_box_ym2_audible_ch6 || diag_box_ym2_audible_ch7 || diag_box_ym2_audible_ch8 || diag_box_soundlatch_bit7 || diag_box_soundlatch_bit6 || diag_box_soundlatch_bit5 || diag_box_soundlatch_bit4 || diag_box_soundlatch_bit3 || diag_box_soundlatch_bit2 || diag_box_soundlatch_bit1 || diag_box_soundlatch_bit0 || diag_row_flags_on || diag_row2_flags_on) ? 8'h00 : vga_b;

arcade_video #(256, 24) arcade_video (
    .clk_video(clk_sys),
    .ce_pix(ce_pix),
    .RGB_in({final_vga_r, final_vga_g, final_vga_b}),
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
    .fx(3'b000), // No "Scanlines" CONF_STR entry exists; was reading unrelated Mode/Continues/Coin1 bits
    .forced_scandoubler(0),
    .gamma_bus(gamma_bus)
);

  reg [23:0] cpu_heartbeat;
  always @(posedge clk_sys) begin
      if (ce_pix) cpu_heartbeat <= cpu_heartbeat + 1'd1;
  end

  assign LED_USER  = cpu_heartbeat[18]; // Blinks if CPU is running
  assign LED_POWER = 0;
  // SDRAM DIAGNOSTIC LEDs:
  // LED_DISK[0] = blinks if SDRAM requests are being issued (req_count > 0)
  // LED_DISK[1] = blinks if SDRAM ready responses arrive (ready_count > 0)
  // Both ON = handshake works. Only [0] ON = state machine stalls in state 14.
  assign LED_DISK  = {sprite_diag_ready_count[8], sprite_diag_req_count[8]};

endmodule
