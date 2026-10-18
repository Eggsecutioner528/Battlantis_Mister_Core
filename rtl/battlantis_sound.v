//============================================================================
//  Battlantis audio subsystem (basic core): Z80 + 2x YM3812 (jtopl2)
//
//  Same behaviour as the long diagnostic version this replaces (rtl/rackemup_sound.v, kept in the repo history): MAME battlnts.cpp sound map
//    0x0000-0x7fff ROM, 0x8000-0x87ff RAM, 0xa000-0xa001 YM3812 #1, 0xc000-0xc001 YM3812 #2, 0xe000 sound latch read
//  Z80 at 24 MHz / 6 = 4 MHz (ce_z80), both YM3812 at 24 MHz / 8 = 3 MHz (ce_ym3812). The main CPU's write to 0x2e18 raises the Z80 interrupt
//  (IM 1), cleared on the interrupt acknowledge; the two chips' IRQ lines are wired to the Z80 NMI.
//============================================================================
module battlantis_sound (
    input         clk,
    input         rst,
    input         ce_z80,
    input         ce_ym3812,
    input   [7:0] snd_latch,
    input         snd_irq,
    input  [14:0] ioctl_sound_addr,
    input   [7:0] ioctl_sound_data,
    input         ioctl_sound_we,
    input   [4:0] vol1,        // Sound Settings: level of each chip, 0 = 100% ... 16 = off
    input   [4:0] vol2,
    input         stereo,      // Sound Settings: chip 1 left, chip 2 right
    output signed [15:0] audio_l,
    output signed [15:0] audio_r,
    output        irq_ack
);
    wire [15:0] z80_addr;
    wire  [7:0] z80_dout;
    reg   [7:0] z80_din;
    wire        n_mreq, n_iorq, n_rd, n_wr, n_m1, n_rfsh, n_halt;
    reg         n_int;

    assign irq_ack = !n_m1 && !n_iorq;
    always @(posedge clk or posedge rst) begin
        if (rst)             n_int <= 1'b1;
        else if (snd_irq)    n_int <= 1'b0;   // main CPU write to 0x2e18
        else if (irq_ack)    n_int <= 1'b1;   // Z80 interrupt acknowledge
    end

    wire mem_acc  = !n_mreq && n_rfsh;
    wire rom_cs   = mem_acc && (z80_addr <  16'h8000);
    wire ram_cs   = mem_acc && (z80_addr >= 16'h8000 && z80_addr < 16'h8800);
    wire ym1_cs   = mem_acc && (z80_addr >= 16'hA000 && z80_addr <= 16'hA001);
    wire ym2_cs   = mem_acc && (z80_addr >= 16'hC000 && z80_addr <= 16'hC001);
    wire latch_cs = mem_acc && (z80_addr == 16'hE000);

    // Sound ROM (32 KB, loaded from the ROM download at ioctl 0x18000) and RAM (2 KB), registered reads like the altsyncram blocks they replace
    (* ramstyle = "M10K" *) reg [7:0] rom [0:32767];
    reg [7:0] rom_dout;
    always @(posedge clk) begin
        if (ioctl_sound_we) rom[ioctl_sound_addr] <= ioctl_sound_data;
        rom_dout <= rom[z80_addr[14:0]];
    end
    (* ramstyle = "M10K" *) reg [7:0] ram [0:2047];
    reg [7:0] ram_dout;
    wire ram_we = mem_acc && !n_wr && ram_cs;
    always @(posedge clk) begin
        if (ram_we) ram[z80_addr[10:0]] <= z80_dout;
        ram_dout <= ram[z80_addr[10:0]];
    end

    wire [7:0] ym1_dout, ym2_dout;
    wire ym1_irq_n, ym2_irq_n;
    wire signed [15:0] ym1_snd, ym2_snd;

    jtopl2 u_ym3812_1 (
        .rst(rst), .clk(clk), .cen(ce_ym3812),
        .din(z80_dout), .addr(z80_addr[0]), .cs_n(!ym1_cs), .wr_n(n_wr),
        .dout(ym1_dout), .irq_n(ym1_irq_n), .snd(ym1_snd), .sample()
    );
    jtopl2 u_ym3812_2 (
        .rst(rst), .clk(clk), .cen(ce_ym3812),
        .din(z80_dout), .addr(z80_addr[0]), .cs_n(!ym2_cs), .wr_n(n_wr),
        .dout(ym2_dout), .irq_n(ym2_irq_n), .snd(ym2_snd), .sample()
    );

    always @(*) begin
        case (1'b1)
            rom_cs:   z80_din = rom_dout;
            ram_cs:   z80_din = ram_dout;
            ym1_cs:   z80_din = ym1_dout;
            ym2_cs:   z80_din = ym2_dout;
            latch_cs: z80_din = snd_latch;
            default:  z80_din = 8'hFF;
        endcase
    end

    cpu_z80 u_z80 (
        .nRESET(~rst), .clk(clk), .clken(ce_z80),
        .Z80_DIN(z80_din), .Z80_DOUT(z80_dout), .Z80_ADDR(z80_addr),
        .nIORQ(n_iorq), .nMREQ(n_mreq), .nRFSH(n_rfsh), .nRD(n_rd), .nWR(n_wr),
        .nINT(n_int), .nNMI(ym1_irq_n & ym2_irq_n), .nWAIT(1'b1),
        .nHALT(n_halt), .nM1(n_m1), .z80_a(), .z80_f_z()
    );

    // Mix of the two chips: rounded average, identical on both outputs, unless the Sound Settings page changes the levels or splits them left and
    // right (rtl/snd_mixer.v; at its defaults it is bit for bit the old mix).
    snd_mixer snd_mixer (.ym1(ym1_snd), .ym2(ym2_snd), .vol1(vol1), .vol2(vol2), .stereo(stereo), .audio_l(audio_l), .audio_r(audio_r));
endmodule
