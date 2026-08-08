//============================================================================
//  Battlantis Audio Subsystem
//  Z80 CPU @ 3.579 MHz + 2x YM3812 (OPL2) FM Synthesisers
//============================================================================

module battlantis_sound (
	input         clk,          // System Clock (e.g. 24 MHz or 48 MHz)
	input         rst,          // System Reset
	input         ce_z80,       // Z80 Clock Enable (3.579545 MHz)
	
	// Communication with Main 6809 CPU
	input   [7:0] snd_latch,    // Sound command latch byte (from 0x2E14 write)
	input         snd_irq,      // Sound IRQ trigger pulse (from 0x2E18 write)
	
	// Sound ROM loading interface (IOCTL: 0x18000 - 0x1FFFF)
	input  [14:0] ioctl_sound_addr,
	input   [7:0] ioctl_sound_data,
	input         ioctl_sound_we,
	
	// Audio Output
	output signed [15:0] audio_l,
	output signed [15:0] audio_r
);

	//------------------------------------------------------------------------
	// Z80 Signals
	//------------------------------------------------------------------------
	wire [15:0] z80_addr;
	wire  [7:0] z80_dout;
	reg   [7:0] z80_din;
	wire        n_mreq, n_iorq, n_rd, n_wr, n_m1, n_rfsh;
	
	// Sound Interrupt Flip-Flop
	reg  n_int;
	wire irq_ack = !n_m1 && !n_iorq;
	
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			n_int <= 1'b1;
		end else begin
			if (snd_irq)
				n_int <= 1'b0;      // Assert IRQ on main CPU write to 0x2E18
			else if (irq_ack)
				n_int <= 1'b1;      // Clear IRQ on Z80 interrupt acknowledge
		end
	end

	//------------------------------------------------------------------------
	// Memory Map Decoding (MAME battlnts_state::sound_map)
	// 0x0000 - 0x7FFF : 32KB Sound ROM
	// 0x8000 - 0x87FF : 2KB Work RAM
	// 0xA000 - 0xA001 : YM3812 #1 (OPL2 Chip 1)
	// 0xC000 - 0xC001 : YM3812 #2 (OPL2 Chip 2)
	// 0xE000 - 0xE000 : Sound Latch Read
	//------------------------------------------------------------------------
	wire mem_acc = !n_mreq && n_rfsh;
	wire rom_cs  = mem_acc && (z80_addr < 16'h8000);
	wire ram_cs  = mem_acc && (z80_addr >= 16'h8000 && z80_addr < 16'h8800);
	wire ym1_cs  = mem_acc && (z80_addr >= 16'hA000 && z80_addr <= 16'hA001);
	wire ym2_cs  = mem_acc && (z80_addr >= 16'hC000 && z80_addr <= 16'hC001);
	wire latch_cs= mem_acc && (z80_addr == 16'hE000);

	//------------------------------------------------------------------------
	// 32KB Sound ROM (Dual-Port BRAM: Port A = IOCTL Write, Port B = Z80 Read)
	//------------------------------------------------------------------------
	wire [7:0] rom_dout;
	
	altsyncram #(
		.operation_mode("DUAL_PORT"),
		.width_a(8),
		.widthad_a(15),
		.width_b(8),
		.widthad_b(15)
	) sound_rom (
		.clock0(clk),
		.address_a(ioctl_sound_addr),
		.data_a(ioctl_sound_data),
		.wren_a(ioctl_sound_we),
		.clock1(clk),
		.address_b(z80_addr[14:0]),
		.q_b(rom_dout)
	);

	//------------------------------------------------------------------------
	// 2KB Sound Work RAM (Single-Port BRAM)
	//------------------------------------------------------------------------
	wire [7:0] ram_dout;
	wire ram_we = mem_acc && !n_wr && ram_cs;
	
	altsyncram #(
		.operation_mode("SINGLE_PORT"),
		.width_a(8),
		.widthad_a(11)
	) sound_ram (
		.clock0(clk),
		.address_a(z80_addr[10:0]),
		.data_a(z80_dout),
		.wren_a(ram_we),
		.q_a(ram_dout)
	);

	//------------------------------------------------------------------------
	// YM3812 #1 & #2 Registers & Data Mux
	//------------------------------------------------------------------------
	//------------------------------------------------------------------------
	// YM3812 #1 & #2 OPL2 Instances
	//------------------------------------------------------------------------
	wire [7:0] ym1_dout, ym2_dout;
	wire ym1_irq_n, ym2_irq_n;
	wire signed [15:0] ym1_snd, ym2_snd;
	
	wire ym1_cs_n = !ym1_cs;
	wire ym2_cs_n = !ym2_cs;
	wire wr_n = n_wr;

	jtopl2 u_ym3812_1 (
		.rst    ( rst           ),
		.clk    ( clk           ),
		.cen    ( ce_z80        ),
		.din    ( z80_dout      ),
		.addr   ( z80_addr[0]   ),
		.cs_n   ( ym1_cs_n      ),
		.wr_n   ( wr_n          ),
		.dout   ( ym1_dout      ),
		.irq_n  ( ym1_irq_n     ),
		.snd    ( ym1_snd       ),
		.sample (               )
	);

	jtopl2 u_ym3812_2 (
		.rst    ( rst           ),
		.clk    ( clk           ),
		.cen    ( ce_z80        ),
		.din    ( z80_dout      ),
		.addr   ( z80_addr[0]   ),
		.cs_n   ( ym2_cs_n      ),
		.wr_n   ( wr_n          ),
		.dout   ( ym2_dout      ),
		.irq_n  ( ym2_irq_n     ),
		.snd    ( ym2_snd       ),
		.sample (               )
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

	//------------------------------------------------------------------------
	// Z80 CPU Instance (T80s VHDL Wrapper)
	//------------------------------------------------------------------------
	cpu_z80 u_z80 (
		.nRESET  ( ~rst     ),
		.clk     ( clk      ),
		.clken   ( ce_z80   ),
		.Z80_DIN ( z80_din  ),
		.Z80_DOUT( z80_dout ),
		.Z80_ADDR( z80_addr ),
		.nIORQ   ( n_iorq   ),
		.nMREQ   ( n_mreq   ),
		.nRFSH   ( n_rfsh   ),
		.nRD     ( n_rd     ),
		.nWR     ( n_wr     ),
		.nINT    ( n_int    ),
		.nNMI    ( 1'b1     ),
		.nWAIT   ( 1'b1     )
	);

	// Mix both YM3812 audio outputs
	wire signed [16:0] mixed_audio_raw = $signed(ym1_snd) + $signed(ym2_snd);
	wire signed [15:0] mixed_audio = mixed_audio_raw[16:1];

	assign audio_l = mixed_audio;
	assign audio_r = mixed_audio;

endmodule
