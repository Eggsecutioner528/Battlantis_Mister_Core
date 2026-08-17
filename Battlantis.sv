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
    "O[30],Debug: Pause CPU,Off,On;",
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
    reg       probe1_ok = 1'b0;
    reg       probe2_ok = 1'b0;
    // Contention correlation (2026-08-12, Test 178): both probe boxes came
    // back RED in Test 177, ruling out k007420's own state machine as the
    // sole cause -- this narrows WHY by tracking, for each individual probe
    // request, whether k007420 had any Port 3 activity (sprite_sdram_req or
    // sprite_sdram_ready pulsing) at any point during that exact request's
    // pending window. probeN_fail_while_idle is a sticky latch that only
    // sets if a probe MISMATCH is ever observed while Port 3 was confirmed
    // completely idle the whole time -- if these stay GREEN (never set) while
    // the plain probeN_ok boxes keep going red, that conclusively proves the
    // failures only happen under genuine arbiter contention, not from a pure
    // electrical/address-marginality issue that would fail regardless of
    // Port 3's activity.
    reg       probe_contended = 0;
    reg       probe1_fail_while_idle = 1'b0;
    reg       probe2_fail_while_idle = 1'b0;
    always @(posedge clk_sys) begin
        if (sys_reset) begin
            probe_state <= 0;
            probe_req   <= 0;
            probe_which <= 0;
            probe1_ok   <= 1'b0;
            probe2_ok   <= 1'b0;
            probe_contended <= 0;
            probe1_fail_while_idle <= 1'b0;
            probe2_fail_while_idle <= 1'b0;
        end else begin
            if (probe_state != 0 && (sprite_sdram_req || sprite_sdram_ready)) probe_contended <= 1'b1;
            case (probe_state)
                0: begin
                    if (test_done && verify_done) begin
                        probe_addr  <= probe_which ? 25'h3F498 : 25'h3BC62;
                        probe_contended <= 1'b0;
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
                            probe2_ok <= (cpu_sdram_dout_raw == 8'h90);
                            if (cpu_sdram_dout_raw != 8'h90 && !probe_contended) probe2_fail_while_idle <= 1'b1;
                        end else begin
                            probe1_ok <= (cpu_sdram_dout_raw == 8'h56);
                            if (cpu_sdram_dout_raw != 8'h56 && !probe_contended) probe1_fail_while_idle <= 1'b1;
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
reg verify_ok = 1'b0;

always @(posedge clk_sys) begin
    if (reset) begin
        verify_state <= 0;
        verify_req   <= 0;
        verify_done  <= 0;
        verify_ok    <= 1'b0;
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
                        verify_ok    <= ((verify_xor_checksum ^ sprite_sdram_dout) == download_xor_checksum);
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
    .p2_req(tile_sdram_req),
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
wire ce_cpu = (clk_12m && cpu_clk_div == 2'b00);
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
wire pause_cpu = status[30];

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
    .nHALT(~pause_cpu)
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
            v_cnt <= (v_cnt == 261) ? 0 : v_cnt + 1;
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
wire sprite_wrap_y;

// irq_ack: K007342 internal IRQ flag is cleared when CPU acknowledges the interrupt.
// The 6809 does this by reading the interrupt vector (0xFFF8-0xFFFF during IRQ service).
wire k007342_irq_ack = cpu_e & cpu_rw & (cpu_addr >= 16'hFFF8);

k007342 k007342_inst (
    .clk(clk_sys),
    .reset(reset),
    
    .vblank(vblank),
    .int_enabled(k007342_int_enabled),
    .sprite_wrap_y(sprite_wrap_y),
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
reg k051937_sprite_enable; // Sprite RAM enable flag at 0x2400

wire k007420_we = cpu_rw == 1'b0 && (cpu_addr >= 16'h2000 && cpu_addr <= 16'h21FF);
wire k007420_re = cpu_rw == 1'b1 && (cpu_addr >= 16'h2000 && cpu_addr <= 16'h21FF);



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
    
    .ioctl_wr(ioctl_download & ioctl_wr),
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
    .has_non_zero_rom_out(sprite_has_non_zero_rom),
    .has_ever_ready_out(sprite_has_ever_ready),
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

// DSW3: bit 0: Coin1, bit 1: Coin2, bit 2: Test/Service (momentary button,
// separate from the bit 7 Service Mode DIP below -- KONAMI8_SYSTEM_10's
// standard layout per battlnts_mame.cpp's own "coinsw, testsw, startsw"
// comment on the DSW3 port-read), bit 3: Start1, bit 4: Start2.
// Bit 2 was previously hardcoded inactive (tied high via 2'b11 alongside
// coin2), meaning there was no way to advance past service mode's initial
// screen (e.g. a monitor alignment/geometry pattern) once the Mode DIP
// below put the board into test mode on reset -- confirmed via user report
// of the board reaching that screen and going no further. joystick_0[6] was
// unused by every other input on this core (0,1,2,3,4,5,7 all taken), so
// it's repurposed here as the physical Test/Service button.
wire m_coin1  = joystick_0[5] | joystick_1[5]; // Usually Select/Coin
wire m_start1 = joystick_0[7];
wire m_start2 = joystick_1[7];
wire m_test   = joystick_0[6];
wire flip_opt = status[13]; // 0=Off (0x20), 1=On (0x00)
wire ctrl_opt = status[14]; // 0=Single (0x40), 1=Dual (0x00)
wire test_opt = status[15]; // 0=Game (0x00), 1=Test (0x80)
wire cont_opt = status[16]; // 0=5 Times (0x00, factory default per manual/MAME), 1=3 Times (0x80)
wire [7:0] dip_switch_3 = (status[16:0] == 17'd0) ? {1'b1, 2'b11, ~m_start2, ~m_start1, 1'b1, ~m_test, ~m_coin1} : {~test_opt, ~ctrl_opt, ~flip_opt, ~m_start2, ~m_start1, 1'b1, ~m_test, ~m_coin1};

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

// HD6309 native-mode (SETMD) detector TEMPORARILY DISABLED (2026-08-16)
// for boot-hang bisection (task #15) -- see git history / debugging_log.md
// entry 22 for the full original reasoning, and task #15 for restoring it
// once the hang is isolated. setmd_seen kept as a constant so
// diag_box_setmd_seen's reference below doesn't need touching.
wire setmd_seen = 1'b0;

// K007342 IRQ delivery sticky check (2026-08-16, boot-hang investigation)
// -- reuses the same box slot/format as the (temporarily disabled) SETMD
// detector above. Tests whether k007342_irq (wired to the CPU's nIRQ pin)
// EVER pulses high since reset, given the CPU appears to be halted with
// K007342's int_enabled=1 but irq observed low on every live sample so
// far (Gemini-assisted read: consistent with the CPU legitimately parked
// in a SYNC/CWAI wait-for-interrupt state that's never being woken).
reg irq_ever_fired;
always @(posedge clk_sys) begin
    if (reset) irq_ever_fired <= 1'b0;
    else if (k007342_irq) irq_ever_fired <= 1'b1;
end

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

battlantis_sound battlantis_sound (
    .clk(clk_sys),
    .rst(reset),
    .ce_z80(ce_z80),
    .ce_ym3812(ce_ym3812),
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
wire diag_row2_v = (v_cnt >= 36) && (v_cnt < 52);
wire diag_byte0 = test_done && (h_cnt >= 0  && h_cnt < 16) && diag_row2_v;
wire diag_byte1 = test_done && (h_cnt >= 20 && h_cnt < 36) && diag_row2_v;
wire diag_byte2 = test_done && (h_cnt >= 40 && h_cnt < 56) && diag_row2_v;
wire diag_byte3 = test_done && (h_cnt >= 60 && h_cnt < 76) && diag_row2_v;
wire diag_box_shadow_stuck = test_done && verify_done && (h_cnt >= 100 && h_cnt < 116) && diag_row2_v;
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
wire diag_box_zoom_wrap_hit = test_done && verify_done && (h_cnt >= 120 && h_cnt < 136) && diag_row2_v;
wire diag_box_setmd_seen = test_done && verify_done && (h_cnt >= 140 && h_cnt < 156) && diag_row2_v; // now shows irq_ever_fired, see mux below
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

wire [7:0] final_vga_r = diag_box3 ? (test_success ? 8'h00 : 8'hFF) :
                          diag_byte0 ? (byte_ok[0] ? 8'h00 : 8'hFF) :
                          diag_byte1 ? (byte_ok[1] ? 8'h00 : 8'hFF) :
                          diag_byte2 ? (byte_ok[2] ? 8'h00 : 8'hFF) :
                          diag_byte3 ? (byte_ok[3] ? 8'h00 : 8'hFF) :
                          diag_box_shadow_stuck ? (shadow_currently_stuck ? 8'hFF : 8'h00) :
                          diag_box_zoom_wrap_hit ? (sprite_zoom_wrap_hit ? 8'hFF : 8'h00) :
                          diag_box_setmd_seen ? (irq_ever_fired ? 8'h00 : 8'hFF) : // RED = IRQ never fired (bad)
                          diag_row_flags_on ? (diag_row_flags_bit ? 8'h00 : 8'hFF) :
                          diag_row2_flags_on ? (diag_row2_flags_bit ? 8'h00 : 8'hFF) : vga_r;
wire [7:0] final_vga_g = diag_box3 ? (test_success ? 8'hFF : 8'h00) :
                          diag_byte0 ? (byte_ok[0] ? 8'hFF : 8'h00) :
                          diag_byte1 ? (byte_ok[1] ? 8'hFF : 8'h00) :
                          diag_byte2 ? (byte_ok[2] ? 8'hFF : 8'h00) :
                          diag_byte3 ? (byte_ok[3] ? 8'hFF : 8'h00) :
                          diag_box_shadow_stuck ? (shadow_currently_stuck ? 8'h00 : 8'hFF) :
                          diag_box_zoom_wrap_hit ? (sprite_zoom_wrap_hit ? 8'h00 : 8'hFF) :
                          diag_box_setmd_seen ? (irq_ever_fired ? 8'hFF : 8'h00) : // GREEN = IRQ has fired (good)
                          diag_row_flags_on ? (diag_row_flags_bit ? 8'hFF : 8'h00) :
                          diag_row2_flags_on ? (diag_row2_flags_bit ? 8'hFF : 8'h00) : vga_g;
wire [7:0] final_vga_b = (diag_box3 || diag_byte0 || diag_byte1 || diag_byte2 || diag_byte3 || diag_box_shadow_stuck || diag_box_zoom_wrap_hit || diag_box_setmd_seen || diag_row_flags_on || diag_row2_flags_on) ? 8'h00 : vga_b;

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
