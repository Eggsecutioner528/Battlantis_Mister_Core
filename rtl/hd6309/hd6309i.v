`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
//
// Hitachi 6309 version of Greg Miller's MC6809 core
// Project started in May 2017 by Roger Taylor
// Added to GitHub on Jan 15, 2025
//
//
// Comments from Greg's mc6809 core:
//
// The 6809 has incomplete instruction decoding.  A collection of instructions, if met, end up actually behaving like
// a binary-adjacent neighbor.  
//
// The soft core permits three different behaviors for this situation, controlled by the instantiation parameter
// ILLEGAL_INSTRUCTIONS
//
// "GHOST" - Mimic the 6809's incomplete decoding.  This is as similar to a hard 6809 as is practical.  [DEFAULT]
//
// "STOP"  - Cause the soft core to cease execution, placing $DEAD on the address bus and R/W to 'read'.  Interrupts,
//           bus control (/HALT, /DMABREQ), etc. are ignored.  The core intentionally seizes in this instance.  
//           (Frankly, this is useful when making changes to the core and you have a logic analyzer connected.)
//
// "IGNORE"- Cause the soft core to merely ignore illegal instructions.  It will consider them 1-byte instructions and
//           attempt to fetch and run an exception 1 byte later.
//
// Mod tips:
// 
// In the main state machine we can only alter _nxt signals, while reading both _nxt and the non _nxt version of the signal with same prefix.
// In the next E cycle all main signals will get their previous state's _nxt values.
//
//////////////////////////////////////////////////////////////////////////////////



module hd6309i
#(
    parameter ILLEGAL_INSTRUCTIONS="IGNORE"
) 
(

    input   [7:0]  D,
    output  [7:0]  DOut,
    output  [15:0] ADDR,
    output  RnW,
    input   E,
    input   Q,
    output  BS,
    output  BA,
    input   nIRQ,
    input   nFIRQ,
    input   nNMI,
    output  AVMA,
    output  BUSY,
    output  LIC,
    input   nHALT,
    input   nRESET,
    input   nDMABREQ
//    output  [111:0] RegData
);

reg     [7:0]  DOutput;

assign DOut = DOutput;

reg     RnWOut;         // Combinatorial     

reg     rLIC;
assign LIC = rLIC;

reg     rAVMA;
assign AVMA = rAVMA;

reg     rBUSY;
assign BUSY = rBUSY;

// Bus control
// BS    BA
//  0     0   normal (CPU running, CPU is master)
//  0     1   Interrupt Ack
//  1     0   Sync Ack
//  1     1   CPU has gone high-Z on A, D, R/W
//

assign RnW = RnWOut;


/////////////////////////////////////////////////
// Vectors
`define RESET_VECTOR        16'HFFFE
`define NMI_VECTOR          16'HFFFC
`define SWI_VECTOR          16'HFFFA
`define IRQ_VECTOR          16'HFFF8
`define FIRQ_VECTOR         16'HFFF6
`define SWI2_VECTOR         16'HFFF4
`define SWI3_VECTOR         16'HFFF2
`define Reserved_VECTOR     16'HFFF0


//////////////////////////////////////////////////////
// Latched registers
//

// The last-latched copy, can only be Read
reg	[7:0]		md;
reg	[7:0]		a;
reg	[7:0]		b;
reg	[7:0]		e;
reg	[7:0]		f;
reg	[15:0]	x;
reg	[15:0]   y;
reg	[15:0]   u;
reg	[15:0]   s;
reg	[15:0]   pc;
reg	[7:0]    dp;
reg	[7:0]    cc;
reg	[15:0]   tmp;
reg [23:0] ALUTmp;
reg [23:0] ALUTmp_nxt;
reg	[15:0]   addr;
reg	[15:0]   ea;
reg	[15:0]   v;
reg	[15:0]   z;
reg	[15:0]   zz;



// Debug ability to export register contents
//assign  RegData[7:0] = a;
//assign  RegData[15:8] = b;
//assign  RegData[31:16] = x;
//assign  RegData[47:32] = y;
//assign  RegData[63:48] = s;
//assign  RegData[79:64] = u;
//assign  RegData[87:80] = cc;
//assign  RegData[95:88] = dp;
//assign  RegData[111:96] = pc;
//


// The values as being calculated, can be Written or Read
reg [7:0]  md_nxt;
reg [7:0]  a_nxt;
reg [7:0]  b_nxt;
reg [7:0]  e_nxt;
reg [7:0]  f_nxt;
reg     [15:0]          x_nxt;
reg     [15:0]          y_nxt;
reg     [15:0]          u_nxt;
reg     [15:0]          s_nxt;
reg     [15:0]          pc_nxt;
reg     [7:0]           dp_nxt;
reg     [7:0]           cc_nxt;
reg     [15:0]          addr_nxt;
reg     [15:0]          ea_nxt;
reg     [15:0]          v_nxt;
reg     [15:0]          z_nxt;
reg     [15:0]          zz_nxt;
reg     [15:0]          tmp_nxt;
reg     [31:0]          tmp32_nxt;

reg                     BS_nxt;
reg                     BA_nxt;



// for ADDR, BS/BA, assign them to the flops
assign BS = BS_nxt;
assign BA = BA_nxt;
assign ADDR=addr_nxt;

localparam CC_E=  8'H80;
localparam CC_F=  8'H40;
localparam CC_H=  8'H20;
localparam CC_I=  8'H10;
localparam CC_N=  8'H08;
localparam CC_Z=  8'H04;
localparam CC_V=  8'H02;
localparam CC_C=  8'H01;

localparam CC_E_BIT=  3'd7;
localparam CC_F_BIT=  3'd6;
localparam CC_H_BIT=  3'd5;
localparam CC_I_BIT=  3'd4;
localparam CC_N_BIT=  3'd3;
localparam CC_Z_BIT=  3'd2;
localparam CC_V_BIT=  3'd1;
localparam CC_C_BIT=  3'd0;

// Convenience calculations
reg     [15:0] pc_p1;
reg     [15:0] pc_p2;
reg     [15:0] pc_p3;
reg     [15:0] pc_p4;
reg     [15:0] pc_p5;
reg     [15:0] s_p1;
reg     [15:0] s_m1;
reg     [15:0] u_p1;
reg     [15:0] u_m1;
reg     [15:0] addr_p1;
reg     [15:0] ea_p1;


//////////////////////////////////////////////////////
// NMI Mask
//
// NMI is supposed to be masked - despite the name - until the 6809 loads a value into S.
// Frankly, I'm cheating slightly.  If someone does a LDS #$0, it won't disable the mask.  Pretty much anything else 
// that changes the value of S from the default (which is currently $0) will clear the mask.  A reset will set the mask again.
reg     NMIMask;

// 2026-08-28, Rack 'Em Up bring-up: NMILatched's own update logic
// (`always @(negedge NMISample2 or posedge wNMIClear)`, further down)
// only ever changes value on a real falling edge of the sampled nNMI
// pin, or an explicit clear pulse -- it has no reset path of its own
// (unlike IRQLatched/FIRQLatched, which track a live sampling chain
// off a real pin and settle correctly within a few cycles regardless
// of their own starting value). Since this project's Battlantis.sv
// ties nNMI permanently high for both mc6809i and hd6309i, NMISample2
// never toggles, so that always block never runs at all: NMILatched
// is stuck forever at whatever it started as. Verilator deterministically
// zero-initializes uninitialized regs (unlike real silicon, where a
// flip-flop's post-power-on state is genuinely indeterminate), so
// without this initial value NMILatched reads as 0 ("NMI pending")
// from the first simulated cycle onward, and the CPU services a
// phantom NMI on its very first instruction-fetch check (unconditional
// per real 6809/6309 semantics -- NMI isn't gated by any CC flag).
// Confirmed this exact mechanism causes Rack 'Em Up's boot hang: the
// phantom NMI diverts PC to whatever's at $FFFA/$FFFB before the ROM's
// own code ever gets to run (in Rack 'Em Up's case, the same shared
// "catch-all" handler at $8AD8 as the other unused vectors -- unlike
// the real reset vector at $8468, which is never reached). Battlantis's
// own ROM never visibly suffers from this identical, inherited
// mc6809i/hd6309i characteristic purely by coincidence: its own NMI
// vector ($FFFA/$FFFB = $8000) happens to equal its own reset vector
// ($FFFE/$FFFF = $8000), so the same phantom redirect lands exactly
// where real execution was already headed. Only touching this
// simulation-only file (`SIM_USE_HD6309`, never synthesized for real
// hardware) -- mc6809i.v has the identical characteristic but is the
// real-hardware-proven core and is left alone.
reg     NMILatched = 1'b1;
reg     NMISample;
reg     NMISample2;
reg     NMIClear;
reg     NMIClear_nxt;
wire    wNMIClear = NMIClear;

reg     IRQLatched;

reg     IRQSample;
reg     IRQSample2;
reg     FIRQLatched;
reg     FIRQSample;
reg     FIRQSample2;
reg     HALTLatched;
reg     HALTSample;
reg     HALTSample2;
reg     DMABREQLatched;
reg     DMABREQSample;
reg     DMABREQSample2;

//localparam INTTYPE_NMI      = 3'H0 ;
//localparam INTTYPE_IRQ      = 3'H1 ;
//localparam INTTYPE_FIRQ     = 3'H2 ;
//localparam INTTYPE_SWI      = 3'H3 ;
//localparam INTTYPE_SWI2     = 3'H4 ;
//localparam INTTYPE_SWI3     = 3'H5 ;

//reg [2:0] IntType;
//reg [2:0] IntType_nxt;

//////////////////////////////////////////////////////
// Instruction Fetch Details
//
reg     InstPage2;
reg     InstPage3;
reg     InstPage2_nxt;
reg     InstPage3_nxt;

reg     [7:0]        Inst1;
reg     [7:0]        Inst2;
reg     [7:0]        Inst3; // 4-byte instructions include LBRN (16,22,hi,lo), etc.
reg     [7:0]        Inst4; // 5-byte instructions include LDQ #
reg     [7:0]        Inst1_nxt;
reg     [7:0]        Inst2_nxt;
reg     [7:0]        Inst3_nxt;
reg     [7:0]        Inst4_nxt;


// Interrupt types
typedef enum {INTTYPE_NONE, INTTYPE_NMI, INTTYPE_IRQ, INTTYPE_FIRQ, INTTYPE_SWI, INTTYPE_SWI2, INTTYPE_SWI3} interrupt_types_e;
interrupt_types_e IntType;
interrupt_types_e IntType_nxt;

// Addressing Modes
typedef enum {TYPE_INHERENT, TYPE_IMMEDIATE, TYPE_DIRECT, TYPE_RELATIVE, TYPE_INDEXED, TYPE_EXTENDED, TYPE_INVALID} addressing_modes_e;
addressing_modes_e AddrModeType;

// CPU main machine states
typedef enum {CPUSTATE_RESET, CPUSTATE_RESET0, CPUSTATE_RESET2, CPUSTATE_FETCH_I1, CPUSTATE_FETCH_I1V2, CPUSTATE_FETCH_I2,
 CPUSTATE_LBRA_OFFSETLOW, CPUSTATE_LBRA_DONTCARE, CPUSTATE_LBRA_DONTCARE2, CPUSTATE_MUL_ACTION,
 CPUSTATE_BRA_DONTCARE, CPUSTATE_BSR_DONTCARE1, CPUSTATE_BSR_DONTCARE2, CPUSTATE_BSR_RETURNLOW, CPUSTATE_BSR_RETURNHIGH,
 CPUSTATE_JSR_DONTCARE, CPUSTATE_JSR_RETLO, CPUSTATE_JSR_RETHI, CPUSTATE_EXTENDED_ADDRLO,
 CPUSTATE_TFR_DONTCARE1, CPUSTATE_TFR_DONTCARE2, CPUSTATE_TFR_DONTCARE3, CPUSTATE_TFR_DONTCARE4,
 CPUSTATE_EXG_DONTCARE1, CPUSTATE_EXG_DONTCARE2, CPUSTATE_EXG_DONTCARE3, CPUSTATE_EXG_DONTCARE4, CPUSTATE_EXG_DONTCARE5, CPUSTATE_EXG_DONTCARE6,
 CPUSTATE_ABX_DONTCARE, CPUSTATE_RTS_HI, CPUSTATE_RTS_LO, CPUSTATE_RTS_DONTCARE2,
 CPUSTATE_DIRECT_DONTCARE, CPUSTATE_EXTENDED_DONTCARE, CPUSTATE_INDEXED_BASE, CPUSTATE_IDX_DONTCARE3,
 CPUSTATE_ALU16_DONTCARE, CPUSTATE_ALU_EA, CPUSTATE_ALU_DONTCARE, CPUSTATE_ALU_WRITEBACK,
 CPUSTATE_16IMM_LO, CPUSTATE_LD16_LO, CPUSTATE_ST16_LO, CPUSTATE_ALU16_LO, CPUSTATE_IDX_OFFSET_LO, CPUSTATE_IDX_16OFFSET_LO,
 CPUSTATE_IDX_16OFF_DONTCARE0, CPUSTATE_IDX_16OFF_DONTCARE1, CPUSTATE_IDX_16OFF_DONTCARE2, CPUSTATE_IDX_16OFF_DONTCARE3,
 CPUSTATE_IDX_DOFF_DONTCARE1, CPUSTATE_IDX_DOFF_DONTCARE2, CPUSTATE_IDX_DOFF_DONTCARE3, CPUSTATE_IDX_PC16OFF_DONTCARE,
 CPUSTATE_IDX_EXTIND_LO, CPUSTATE_IDX_EXTIND_DONTCARE, CPUSTATE_INDIRECT_HI, CPUSTATE_INDIRECT_LO, CPUSTATE_INDIRECT_DONTCARE,
 CPUSTATE_PSH_DONTCARE1, CPUSTATE_PSH_DONTCARE2, CPUSTATE_PSH_DONTCARE3, CPUSTATE_PSH_ACTION,
 CPUSTATE_PUL_DONTCARE1, CPUSTATE_PUL_DONTCARE2, CPUSTATE_PUL_ACTION,
 CPUSTATE_NMI_START, CPUSTATE_IRQ_DONTCARE, CPUSTATE_IRQ_START, CPUSTATE_IRQ_DONTCARE2, CPUSTATE_IRQ_VECTOR_HI, CPUSTATE_IRQ_VECTOR_LO,
 CPUSTATE_FIRQ_START, CPUSTATE_CC_DONTCARE, CPUSTATE_SWI_START, CPUSTATE_TST_DONTCARE1, CPUSTATE_TST_DONTCARE2, CPUSTATE_DEBUG,
 CPUSTATE_16IMM_DONTCARE, CPUSTATE_HALTED, CPUSTATE_HALT_EXIT2, CPUSTATE_STOP, CPUSTATE_STOP2, CPUSTATE_STOP3,
 CPUSTATE_CWAI, CPUSTATE_CWAI_DONTCARE1, CPUSTATE_CWAI_POST, CPUSTATE_DMABREQ, CPUSTATE_DMABREQ_EXIT, CPUSTATE_SYNC, CPUSTATE_SYNC_EXIT,
 CPUSTATE_INT_DONTCARE, CPUSTATE_FPU_2,
 CPUSTATE_ST32_B2316, CPUSTATE_ST32_B1508, CPUSTATE_ST32_B0700, CPUSTATE_LD32_B2316, CPUSTATE_LD32_B1508, CPUSTATE_LD32_B0700,
 CPUSTATE_32IMM_B3116, CPUSTATE_32IMM_B1508, CPUSTATE_32IMM_B0700,
 CPUSTATE_LOAD_BIT, CPUSTATE_LDMD, CPUSTATE_LDMD_DONTCARE} state_e;

state_e CpuState;
state_e CpuState_nxt;
state_e NextState;
state_e NextState_nxt;
state_e PostIllegalState;

// Ok to enumerate as long as WhatReg8 function doesn't form reg ID directly from instruction bits
typedef enum {TARGETREG_A, TARGETREG_B, TARGETREG_E, TARGETREG_F, TARGETREG_MD} TargetRegs_e;
TargetRegs_e ALU8Reg;

// If we encounter something like an illegal addressing mode (an index mode that's illegal for instance)
// What state should we go to?
generate
if (ILLEGAL_INSTRUCTIONS=="STOP")
begin : postillegal
    assign PostIllegalState = CPUSTATE_STOP; 
end
else
begin
    assign PostIllegalState = CPUSTATE_FETCH_I1;
end
endgenerate



///////////////////////////////////////////////////////////////////////

//
// MapInstruction - Considering how the core was instantiated, this 
// will either directly return D[7:0] *or* remap values from D[7:0] 
// that relate to undefined instructions in the 6809 to the instructions
// that the 6809 actually executed when these were encountered, due to
// incomplete decoding.
//
// NEG, COM, LSR, DEC - these four instructions, in Direct, Inherent (A or B)
// Indexed, or Extended addressing do not actually decode bit 0 on the instruction.
// Thus, for instance, a $51 encountered will be executed as a $50, which is a NEGB.
//

// Specifically, the input is an instruction; if it matches an unknown instruction that the 
// 6809 is known to ghost to another instruction, the output of the function 
// is the the instruction that actually gets executed.  Otherwise, the output is the 
// input.
// In 6309 and F09 we don't remap any instructions, so this process isn't effective
//function [7:0] MapInstruction(input [7:0] i);
//reg [3:0] topnyb;
//reg [3:0] btmnyb;
//reg [7:0] newinst;
//begin
//    newinst = i;
//    
//    topnyb = i[7:4];
//    btmnyb = i[3:0];
//    
//    if ( (topnyb == 4'H0) || 
//         (topnyb == 4'H4) || 
//         (topnyb == 4'H5) || 
//         (topnyb == 4'H6) ||
//         (topnyb == 4'H7) 
//        )
//    begin
//        if (btmnyb == 4'H1)
//            newinst = {topnyb, 4'H0};
//        if (btmnyb == 4'H2)
//            newinst = {topnyb, 4'H3};
//        if (btmnyb == 4'H5)
//            newinst = {topnyb, 4'H4};
//        if (btmnyb == 4'HB)
//            newinst = {topnyb, 4'HA};
//    end
//    MapInstruction = newinst;
//end
//endfunction


wire [7:0] MappedInstruction;
assign MappedInstruction = D;

//generate
//if (ILLEGAL_INSTRUCTIONS=="GHOST")
//begin : ghost
//    assign MappedInstruction = MapInstruction(D);  
//end
//else
//begin
//    assign MappedInstruction = D;
//end
//endgenerate



///////////////////////////////////////////////////////////////////////

//function IllegalInstruction(input [7:0] i);
//reg [3:0] hi;
//reg [3:0] lo;
//reg       illegal;
//begin
//    illegal = 1'b0;
//    hi = i[7:4];
//    lo = i[3:0];
//    if ( (hi == 4'H0) || (hi == 4'H4) || (hi == 4'H5) || (hi == 4'H6) || (hi == 4'H7) )
//    begin
//        if ( (lo == 4'H1) || (lo == 4'H2) || (lo == 4'H5) || (lo == 4'HB) )
//            illegal = 1'b1;
//        if (lo == 4'HE)
//            if ( (hi == 4'H4) || (hi == 4'H5) )
//                illegal = 1'b1;
//    end
//    if (hi == 4'H3)
//    begin
//        if ( (lo == 4'H8) || (lo == 4'HE) )
//            illegal = 1'b1;
//    end
//    if (hi == 4'H1)
//    begin
//        if ( (lo == 4'H4) || (lo == 4'H5) || (lo == 4'H8) || (lo == 4'HB) )
//            illegal = 1'b1;
//    end
//    if ( (hi == 4'H8) || (hi == 4'HC) )
//    begin
//        if ( (lo == 4'H7) || (lo == 4'HF) )
//            illegal = 1'b1;
//        if ( lo == 4'HD )
//            if (hi == 4'HC)
//                illegal = 1'b1;
//    end
//    IllegalInstruction = 1'b0;
////    IllegalInstruction = illegal;
//end
//endfunction

wire IsIllegalInstruction;
assign IsIllegalInstruction = 1'b0; // No

//generate
//if (ILLEGAL_INSTRUCTIONS=="GHOST")
//begin : never_illegal
//    assign IsIllegalInstruction = 1'b0; 
//end
//else
//begin
//    assign IsIllegalInstruction = IllegalInstruction(Inst1);
//end
//endgenerate

wire [6:0] IllegalInstructionState;
assign IllegalInstructionState = CPUSTATE_FETCH_I1[6:0];

//generate
//if (ILLEGAL_INSTRUCTIONS=="IGNORE")
//begin : illegal_state
//    assign IllegalInstructionState = CPUSTATE_FETCH_I1;
//end
//else if (ILLEGAL_INSTRUCTIONS=="STOP")
//begin
//    assign IllegalInstructionState = CPUSTATE_STOP;
//end
//else
//begin
//    assign IllegalInstructionState = 7'd0;
//end
//endgenerate


///////////////////////////////////////////////////////////////////////


always @(negedge NMISample2 or posedge wNMIClear)
begin
    if (wNMIClear == 1)
        NMILatched <= 1;
    else if (NMIMask == 0)
        NMILatched <= 0;
    else
        NMILatched <= 1;
end

//
// The 6809 specs say that the CPU control signals are sampled on the falling edge of Q.
// It also says that the interrupts require 1 cycle of synchronization time.  
// That's vague, as it doesn't say where "1 cycle" starts or ends.  Starting from the
// falling edge of Q, the next cycle notices an assertion.  From checking a hard 6809 on
// an analyzer, what they really mean is that it's sampled on the falling edge of Q, 
// but there's a one cycle delay from the falling edge of E (0.25 clocks from the falling edge of Q
// where the signals were sampled) before it can be noticed.  
// So, SIGNALSample is the latched value at the falling edge of Q
//     SIGNALSample2 is the latched value at the falling edge of E (0.25 clocks after the line above)
//     SIGNALLatched is the latched value at the falling edge of E (1 cycle after the line above)
//
// /HALT and /DMABREQ are delayed one cycle less than interrupts.  The 6809 specs infer these details,
// but don't list the point-of-reference they're written from (for instance, they say that an interrupt requires
// a cycle for synchronization; however, it isn't clear whether that's from the falling Q to the next falling Q,
// a complete intermediate cycle, the falling E to the next falling E, etc.) - which, in the end, required an
// analyzer on the 6809 to determine how many cycles before a new instruction an interrupt (or /HALT & /DMABREQ)
// had to be asserted to be noted instead of the next instruction running start to finish.  
// 
always @(negedge Q) begin
	NMISample <= nNMI;
	IRQSample <= nIRQ;
	FIRQSample <= nFIRQ;
	HALTSample <= nHALT;
	DMABREQSample <= nDMABREQ;
	end


reg rnRESET=0; // The latched version of /RESET, useful 1 clock after it's latched
always @(negedge E) begin
	rnRESET <= nRESET;
	NMISample2 <= NMISample;
	IRQSample2 <= IRQSample;
	IRQLatched <= IRQSample2;
	FIRQSample2 <= FIRQSample;
	FIRQLatched <= FIRQSample2;
	HALTSample2 <= HALTSample;
	HALTLatched <= HALTSample2;
	DMABREQSample2 <= DMABREQSample;
	DMABREQLatched <= DMABREQSample2;

    if (rnRESET == 1) begin
        CpuState <= CpuState_nxt;
        
        // Don't interpret this next item as "The Next State"; it's a special case 'after this 
        // generic state, go to this programmable state', so that a single state 
        // can be shared for many tasks. [Specifically, the stack push/pull code, which is used
        // for PSH, PUL, Interrupts, RTI, etc.
        NextState <= NextState_nxt;

        // CPU registers latch from the combinatorial circuit
		  md <= md_nxt;
        a <= a_nxt;
        b <= b_nxt;
        e <= e_nxt;
        f <= f_nxt;
        x <= x_nxt;
        y <= y_nxt;
        s <= s_nxt;
        u <= u_nxt;
        v <= v_nxt;
        z <= z_nxt;
        zz <= zz_nxt;
        cc <= cc_nxt;
        dp <= dp_nxt;
        pc <= pc_nxt;
        tmp <= tmp_nxt;
        ALUTmp <= ALUTmp_nxt;
        addr <= addr_nxt;
        ea <= ea_nxt;
        fpislots <= fpislots_nxt;
		  
        InstPage2 <= InstPage2_nxt;
        InstPage3 <= InstPage3_nxt;
        Inst1 <= Inst1_nxt;
        Inst2 <= Inst2_nxt;
        Inst3 <= Inst3_nxt;
        NMIClear <= NMIClear_nxt;
        
        IntType <= IntType_nxt;

        
        if (s != s_nxt)                 // Once S changes at all (default is '0'), release the NMI Mask.
            NMIMask <= 1'b0;
    end
    else begin
		CpuState <= CPUSTATE_RESET; 
		NMIMask <= 1'b1; // Mask NMI until S is loaded.
		NMIClear <= 1'b0; // Mark us as not having serviced NMI
		end
end




//
//localparam TYPE_INHERENT   =  3'd0;
//localparam TYPE_IMMEDIATE  =  3'd1;
//localparam TYPE_DIRECT     =  3'd2;
//localparam TYPE_RELATIVE   =  3'd3;
//localparam TYPE_INDEXED    =  3'd4;
//localparam TYPE_EXTENDED   =  3'd5;
//
//localparam TYPE_INVALID    =  3'd7;

////////////////////////////////////////////////////////////

// Function to decode the addressing mode the instruction uses
//
// Decode 
// 00-0F = DIRECT
// 10-1F = INHERENT, RELATIVE, IMMEDIATE
// 20-2F = RELATIVE
// 30-3F = INDEXED, IMMEDIATE (pus, pul), INHERENT
// 40-4F = INHERENT
// 50-5F = INHERENT
// 60-6F = INDEXED
// 70-7F = EXTENDED
// 80-8F = IMMEDIATE, RELATIVE (BSR)
// 90-9F = DIRECT
// A0-AF = INDEXED
// B0-BF = EXTENDED
// C0-CF = IMMEDIATE
// D0-DF = DIRECT
// E0-EF = INDEXED
// F0-FF = EXTENDED

// DIRECT; 00-0F, 90-9F, D0-DF
// INHERENT; 10-1F (12, 13, 19, 1D), 30-3F (39-3F), 40-4F, 50-5F, 
// RELATIVE: 10-1F (16, 17), 20-2F, 80-8F (8D)
// IMMEDIATE: 10-1F (1A, 1C, 1E, 1F), 30-3F (34-37), 80-8F (80-8C, 8E), C0-CF
// INDEXED: 60-6F, A0-AF, E0-EF
// EXTENDED: 70-7F, B0-Bf, F0-FF

function addressing_modes_e addressing_mode_type(input   [7:0] inst);
begin
    casex (inst)
    8'b0000???? :                 addressing_mode_type   =  TYPE_DIRECT;
    8'b0001???? : begin
        casex (inst[3:0])
        4'b0010:
            addressing_mode_type   =  TYPE_INHERENT; // $12 NOP
        
        4'b0011:
            addressing_mode_type   =  TYPE_INHERENT; // $13 SYNC
        
        4'b1001:
            addressing_mode_type   =  TYPE_INHERENT; //  
        
        4'b1101:
            addressing_mode_type   =  TYPE_INHERENT; // 
        
        4'b0110:
            addressing_mode_type   =  TYPE_RELATIVE; // 
        
        4'b0111:
            addressing_mode_type   =  TYPE_RELATIVE; // 
        
        4'b1010:
            addressing_mode_type   =  TYPE_IMMEDIATE; // 
        
        4'b1100:
            addressing_mode_type   =  TYPE_IMMEDIATE;
        
        4'b1110:
            addressing_mode_type   =  TYPE_IMMEDIATE;
        
        4'b1111:
            addressing_mode_type   =  TYPE_IMMEDIATE;
        
        default:
            addressing_mode_type   =  TYPE_INVALID;
        endcase
		end
    8'b0010????:                     addressing_mode_type   =  TYPE_RELATIVE;
    8'b0011????: begin
        casex(inst[3:0])
        4'b00??:
            addressing_mode_type   =  TYPE_INDEXED;
        
        4'b01??: // covers $1136 LDBT   $1137   during SpecialImmediate check
            addressing_mode_type   =  TYPE_IMMEDIATE;
        
        4'b10??:
				if (InstPage2)
					addressing_mode_type   =  TYPE_IMMEDIATE; // SpecialImmediate $1038, $1039, $103A, $103B  PSHSW/PULSW/PSHUW/PULUW
				else
					addressing_mode_type   =  TYPE_INHERENT;
				
        4'b1100:
            addressing_mode_type   =  TYPE_INHERENT; // <----- CWAI should be TYPE_IMMEDIATE
        
        4'b1101:
				if (InstPage3)
					addressing_mode_type   =  TYPE_IMMEDIATE;
				else
					addressing_mode_type   =  TYPE_INHERENT;
        
//			4'b1110: // $3E FPU
//					addressing_mode_type   =  TYPE_IMMEDIATE;
					
        4'b1111:
            addressing_mode_type   =  TYPE_INHERENT;
        
        default:
            addressing_mode_type   =  TYPE_INVALID;
        endcase
		end
    
    8'b010?????:					addressing_mode_type   =  TYPE_INHERENT;
			
    8'b0110????:                addressing_mode_type   =  TYPE_INDEXED;
    
    8'b0111????:                addressing_mode_type   =  TYPE_EXTENDED;
    
    8'b1000????: begin
        casex (inst[3:0])
        4'b0111:                addressing_mode_type   =  TYPE_INVALID;
        4'b1111:                addressing_mode_type   =  TYPE_INVALID;
        4'b1101:                addressing_mode_type   =  TYPE_RELATIVE;
        default:                addressing_mode_type   =  TYPE_IMMEDIATE;
        endcase
		end
    
    8'b1001????:                addressing_mode_type   =  TYPE_DIRECT;
    8'b1010????:                addressing_mode_type   =  TYPE_INDEXED;
    8'b1011????:                addressing_mode_type   =  TYPE_EXTENDED;
    8'b1100????:                addressing_mode_type   =  TYPE_IMMEDIATE;
    8'b1101????:                addressing_mode_type   =  TYPE_DIRECT;
    8'b1110????:                addressing_mode_type   =  TYPE_INDEXED;
    8'b1111????:                addressing_mode_type   =  TYPE_EXTENDED;
    
    endcase
end
endfunction
assign  AddrModeType = addressing_mode_type(Inst1);


/////////////////////////////////////////////////////////////////
// Decode the Index byte
// Do not renumber or enumerate these constants!!
localparam IDX_REG_X   =  3'd0;
localparam IDX_REG_Y   =  3'd1;
localparam IDX_REG_U   =  3'd2;
localparam IDX_REG_S   =  3'd3;
localparam IDX_REG_PC  =  3'd4;
localparam IDX_REG_W = 3'd5;


localparam IDX_MODE_POSTINC1   =				5'd0;
localparam IDX_MODE_POSTINC2   =				5'd1;
localparam IDX_MODE_PREDEC1    =				5'd2;
localparam IDX_MODE_PREDEC2    =				5'd3;
localparam IDX_MODE_NOOFFSET   =				5'd4;
localparam IDX_MODE_B_OFFSET   =				5'd5;
localparam IDX_MODE_A_OFFSET   =				5'd6;
localparam IDX_MODE_E_OFFSET   =				5'd7;
//localparam IDX_MODE_5BIT_OFFSET=				5'd7;    // Special case, not bit pattern 7; the offset sits in the bit pattern
localparam IDX_MODE_8BIT_OFFSET=  			5'd8;
localparam IDX_MODE_16BIT_OFFSET   =  		5'd9;
localparam IDX_MODE_F_OFFSET   =				5'd10;
localparam IDX_MODE_D_OFFSET	=				5'd11;
localparam IDX_MODE_8BIT_OFFSET_PC	= 		5'd12;
localparam IDX_MODE_16BIT_OFFSET_PC	=		5'd13;
localparam IDX_MODE_W_OFFSET	=				5'd14;
localparam IDX_MODE_EXTENDED_INDIRECT	=	5'd15;
localparam IDX_MODE_5BIT_OFFSET=				5'd31;    // Special case, not bit pattern 11111; the offset sits in the bit pattern

// Return:
//     Register base [3 bits]
//     Indirect      [1 bit]
//     Mode          [4 bits]

function [8:0] IndexDecode(input   [7:0] postbyte);
reg     [2:0]  regnum;
reg     indirect;
reg     [4:0]  mode;
begin
    indirect   =  0;
    mode       =  0;
    
    if (postbyte[7] == 0) begin          // 5-bit
		mode   =  IDX_MODE_5BIT_OFFSET;
		end
    else begin
		mode   =  {1'b0, postbyte[3:0]};
		indirect   =  postbyte[4];
		end

	if ((mode == IDX_MODE_8BIT_OFFSET_PC) || (mode == IDX_MODE_16BIT_OFFSET_PC)) // ,PCR index
		regnum[2:0]    =  IDX_REG_PC;
		
	else if (postbyte == 8'b10001111) begin // ,W    [,W]
		regnum[2:0] = IDX_REG_W;
		mode = IDX_MODE_NOOFFSET;
		end
	else if (postbyte == 8'b10101111) begin // nn,W  [nn,W]
		regnum[2:0] = IDX_REG_W;
		mode = IDX_MODE_16BIT_OFFSET;
		end
	else if (postbyte == 8'b10010000) begin // ,W++  [,W++]
		regnum[2:0] = IDX_REG_W;
		mode = IDX_MODE_POSTINC2;
		end
	else if (postbyte == 8'b10110000) begin // ,--W  [,--W]
		regnum[2:0] = IDX_REG_W;
		mode = IDX_MODE_PREDEC2;
		end
	else
		regnum[2:0]    =  postbyte[6:5]; // X,Y,U,S index
	 
    IndexDecode    =  {indirect, mode, regnum};
end
endfunction
wire    [4:0]  IndexedMode;
wire    IndexedIndirect;
wire    [2:0]  IndexedRegister;
assign  {IndexedIndirect, IndexedMode, IndexedRegister}    =  IndexDecode(Inst2);


/////////////////////////////////////////////////////////////////
// Is this a JMP instruction?  (irrespective of addressing mode)
function IsJMP(input   Page2, input   Page3, input   [7:0] inst);
begin
	casex ({Page2, Page3, inst})
		10'b0000001110: // $0E (JMP)
			IsJMP = 1;
		10'b00011x1110: // $6E,$7E (JMP)
			IsJMP = 1;
		default:
			IsJMP =  0;
	endcase;
end
endfunction




//////////////////////////////////////////////////

// Individual opcodes that are the top of a column of states.
// Do not renumber or enumerate these constants!!

localparam OPCODE_INH_ABX           =  8'H3A;
localparam OPCODE_INH_RTS           =  8'H39;
localparam OPCODE_INH_RTI           =  8'H3B;
localparam OPCODE_INH_CWAI          =  8'H3C;
localparam OPCODE_INH_MUL           =  8'H3D;
localparam OPCODE_INH_SWI           =  8'H3F;
localparam OPCODE_INH_SEX           =  8'H1D;
localparam OPCODE_INH_NOP           =  8'H12;
localparam OPCODE_INH_SYNC          =  8'H13;
localparam OPCODE_INH_DAA           =  8'H19;

localparam OPCODE_IMM_ORCC          =  8'H1A;
localparam OPCODE_IMM_ANDCC         =  8'H1C;
localparam OPCODE_IMM_EXG           =  8'H1E;
localparam OPCODE_IMM_TFR           =  8'H1F;
localparam OPCODE_IMM_PSHS          =  8'H34;
localparam OPCODE_IMM_PULS          =  8'H35;

localparam OPCODE_IMM_PSHU          =  8'H36;
localparam OPCODE_IMM_LDBT				=  8'H36; // $1036 LDBT

localparam OPCODE_IMM_PULU          =  8'H37;
localparam OPCODE_IMM_STBT				=  8'H37; // $1036 LDBT

localparam OPCODE_IMM_PSHSW			=  8'H38; // $1038
localparam OPCODE_IMM_PULSW			=  8'H39; // $1039
localparam OPCODE_IMM_PSHUW			=  8'H3A; // $103A
localparam OPCODE_IMM_PULUW			=  8'H3B; // $103B

localparam OPCODE_IMM_BITMD          =  8'H3C; // $113C  4 cycles  tests bits 6,7 only, use ALU8?
localparam OPCODE_IMM_LDMD          =  8'H3D; // $113D  5 cycles  $11=1 $3D=2  $d8=3   leaves 2 cycles... use ALU8 or bypass?

localparam OPCODE_IMM_FPU          =  8'H3E; // $3E FPU

localparam OPCODE_IMM_LDQ = 8'HCD;


// Do not renumber or enumerate these constants
//They're taken directly from the EXG/TFR instruction postbyte nibbles!
localparam EXGTFR_REG_D             =  4'H0;
localparam EXGTFR_REG_X             =  4'H1;
localparam EXGTFR_REG_Y             =  4'H2;
localparam EXGTFR_REG_U             =  4'H3;
localparam EXGTFR_REG_S             =  4'H4;
localparam EXGTFR_REG_PC            =  4'H5;
localparam EXGTFR_REG_W             =  4'H6;
localparam EXGTFR_REG_V             =  4'H7;
localparam EXGTFR_REG_A             =  4'H8;
localparam EXGTFR_REG_B             =  4'H9;
localparam EXGTFR_REG_CC            =  4'HA;
localparam EXGTFR_REG_DP            =  4'HB;
localparam EXGTFR_REG_Z             =  4'HC;
localparam EXGTFR_REG_ZZ            =  4'HD;
localparam EXGTFR_REG_E             =  4'HE;
localparam EXGTFR_REG_F             =  4'HF;

localparam INST_LBRA   =  8'H16;                // always -- shitty numbering, damnit
localparam INST_LBSR   =  8'H17;                // 

localparam INST_BRA    =  8'H20;           // always
localparam INST_BRN    =  8'H21;           // never
localparam INST_BHI    =  8'H22;           // CC.Z = 0 && CC.C = 0
localparam INST_BLS    =  8'H23;           // CC.Z != 0 && CC.C != 0
localparam INST_BCC    =  8'H24;           // CC.C = 0
localparam INST_BHS    =  8'H24;           // same as BCC
localparam INST_BCS    =  8'H25;           // CC.C = 1
localparam INST_BLO    =  8'H25;           // same as BCS
localparam INST_BNE    =  8'H26;           // CC.Z = 0
localparam INST_BEQ    =  8'H27;           // CC.Z = 1
localparam INST_BVC    =  8'H28;           // V = 1
localparam INST_BVS    =  8'H29;           // V = 0
localparam INST_BPL    =  8'H2A;           // CC.N = 0
localparam INST_BMI    =  8'H2B;           // CC.N = 1
localparam INST_BGE    =  8'H2C;           // CC.N = CC.V
localparam INST_BLT    =  8'H2D;           // CC.N != CC.V
localparam INST_BGT    =  8'H2E;           // CC.N = CC.V && CC.Z = 0
localparam INST_BLE    =  8'H2F;           // CC.N != CC.V && CC.Z = 1
localparam INST_BSR    =  8'H8D;           // always

localparam NYB_BRA     =  4'H0;            // always
localparam NYB_BRN     =  4'H1;            // never
localparam NYB_BHI     =  4'H2;            // CC.Z = 0 && CC.C = 0
localparam NYB_BLS     =  4'H3;            // CC.Z != 0 && CC.C != 0
localparam NYB_BCC     =  4'H4;            // CC.C = 0
localparam NYB_BHS     =  4'H4;            // same as BCC
localparam NYB_BCS     =  4'H5;            // CC.C = 1
localparam NYB_BLO     =  4'H5;            // same as BCS
localparam NYB_BNE     =  4'H6;            // CC.Z = 0
localparam NYB_BEQ     =  4'H7;            // CC.Z = 1
localparam NYB_BVC     =  4'H8;            // V = 0
localparam NYB_BVS     =  4'H9;            // V = 1
localparam NYB_BPL     =  4'HA;            // CC.N = 0
localparam NYB_BMI     =  4'HB;            // CC.N = 1
localparam NYB_BGE     =  4'HC;            // CC.N = CC.V
localparam NYB_BLT     =  4'HD;            // CC.N != CC.V
localparam NYB_BGT     =  4'HE;            // CC.N = CC.V && CC.Z = 0
localparam NYB_BLE     =  4'HF;            // CC.N != CC.V && CC.Z = 1


function take_branch(input   [7:0] Inst1, input   [7:0] cc);
begin
    take_branch    =  0;    //default
    if ( (Inst1 == INST_BSR) || (Inst1 == INST_LBSR) || (Inst1 == INST_LBRA) )
        take_branch    =  1;
    else
        case (Inst1[3:0])
            NYB_BRA:
                take_branch    =  1;
            NYB_BRN:
                take_branch    =  0;
            NYB_BHI:
                if ( ( cc[CC_Z_BIT] | cc[CC_C_BIT] ) == 0)
                    take_branch    =  1;
            NYB_BLS:
                if ( cc[CC_Z_BIT] | cc[CC_C_BIT] )
                    take_branch    =  1;
            NYB_BCC:
                if ( cc[CC_C_BIT] == 0 )
                    take_branch    =  1;
            NYB_BCS:
                if ( cc[CC_C_BIT] == 1 )
                    take_branch    =  1;
            NYB_BNE:
                if ( cc[CC_Z_BIT] == 0 )
                    take_branch    =  1;
            NYB_BEQ:
                if ( cc[CC_Z_BIT] == 1 )
                    take_branch    =  1;
            NYB_BVC:
                if ( cc[CC_V_BIT] == 0)
                    take_branch    =  1;
            NYB_BVS:
                if ( cc[CC_V_BIT] == 1)
                    take_branch    =  1;
            NYB_BPL:
                if ( cc[CC_N_BIT] == 0 )
                    take_branch    =  1;
            NYB_BMI:
                if (cc[CC_N_BIT] == 1)
                    take_branch    =  1;
            NYB_BGE:
                if ((cc[CC_N_BIT] ^ cc[CC_V_BIT]) == 0)
                    take_branch    =  1;
            NYB_BLT:
                if ((cc[CC_N_BIT] ^ cc[CC_V_BIT]) == 1)
                    take_branch    =  1;
            NYB_BGT:
                if ( ((cc[CC_N_BIT] ^ cc[CC_V_BIT]) == 0) & (cc[CC_Z_BIT] == 0) )
                    take_branch    =  1;
            NYB_BLE:
                if ( ((cc[CC_N_BIT] ^ cc[CC_V_BIT]) == 1) | (cc[CC_Z_BIT] == 1) )
                    take_branch    =  1;
    endcase
end
endfunction

wire    TakeBranch =  take_branch(Inst1, cc);

/////////////////////////////////////////////////////////////////////
// Convenience function for knowing the contents for TFR, EXG
function [15:0] EXGTFRRegister(input [3:0] regid);
begin
        case (regid)
            EXGTFR_REG_W:
                EXGTFRRegister   =  {e, f};
            EXGTFR_REG_D:
                EXGTFRRegister   =  {a, b};
            EXGTFR_REG_X:
                EXGTFRRegister   =  x;
            EXGTFR_REG_Y:
                EXGTFRRegister   =  y;
            EXGTFR_REG_U:
                EXGTFRRegister   =  u;
            EXGTFR_REG_S:
                EXGTFRRegister   =  s;
            EXGTFR_REG_V:
                EXGTFRRegister   =  v;
            EXGTFR_REG_Z:
                EXGTFRRegister   =  z;
            EXGTFR_REG_ZZ:
                EXGTFRRegister   =  zz;
            EXGTFR_REG_PC:
                EXGTFRRegister   =  pc_p1; // For both EXG and TFR, this is used on the 2nd byte in the instruction's cycle.  The PC intended to transfer is actually the next byte.
            EXGTFR_REG_DP:
                EXGTFRRegister   =  {8'HFF, dp};
            EXGTFR_REG_A:
                EXGTFRRegister   =  {8'HFF, a};
            EXGTFR_REG_B:
                EXGTFRRegister   =  {8'HFF, b};
            EXGTFR_REG_E:
                EXGTFRRegister   =  {8'HFF, e};
            EXGTFR_REG_F:
                EXGTFRRegister   =  {8'HFF, f};
            EXGTFR_REG_CC:
                EXGTFRRegister   =  {8'HFF, cc};
            default:
                EXGTFRRegister   =  16'H0;                                       
        endcase
end
endfunction
wire [15:0] EXGTFRRegA = EXGTFRRegister(D[7:4]);
wire [15:0] EXGTFRRegB = EXGTFRRegister(D[3:0]);


/////////////////////////////////////////////////////////////////
// Is this a special Immediate mode instruction, ala
// PSH, PUL, EXG, TFR, ANDCC, ORCC, PSHSW, PULSW, PSHUW, PULSW, LDMD, BITMD
// FPU (new 64-bit math processor instruction by Roger Taylor)
function IsSpecialImm(input   Page2, input   Page3, input   [7:0] inst);
reg     is;
begin
	casex ({Page2, Page3, inst})
		10'b0000011010: // 1A (ORCC)
			is = 1;
		10'b0000011100: // 1C (ANDCC)
			is = 1;
		10'b000001111x: // 1E,1F (EXG, TFR)
			is = 1;
		10'b00001101xx: // 34,35,36,37 (PSHS,PULS,PSHU,PULU)
			is = 1;
		10'b10001110xx: // 1038,1039,103A,103B (PSHSW, PSHUW, PULSW, PULUW)
			is = 1;
		10'b010011110x: // 113C BITMD		113D LDMD   should this be Not Special, but pass through ALU?
			is = 1;
//		10'b0100111110: // 3E FPU
//			is = 1;
		default:
			is =  0;
	endcase;
	IsSpecialImm   =  is; // return 'is' to the caller
end
endfunction
wire    IsSpecialImmediate =  IsSpecialImm(InstPage2, InstPage3, Inst1);


/////////////////////////////////////////////////////////////////
// Is this a one-byte instruction?  [The 6809 reads 2 bytes for every instruction, minimum (it can read more).
// On a one-byte, we have to ensure that we haven't skipped the PC ahead.
function IsOneByteInstruction(input   [7:0] inst);
reg     is;
reg     [3:0] hi;
reg     [3:0] lo;
begin
	hi =  inst[7:4];
	lo =  inst[3:0];
	is = 1'b0;
	 
	if ( (hi == 4'H4) || (hi == 4'H5) )
		is =  1'b1;
	
	// $12 $13 $19 $1D
	else if ( hi == 4'H1) begin
		if ( (lo == 4'H2) || (lo == 4'H3) || (lo == 4'H9) || (lo == 4'HD) )
			is =  1'b1;
		end
	// $38 $39 $3A $3B $3D $3E $3F
	else if (hi == 4'H3) begin
		if ( (lo >= 4'H8) && (lo != 4'HC) )
			is =  1'b1;
		end
	
	else
		is =  1'b0;

	IsOneByteInstruction   =  is;  // return 'is' to the caller 
end
endfunction 




///////////////////////////////////////////////////////////////////
// Is this an 8-bit Store?
localparam ST8_REG_A   =  2'b00;
localparam ST8_REG_B   =  2'b01;
localparam ST8_REG_E   =  2'b10;
localparam ST8_REG_F   =  2'b11;
function [2:0] IsST8(input page2, input page3, input   [7:0] inst);
reg     [1:0] regnum;
reg     IsStore;
begin //0
    IsStore = 1'b0;
    regnum = 2'b01;
	if ( (inst == 8'H97) || (inst == 8'HA7) || (inst == 8'HB7) ) begin //1
		if (page3) begin //2
			IsStore = 1'b1;
			regnum = ST8_REG_E; // E
			end //2
		else if (~page2) begin //3
			IsStore = 1'b1;
			regnum = ST8_REG_A; // A
			end //3
		end //1
	else if ( (inst == 8'HD7) || (inst == 8'HE7) || (inst == 8'HF7) ) begin //4
		if (page3) begin //5
			IsStore = 1'b1;
			regnum = ST8_REG_F; // F
			end //5
		else if (~page2) begin //6
			IsStore = 1'b1;
			regnum = ST8_REG_B; // B
			end //6
		end //4
    IsST8  =  {IsStore, regnum}; // return {x,x} to the caller
end //0
endfunction
wire    IsStore8;
wire    [1:0] Store8RegisterNum;
assign  {IsStore8, Store8RegisterNum}  =  IsST8(InstPage2, InstPage3, Inst1);        



/////////////////////////////////////////////////////////////////
// ALU8
// Do not renumber or enumerate these constants!!
// The ops are organized from the 4 low-order bits of the instructions for the first set of ops, then 16-31 are the second set - even though bit 4 isn't representative.
localparam        ALU8OP_NEG  =  5'd0;
localparam        ALU8OP_COM  =  5'd3;
localparam        ALU8OP_LSR  =  5'd4;
localparam        ALU8OP_ROR  =  5'd6;
localparam        ALU8OP_ASR  =  5'd7;
localparam        ALU8OP_ASL  =  5'd8;
localparam        ALU8OP_ROL  =  5'd9;
localparam        ALU8OP_DEC  =  5'd10;
localparam        ALU8OP_INC  =  5'd12;
localparam        ALU8OP_TST  =  5'd13;
localparam        ALU8OP_CLR  =  5'd15;

localparam        ALU8OP_SUB  =  5'd16;
localparam        ALU8OP_CMP  =  5'd17;
localparam        ALU8OP_SBC  =  5'd18;
localparam        ALU8OP_AND  =  5'd20;
localparam        ALU8OP_BIT  =  5'd21;
localparam        ALU8OP_LD   =  5'd22;
localparam        ALU8OP_EOR  =  5'd24;
localparam        ALU8OP_ADC  =  5'd25;
localparam        ALU8OP_OR   =  5'd26;
localparam        ALU8OP_ADD  =  5'd27;
localparam ALU8OP_BIT2REG		= 5'd28;
localparam ALU8OP_REG2BIT		= 5'd29;
localparam ALU8OP_TESTMDBIT	= 5'd30;
localparam ALU8OP_INVALID		= 5'd31;

function [5:0] ALU8OpFromInst(input Page2, input Page3, input   [7:0] inst);
reg     [4:0] op;
reg     writeback;
begin
	// LDBT ($1136) and STBT ($1137) below are bit-manipulation ops (copy a
	// single bit between a register and a memory bit-field), not generic
	// single-accumulator ALU ops, so like their BITMD sibling case they
	// don't participate in the generic writeback path. Default to 0 here
	// (matching BITMD's explicit writeback=0) instead of leaving this an
	// unassigned path -- Quartus warning 10776/10242, an inferred-latch/
	// don't-care read the same class of past real bug in this file
	// (NMILatched) was caused by relying on an unspecified default value.
	writeback = 1'b0;

	 // (RT) Greg's scheme works for 6809, but 6309 inserts some nearby ALU'able instructions that yield "wrong" 6809 ALUOP8
	 // (RT) So I added the case statements and put GM's logic in the Default section
	case ({Page2, Page3, inst}) // 6309 instructions bypass GM's operation code method
		10'b0100110110: // $1136 LDBT reg,regbit,membit,addr8
			op = ALU8OP_BIT2REG;
		10'b0100110111: // $1137 STBT
			op = ALU8OP_REG2BIT;
		10'b0100111100: begin // $113C BITMD
			op = ALU8OP_TESTMDBIT;
			writeback  =  0;
			end
	default: begin // otherwise extract an ALU Op # from the instruction
		op =  {inst[7], inst[3:0]};
		case (op)
			ALU8OP_CMP:
				writeback  =  0;
			ALU8OP_TST:
				writeback  =  0;
			ALU8OP_BIT:
				writeback  =  0;
			default:
				writeback  =  1;
		endcase
		end
		
	endcase
	ALU8OpFromInst  =  {writeback, op};

end
endfunction

wire    [4:0] ALU8Op;
wire    ALU8Writeback;

assign  {ALU8Writeback, ALU8Op}    =  ALU8OpFromInst(InstPage2, InstPage3, Inst1);

reg     [7:0] ALU8_A;
reg     [7:0] ALU8_B;
reg     [7:0] ALU8_CC;
reg     [4:0] ALU8_OP;


function [15:0] ALU8Inst(input   [4:0] operation, input   [7:0] a_arg, input   [7:0] b_arg, input   [7:0] cc_arg);
reg     [7:0]    cc_out;
reg     [7:0]    ALUFn;
reg [2:0] sourcebit;
reg [2:0] destbit;
reg     carry;
reg     borrow;
begin
    cc_out =  cc_arg;
    // sourcebit/destbit/carry are each written in only one case branch
    // below and never read back by this function's own return value --
    // harmless as-is, but Quartus can't prove that and warns about an
    // inferred latch (10030/10776) without an explicit default on every
    // path. Give them one here rather than leave it unspecified.
    sourcebit = 3'b0;
    destbit   = 3'b0;
    carry     = 1'b0;
    case (operation)

			ALU8OP_BIT2REG: begin
			sourcebit = b_arg[5:3]; // 0-7
			destbit = b_arg[2:0]; // 0-7
			// This op produces its result via sourcebit/destbit (a single
			// bit copy), not a generic ALU result -- explicit 0 here
			// matches this case statement's own `default: ALUFn = 8'H00`
			// used for the other non-ALU-result ops (Quartus 10030/10776).
			ALUFn = 8'H00;
			end
	 
        ALU8OP_NEG: begin
			ALUFn[7:0]             =  ~a_arg + 1'b1;
			cc_out[CC_C_BIT]       =  (ALUFn[7:0] != 8'H00);
			cc_out[CC_V_BIT]       =  (a_arg == 8'H80);
			end

		  ALU8OP_ASL: begin
			{cc_out[CC_C_BIT], ALUFn}  =  {a_arg, 1'b0};
			cc_out[CC_V_BIT]   =  a_arg[7] ^ a_arg[6];
			end
        
        ALU8OP_LSR: begin
			{ALUFn, cc_out[CC_C_BIT]}  =  {1'b0, a_arg}; 
			end

        ALU8OP_ASR: begin
			{ALUFn, cc_out[CC_C_BIT]}  =  {a_arg[7], a_arg}; 
			end    
        
        ALU8OP_ROL: begin
			{cc_out[CC_C_BIT], ALUFn}  =  {a_arg, cc_arg[CC_C_BIT]};
			cc_out[CC_V_BIT]   =  a_arg[7] ^ a_arg[6];
			end

        ALU8OP_ROR: begin
			{ALUFn, cc_out[CC_C_BIT]}  =  {cc_arg[CC_C_BIT], a_arg}; 
			end

        ALU8OP_OR: begin
			ALUFn[7:0] =  (a_arg | b_arg);
			cc_out[CC_V_BIT]   =  1'b0;
			end

        ALU8OP_ADD: begin
			{cc_out[CC_C_BIT], ALUFn[7:0]} =  {1'b0, a_arg} + {1'b0, b_arg};
			cc_out[CC_V_BIT]   =  (a_arg[7] & b_arg[7] & ~ALUFn[7]) | (~a_arg[7] & ~b_arg[7] & ALUFn[7]);
			cc_out[CC_H_BIT]   =  a_arg[4] ^ b_arg[4] ^ ALUFn[4];
			end

        ALU8OP_SUB: begin
			{cc_out[CC_C_BIT], ALUFn[7:0]} = {1'b0, a_arg} - {1'b0, b_arg};
			cc_out[CC_V_BIT]   =   (a_arg[7] & ~b_arg[7] & ~ALUFn[7]) | (~a_arg[7] & b_arg[7] & ALUFn[7]);
			end

        ALU8OP_AND: begin
			ALUFn[7:0] =  (a_arg & b_arg);
			cc_out[CC_V_BIT]   =  1'b0;
			end

		ALU8OP_BIT: begin
			ALUFn[7:0] =  (a_arg & b_arg);
			cc_out[CC_V_BIT]   =  1'b0;
			end

		ALU8OP_TST: begin
			ALUFn[7:0] =  a_arg;
			cc_out[CC_V_BIT]   =  1'b0;
			end

		ALU8OP_EOR: begin
			ALUFn[7:0] =  (a_arg ^ b_arg);
			cc_out[CC_V_BIT]   =  1'b0;                
			end

		ALU8OP_CMP: begin
			{cc_out[CC_C_BIT], ALUFn[7:0]} = {1'b0, a_arg} - {1'b0, b_arg};
			cc_out[CC_V_BIT]   =   (a_arg[7] & ~b_arg[7] & ~ALUFn[7]) | (~a_arg[7] & b_arg[7] & ALUFn[7]);
			end

        ALU8OP_COM:
        begin
            ALUFn[7:0] =  ~a_arg;
            cc_out[CC_V_BIT]   =  1'b0;
            cc_out[CC_C_BIT]   =  1'b1;
        end
        
        ALU8OP_ADC:
        begin
            {cc_out[CC_C_BIT], ALUFn[7:0]} =  {1'b0, a_arg} + {1'b0, b_arg} + cc_arg[CC_C_BIT];
            cc_out[CC_V_BIT]   =  (a_arg[7] & b_arg[7] & ~ALUFn[7]) | (~a_arg[7] & ~b_arg[7] & ALUFn[7]);
            cc_out[CC_H_BIT]   =  a_arg[4] ^ b_arg[4] ^ ALUFn[4];
        end
 
		ALU8OP_LD: begin
			ALUFn[7:0] =  b_arg;
			cc_out[CC_V_BIT] = 1'b0;
			end

        ALU8OP_INC:
        begin
            {carry, ALUFn} =  {1'b0, a_arg} + 1'b1;
            cc_out[CC_V_BIT]   =  (~a_arg[7] & ALUFn[7]);             
        end
        
        ALU8OP_DEC:
        begin
            {carry, ALUFn[7:0]}    =  {1'b0, a_arg} - 1'b1;
            cc_out[CC_V_BIT]       =   (a_arg[7] & ~ALUFn[7]);
        end
        
        ALU8OP_CLR:
        begin
            ALUFn[7:0] =  8'H00;
            cc_out[CC_V_BIT]   =  1'b0;
            cc_out[CC_C_BIT]   =  1'b0;
        end
        
        ALU8OP_SBC:
        begin
            {cc_out[CC_C_BIT], ALUFn[7:0]} = {1'b0, a_arg} - {1'b0, b_arg} - cc_arg[CC_C_BIT];
            cc_out[CC_V_BIT]   =   (a_arg[7] & ~b_arg[7] & ~ALUFn[7]) | (~a_arg[7] & b_arg[7] & ALUFn[7]);
        end
        
        default:
            ALUFn = 8'H00;
    
    endcase
    
    cc_out[CC_N_BIT]   =  ALUFn[7];
    cc_out[CC_Z_BIT]   =  (ALUFn == 8'H00);
    ALU8Inst    =  {cc_out[7:0], ALUFn[7:0]};
end
endfunction

// Top 8 bits == CC, bottom 8 bits = output value
wire    [15:0] ALU8 =  ALU8Inst(ALU8_OP, ALU8_A, ALU8_B, ALU8_CC);

function IsALU8Set0(input   [7:0] instr);
reg     result;
reg     [3:0] hi;
reg     [3:0] lo;
begin
	hi =  instr[7:4];
	lo =  instr[3:0];
	result =  0;
	if (~InstPage2) // Page $00 and $11 are 8-bit
	begin
		if ( (hi == 4'H0) || (hi == 4'H4) || (hi == 4'H5) || (hi == 4'H6) || (hi == 4'H7) )
		begin
			if ( (lo != 4'H1) && (lo != 4'H2) && (lo != 4'H5) && (lo != 4'HB) && (lo != 4'HE) )     // permit NEG, COM, LSR, ROR, ASR, ASL/LSL, ROL, DEC, INC, TST, CLR 
			result =  1;
		end
	end
    IsALU8Set0     =  result;            
end
endfunction
function IsALU8Set1(input   [7:0] instr);
reg     result;
reg     [3:0] hi;
reg     [3:0] lo;
begin
    hi =  instr[7:4];
    lo =  instr[3:0];
	result =  0;
	if (~InstPage2) // Page $00 and $11 are 8-bit
	begin
		if ( (hi >= 4'H8) )
		begin
			if ( (lo <= 4'HB) && (lo != 4'H3) && (lo != 4'H7) )     // 8-bit SUB, CMP, SBC, AND, BIT, LD, EOR, ADC, OR, ADD
			result =  1;
		end
	end
	IsALU8Set1     =  result;                
end
endfunction
// Determine if the instruction is performing an 8-bit op (ALU only)    
function ALU8BitOp(input   [7:0] instr);
begin
    ALU8BitOp      =  IsALU8Set0(instr) | IsALU8Set1(instr);
end
endfunction
wire    Is8BitInst     =  ALU8BitOp(Inst1);


function TargetRegs_e WhatReg8(input   [7:0] instr);
TargetRegs_e result;
reg     [3:0] hi;
begin
	result = TARGETREG_A;
	hi =  instr[7:4];
	
	if ((instr == 8'H3C) || (instr == 8'H3D)) begin //1
		if (InstPage3) begin //2
			result = TARGETREG_MD;
			end //2
		end //1
	
	if ((hi == 4'H4) || (hi == 4'H8) || (hi == 4'H9) || (hi == 4'HA) || (hi == 4'HB) ) // a or e
	begin
		if (InstPage3)
		begin
			result = TARGETREG_E;
		end
		else if (~InstPage2)
		begin
			result =  TARGETREG_A;
		end
	end
	
	else if ((hi == 4'H5) || (hi == 4'HC) || (hi == 4'HD) || (hi == 4'HE) || (hi == 4'HF) ) // b or f
	begin
		if (InstPage3)
		begin
			result = TARGETREG_F;
		end
		else if (~InstPage2)
		begin
			result =  TARGETREG_B;
		end
	end
	WhatReg8 =  result;
end
endfunction
assign ALU8Reg = WhatReg8(Inst1);

/////////////////////////////////////////////////////////////////
// Is this a 16-bit Store?
localparam ST16_REG_X  =  3'd0;
localparam ST16_REG_Y  =  3'd1;
localparam ST16_REG_U  =  3'd2;
localparam ST16_REG_S  =  3'd3;
localparam ST16_REG_D  =  3'd4;
localparam ST16_REG_W  =  3'd5;
function [3:0] IsST16(input page2, input page3, input   [7:0] inst);
reg     [3:0] hi;
reg     [3:0] lo;
reg     [2:0] regnum;
reg     IsStore;
begin
    hi =  inst[7:4];
    lo =  inst[3:0];
    IsStore    =  1'b0;
    regnum     =  3'b111;
	if ( (inst == 8'H97) || (inst == 8'HA7) || (inst == 8'HB7) )
		begin
			if (page2)
				begin
					IsStore = 1;
					regnum = ST16_REG_W;
				end
		end
	else if ((inst == 8'H9F) || (inst == 8'HAF) || (inst == 8'HBF))
		begin
			IsStore    =  1;
			if (page2)
				regnum =  ST16_REG_Y;
			else
				regnum =  ST16_REG_X;
		end
    else if ((inst == 8'HDF) || (inst == 8'HEF) || (inst == 8'HFF))
		 begin
			  IsStore        =  1;
			  if (page2)
					regnum =  ST16_REG_S;
			  else
					regnum =  ST16_REG_U;
		 end
    else if ((inst == 8'HDD) || (inst == 8'HED) || (inst == 8'HFD))
		 begin
			  IsStore        =  1;
			  regnum =  ST16_REG_D;
		 end
    IsST16 =  {IsStore, regnum}; // return {x,x} to the caller
end
endfunction
wire    IsStore16;
wire    [2:0] StoreRegisterNum;
assign  {IsStore16, StoreRegisterNum}  =  IsST16(InstPage2, InstPage3, Inst1);

/////////////////////////////////////////////////////////////////
// ALU16 - Simpler than the 8 bit ALU

localparam ALU16_REG_X =  3'd0;
localparam ALU16_REG_Y =  3'd1;
localparam ALU16_REG_U =  3'd2;
localparam ALU16_REG_S =  3'd3;
localparam ALU16_REG_D =  3'd4;
localparam ALU16_REG_W =  3'd5;

function [2:0] ALU16RegFromInst(input   Page2, input   Page3, input   [7:0] inst);
reg     [2:0] srcreg;
begin
    srcreg =  3'b111;       // default
    casex ({Page2, Page3, inst}) // Note pattern for the matching below

		// 6309 D ops
		10'b1001000000:			// (NEGD) 1040
			srcreg =  ALU16_REG_D;
		10'b1001000011:			// (COMD) 1043
			srcreg =  ALU16_REG_D;
		10'b1001000100:			// (LSRD) 1044
			srcreg =  ALU16_REG_D;
		10'b1001000110:			// (RORD) 1046
			srcreg =  ALU16_REG_D;
		10'b1001000111:			// (ASRD) 1047
			srcreg =  ALU16_REG_D;
		10'b1001001000:			// (LSLD) 1048
			srcreg =  ALU16_REG_D;
		10'b1001001001:			// (ROLD) 1049
			srcreg =  ALU16_REG_D;
		10'b1001001010:			// (DECD) 104A
			srcreg =  ALU16_REG_D;
		10'b1001001100:			// (INCD) 104C
			srcreg =  ALU16_REG_D;
		10'b1001001101:			// (TSTD) 104D
			srcreg =  ALU16_REG_D;
		10'b1001001111:			// (CLRD) 104F
			srcreg =  ALU16_REG_D;


		// 6309 W ops
		10'b1001010011:			// (COMW) 1053
			srcreg =  ALU16_REG_W;
		10'b1001010100:			// (LSRW) 1054
			srcreg =  ALU16_REG_W;
		10'b1001010110:			// (RORW) 1056
			srcreg =  ALU16_REG_W;
		10'b1001011001:			// (ROLW) 1059
			srcreg =  ALU16_REG_W;
		10'b1001011010:			// (DECW) 105A
			srcreg =  ALU16_REG_W;
		10'b1001011100:			// (INCW) 105C
			srcreg =  ALU16_REG_W;
		10'b1001011101:			// (TSTW) 105D
			srcreg =  ALU16_REG_W;
		10'b1001011111:			// (CLRW) 105F
			srcreg =  ALU16_REG_W;
	

		10'b1010xx000x:         // 1081, 1091, 10A1, 10B1 		CMPW      1080, 1090, 10A0, 10B0 		SUBW
			srcreg =  ALU16_REG_W;
		10'b1010xx1011:         // 108B, 109B, 10AB, 10BB 		ADDW
			srcreg =  ALU16_REG_W;
		10'b1010xx0110:				// 1086, 1096, 10A6, 10B6	LDW
			srcreg =  ALU16_REG_W;
			
		
		10'b1010xx1001:         // (ADCD) 1089, 1099, 10A9, 10B9
			srcreg =  ALU16_REG_D;
		10'b1010xx0010:			// (SBCD) 1082, 1092, 10A2, 10B2
			srcreg = ALU16_REG_D;
		10'b1010xx0100:			// (ANDD) 1084, 1094, 10A4, 10B4
			srcreg = ALU16_REG_D;
		10'b1010xx0101:			// (BITD) 1085, 1095, 10A5, 10B5
			srcreg = ALU16_REG_D;
		10'b1010xx1000:			// (EORD) 1088, 1098, 10A8, 10B8
			srcreg = ALU16_REG_D;
		10'b1010xx1010:			// (ORD)  108A, 109A, 10AA, 10BA
			srcreg = ALU16_REG_D;


		// 6809 D ops
		10'b0011xx0011:         // C3, D3, E3, F3 				ADDD
			srcreg =  ALU16_REG_D;
		10'b0011xx1100:         // CC, DC, EC, FC 				LDD
			srcreg =  ALU16_REG_D;  
		10'bx010xx0011:         // 1083, 1093, 10A3, 10B3 		CMPD		83, 93, A3, B3					SUBD
			srcreg =  ALU16_REG_D;
			
	
		// X ops
		10'b0010xx11x0:         // 8E LDX, 9E LDX, AE LDX, BE					LDX		8C,9C,AC,BC										CMPX
			srcreg =  ALU16_REG_X;
		10'H03A:                // 3A ABX
			srcreg =  ALU16_REG_X;
		10'H030:                // 30 LEAX
			srcreg =  ALU16_REG_X;
			
			
		// Y ops
		10'b1010xx11x0:         // 108E LDY, 109E LDY, 10AE LDY, 10BE 		LDY		108C, 109C, 10AC, 10BC 						CMPY
			srcreg =  ALU16_REG_Y;
		10'H031:                // 31 LEAY
			srcreg =  ALU16_REG_Y;

			
		// U ops
		10'b0011xx1110:         // CE LDU, DE LDU, EE LDU, FE 				LDU
			srcreg =  ALU16_REG_U; 
		10'b0110xx0011:         // 1183, 1193, 11A3, 11B3 						CMPU
			srcreg =  ALU16_REG_U;
		10'H033:                // 32 LEAU
			srcreg =  ALU16_REG_U;
			
			
		// S ops
		10'b1011xx1110:         // 10CE LDS, 10DE LDS, 10EE LDS, 10FE 		LDS
			srcreg =  ALU16_REG_S;
		10'b0110xx1100:         // 118C, 119C, 11AC, 11BC 						CMPS
			srcreg =  ALU16_REG_S;
		10'H032:                // 32 LEAS
			srcreg =  ALU16_REG_S;
			

		default:
			srcreg =  3'b111;
	 endcase
    ALU16RegFromInst   =  srcreg;
end
endfunction

wire    [2:0] ALU16Reg     =  ALU16RegFromInst(InstPage2, InstPage3, Inst1);

// these codes aren't part of instruction but for our use only
//localparam  ALUOP16_SUB			=  4'H0;
//localparam  ALUOP16_ADD			=  4'H1;
//localparam  ALUOP16_LD			=  4'H2;
//localparam  ALUOP16_CMP			=  4'H3;
//localparam  ALUOP16_LEA			=  4'H4;
//localparam	ALUOP16_CLR			=	4'H5;
//localparam	ALUOP16_DEC			=	4'H6;
//localparam	ALUOP16_INC			=	4'H7;
//localparam	ALUOP16_ASL			=	4'H8;
//localparam	ALUOP16_LSL			=	4'H8;
//localparam	ALUOP16_NEG			=	4'H9;
//localparam	ALUOP16_ROL			=	4'HA;
//localparam	ALUOP16_ADC			=	4'HB;
//localparam  ALUOP16_BIT			=	4'HC;
//localparam  ALUOP16_LSR			=	4'HD;
//localparam  ALUOP16_ASR			=	4'HD;
//localparam  ALUOP16_AND			=	4'HE;
//
//localparam  ALUOP16_INVALID	=  4'HF;

localparam  ALUOP16_SUB			=  5'd0;
localparam  ALUOP16_ADD			=  5'd1;
localparam  ALUOP16_LD			=  5'd2;
localparam  ALUOP16_CMP			=  5'd3;
localparam  ALUOP16_LEA			=  5'd4;
localparam	ALUOP16_CLR			=	5'd5;
localparam	ALUOP16_DEC			=	5'd6;
localparam	ALUOP16_INC			=	5'd7;
localparam	ALUOP16_ASL			=	5'd8; // same as LSL
localparam	ALUOP16_NEG			=	5'd9;
localparam	ALUOP16_ROL			=	5'd10;
localparam	ALUOP16_ADC			=	5'd11;
localparam  ALUOP16_BIT			=	5'd12;
localparam  ALUOP16_LSR			=	5'd13;
localparam  ALUOP16_ASR			=	5'd14;
localparam  ALUOP16_AND			=	5'd15;
localparam  ALUOP16_ROR			=	5'd16;
localparam  ALUOP16_COM			=	5'd17;
localparam  ALUOP16_TST			=	5'd18;
localparam  ALUOP16_INVALID	=  5'd31;


function [5:0] ALU16OpFromInst(input   Page2, input   Page3, input   [7:0] inst);
reg     [4:0] aluop;
reg     writeback;
begin
	aluop  =  ALUOP16_INVALID;
	writeback  =  1'b1;
	casex ({Page2, Page3, inst})
	
		10'b0000111010:	// 3A ABX
            aluop  =  ALUOP16_ADD;
		10'b1001000000:	// 1040 NEGD
			aluop  =  ALUOP16_NEG;
		10'b1001000111:	// 1047 ASRD
			aluop  =  ALUOP16_ASR;
		10'b1001001000:	// 1048 ASLD/LSLD
			aluop  =  ALUOP16_ASL;

		10'b00001100xx:         // $30-$33, LEAX, LEAY, LEAS, LEAU
			aluop  =  ALUOP16_LEA;

		10'b10010x0011:	// 1043 COMD   1053 COMW
			aluop  =  ALUOP16_COM;
		10'b10010x0100:	// 1044 LSRD   1054 LSRW
			aluop  =  ALUOP16_LSR;
		10'b10010x0110:	// 1046 RORD   1056 RORW
			aluop  =  ALUOP16_ROR;
		10'b10010x1001:	// 1049 ROLD / 1059 ROLW
			aluop  =  ALUOP16_ROL;
		10'b10010x1010:	// 104A DECD / 105A DECW
			aluop  =  ALUOP16_DEC;
		10'b10010x1100:	// 104C INCD / 105C INCW
			aluop  =  ALUOP16_INC;
		10'b10010x1101: begin	// 104D TSTD / 105D TSTW
			aluop  =  ALUOP16_TST;
			writeback  =  1'b0;
			end
		10'b10010x1111:	// 104F CLRD / 105F CLRW
			aluop  =  ALUOP16_CLR;
		  
		10'b0110xx0011: begin         // 1183, 1193, 11A3, 11B3			CMPU
            aluop      =  ALUOP16_CMP;
            writeback  =  1'b0;
				end

		10'b1010xx0100:         // 1084, 1094, 10A4, 10B4		ANDD		  
            aluop  =  ALUOP16_AND;

		10'b0110xx1100: begin         // 118C, 119C, 11AC, 11BC			CMPS
            aluop      =  ALUOP16_CMP;
            writeback  =  1'b0;
				end

		//   8C,   9C,   AC,   BC    CMPX
		// 108C, 109C, 10AC, 10BC    CMPY
		10'bx010xx1100: begin
			aluop      =  ALUOP16_CMP;
			writeback  =  1'b0;
			end
        
		10'b1010xx1011:         // 108B, 109B, 10AB, 10BB		ADDW
            aluop  =  ALUOP16_ADD;
		10'b0011xx0011:         // C3, D3, E3, F3 					ADDD
            aluop  =  ALUOP16_ADD;
        
		10'b1010xx0110:				// 1086, 1096, 10A6, 10B6		LDW
          aluop  =  ALUOP16_LD;
		10'b0011xx1100:         // CC, DC, EC, FC 					LDD
          aluop  =  ALUOP16_LD;
				
		10'bx01xxx1110:         // 8E LDX, 9E LDX, AE LDX, BE LDX, CE LDU, DE LDU, EE LDU, FE LDU
            aluop  =  ALUOP16_LD;
        
		10'b1010xx0000:         // 1080, 1090, 10A0, 10B0			SUBW
            aluop  =  ALUOP16_SUB;
		10'b0010xx0011:         // 83, 93, A3, B3						SUBD
            aluop  =  ALUOP16_SUB;


		10'b1010xx1001:	// 1089, 1099, 10A9, 10B9		ADCD		  
			aluop  =  ALUOP16_ADC;
		
		// 1081, 1091, 10A1, 10B1 		CMPW 
		// 1083, 1093, 10A3, 10B3 		CMPD
		10'b1010xx00x1: begin
			aluop  =  ALUOP16_CMP;
			writeback  =  1'b0;
			end

	default:
			aluop  =  ALUOP16_INVALID;
	endcase
	ALU16OpFromInst    =  {writeback, aluop};
end
endfunction
wire    ALU16OpWriteback;
wire    [4:0]  ALU16Op;
assign  {ALU16OpWriteback, ALU16Op}    =  ALU16OpFromInst(InstPage2, InstPage3, Inst1);  
wire    IsALU16Op  =  (ALU16Op != ALUOP16_INVALID);          


function [23:0] DoALU16(input   [4:0] operation16, input   [15:0] a_arg, input   [15:0] b_arg, input   [7:0] cc_arg);
reg     [7:0]    cc_out;
reg     [15:0]   ALUFn;
reg     carry;
reg     borrow;
begin
    cc_out =  cc_arg;
    // carry is written in only 2 case branches below (DEC/INC) and never
    // read back by this function's own return value -- harmless as-is,
    // but Quartus can't prove that and warns about an inferred latch
    // (10776) without an explicit default on every path (same pattern
    // already fixed in ALU8Inst above).
    carry = 1'b0;
	case (operation16)
	 
		ALUOP16_CLR: begin
				ALUFn = 16'H0000;
				cc_out[CC_V_BIT]   =  1'b0;
				cc_out[CC_C_BIT]   =  1'b0;
			end

		ALUOP16_DEC: begin
            {carry, ALUFn}		=	{1'b0, a_arg} - 16'H0001;
            cc_out[CC_V_BIT]	=	(a_arg[15] & ~ALUFn[15]);
				end
			
		ALUOP16_INC: begin
			{carry, ALUFn} =  {1'b0, a_arg} + 16'H0001;
			cc_out[CC_V_BIT]   =  (~a_arg[15] & ALUFn[15]);             
			end

		ALUOP16_ASL: begin // same as LSL, shift left, 0 in, bit 15 out to carry
            {cc_out[CC_C_BIT], ALUFn}  =  {a_arg, 1'b0}; // do the 16-bit shift left with bit 0 cleared
            cc_out[CC_V_BIT]   =  a_arg[15] ^ a_arg[14]; // set overflow condition in reg.cc
				end
		
		ALUOP16_LSR: begin
            {ALUFn, cc_out[CC_C_BIT]}  =  {1'b0, a_arg};
            cc_out[CC_V_BIT]   =  a_arg[15] ^ a_arg[14];
				end
		  
		ALUOP16_ASR: begin
            {ALUFn, cc_out[CC_C_BIT]}  =  {a_arg[15], a_arg};
            cc_out[CC_V_BIT]   =  a_arg[15] ^ a_arg[14];
				end
		  
		ALUOP16_ROL: begin
			{cc_out[CC_C_BIT], ALUFn}  =  {a_arg, cc_arg[CC_C_BIT]};
			cc_out[CC_V_BIT]   =  a_arg[15] ^ a_arg[14];
			end

		ALUOP16_ROR: begin
			{ALUFn, cc_out[CC_C_BIT]}  =  {cc_arg[CC_C_BIT], a_arg};
			cc_out[CC_V_BIT]   =  a_arg[15] ^ a_arg[14];
			end
		  
		ALUOP16_NEG: begin
			ALUFn = ~a_arg + 1'b1;
			cc_out[CC_C_BIT] = (ALUFn != 16'H00);
			cc_out[CC_V_BIT] = (a_arg == 16'H8000);
			end
	
		ALUOP16_ADD:
        begin
            {cc_out[CC_C_BIT], ALUFn} =  {1'b0, a_arg} + {1'b0, b_arg};
            cc_out[CC_V_BIT]   =  (a_arg[15] & b_arg[15] & ~ALUFn[15]) | (~a_arg[15] & ~b_arg[15] & ALUFn[15]);
        end

		ALUOP16_ADC:
        begin
            {cc_out[CC_C_BIT], ALUFn} =  {1'b0, a_arg} + cc_arg[CC_C_BIT];
            cc_out[CC_V_BIT]   =  (a_arg[15] & ~ALUFn[15]) | (~a_arg[15] & ALUFn[15]);
//            cc_out[CC_H_BIT]   =  a_arg[4] ^ b_arg[4] ^ ALUFn[4];
        end
		  
		ALUOP16_AND: // ANDD ANDW
        begin
            {cc_out[CC_C_BIT], ALUFn} =  {1'b0, a_arg} & b_arg;
            cc_out[CC_V_BIT]   =  1'b0;
        end
		  
		ALUOP16_SUB:
        begin
            {cc_out[CC_C_BIT], ALUFn} =  {1'b0, a_arg} - {1'b0, b_arg};
            cc_out[CC_V_BIT]   =  (a_arg[15] & ~b_arg[15] & ~ALUFn[15]) | (~a_arg[15] & b_arg[15] & ALUFn[15]);
        end
        
		ALUOP16_LD: begin
			ALUFn  =  b_arg;
			cc_out[CC_V_BIT]   =  1'b0;
			end
        
		ALUOP16_CMP: begin
			{cc_out[CC_C_BIT], ALUFn} = {1'b0, a_arg} - {1'b0, b_arg};
			cc_out[CC_V_BIT] = (a_arg[15] & ~b_arg[15] & ~ALUFn[15]) | (~a_arg[15] & b_arg[15] & ALUFn[15]);
			end
  	  
      ALUOP16_BIT: begin
			ALUFn[15:0] =  (a_arg & b_arg);
			cc_out[CC_V_BIT] = 1'b0;
			end
				
		ALUOP16_TST: begin
			ALUFn[15:0] = a_arg;
			cc_out[CC_V_BIT] = 1'b0;
			end

		ALUOP16_LEA:
			ALUFn = a_arg;
        
		default:
		ALUFn = 16'H0000;
 
	endcase
	cc_out[CC_Z_BIT]   =  (ALUFn[15:0] == 16'H0000);
	if (operation16 != ALUOP16_LEA)
		cc_out[CC_N_BIT]   =  ALUFn[15];
	DoALU16  =  {cc_out, ALUFn};
end
endfunction
reg     [4:0]   ALU16_OP;
reg     [15:0]  ALU16_A;
reg     [15:0]  ALU16_B;
reg     [7:0]   ALU16_CC;     
wire    [23:0] ALU16   =  DoALU16(ALU16_OP, ALU16_A, ALU16_B, ALU16_CC);


/////////////////////////////////////////////////////////////////////////////////////////\
// Slowly turn this into the main instruction breakdown?
/////////////////////////////////////////////////////////////////////////////////////////\
localparam  ALUOP32_INVALID	=  1'd0;
localparam  ALUOP32_LD			=  1'd1;
function [3:0] Examine32BitOp(input   Page2, input   Page3, input   [7:0] inst); // returns 4 bits to caller
reg aluop; // 6309 only has one 32-bit ALU op  (Load  Q)
reg isaluop;
reg writeback;
reg isstore;
begin
	writeback  =  1'b0;
	aluop  =  ALUOP32_INVALID;
	isaluop = 1'b0;
	isstore = 1'b0;

	case ({Page2, Page3, inst})
//	10'b0100111100: begin // $1136  LDBT #imm,
	
	10'b0011001101: begin // $CD  LDQ #
		writeback  =  1'b1;
		aluop  =  ALUOP32_LD;
		isaluop = 1'b1;
		isstore = 1'b0;
		end
	10'b1011011100: begin // $10DC  LDQ <direct
		writeback  =  1; // change to 0 under for TST, CMP, BIT
		aluop  =  ALUOP32_LD;
		isaluop = 1;
		isstore = 0;
		end
	10'b1011101100: begin // $10EC  LDQ ,index
		writeback  =  1; // change to 0 under for TST, CMP, BIT
		aluop  =  ALUOP32_LD;
		isaluop = 1;
		isstore = 0;
		end
	10'b1011111100: begin // $10FC  LDQ >extended
		writeback  =  1; // change to 0 under for TST, CMP, BIT
		aluop  =  ALUOP32_LD;
		isaluop = 1;
		isstore = 0;
		end
	10'b1011011101: begin // $10DD  STQ <direct
		writeback  =  0;
		aluop  =  ALUOP32_LD; // uses ALU32 load operation to set CC
		isaluop = 0;
		isstore = 1;
		end
	10'b1011101101: begin // $10ED  STQ ,index
		writeback  =  0;
		aluop  =  ALUOP32_LD; // uses ALU32 load operation to set CC
		isaluop = 0;
		isstore = 1;
		end
	10'b1011111101: begin // $10FD  STQ >extended
		writeback  =  0;
		aluop  =  ALUOP32_LD; // uses ALU32 load operation to set CC
		isaluop = 0;
		isstore = 1;
		end
	default: begin
		writeback  =  1'b0;
		aluop  =  ALUOP32_INVALID;
		isaluop = 1'b0;
		isstore = 1'b0;
		end
	endcase
	Examine32BitOp    =  {isaluop, aluop, writeback, isstore};
end
endfunction
// known facts about 32-bit instruction examined in function
wire IsALU32Op;
wire ALU32Op;
wire ALU32OpWriteback;
wire IsStore32;
assign  {IsALU32Op, ALU32Op, ALU32OpWriteback, IsStore32} = Examine32BitOp(InstPage2, InstPage3, Inst1);  



/////////////////////////////////////////////////////////////////////////////////////////
function [39:0] DoALU32(input operation32, input   [31:0] a_arg, input   [31:0] b_arg, input   [7:0] cc_arg);
reg [7:0] cc_out;
reg [31:0] ALUFn;
begin
	cc_out =  cc_arg;
	case (operation32)
		ALUOP32_LD: begin	
			ALUFn = b_arg;
			cc_out[CC_V_BIT] = 1'b0;
			end
		default:
			ALUFn = 32'H0000;
	endcase
	cc_out[CC_Z_BIT] = (ALUFn[31:0] == 32'H0000);
	cc_out[CC_N_BIT] = ALUFn[31];
	DoALU32 = {cc_out, ALUFn};
end
endfunction
reg ALU32_OP;
reg [31:0] ALU32_A;
reg [31:0] ALU32_B;
reg [7:0] ALU32_CC;     
wire [39:0] ALU32 = DoALU32(ALU32_OP, ALU32_A, ALU32_B, ALU32_CC);
/////////////////////////////////////////////////////////////////////////////////////////




////////////////////////////////////////////////////////////
// Should software wait # of result-ready cycles by pipelining instructions?  Maybe for MUL/DIV?
// WRFFFFSS   where FFFFF is the 5-bit Function/Operation, SS is the slot #0-3, read arg from slot, write result to slot

localparam FPU_NOP		= 4'H00;
localparam FPU_ADD		= 4'H01;
localparam FPU_SUB		= 4'H02; // subtract arga FROM argb/slot
localparam FPU_NEG		= 4'H03;
localparam FPU_COM		= 4'H04;
localparam FPU_LSL		= 4'H05;
localparam FPU_LSR		= 4'H06;
localparam FPU_ASR		= 4'H07;
localparam FPU_MUL		= 4'H08;
localparam FPU_DIV		= 4'H09;

function [47:0] FPU(input   [3:0] operation, input signed [39:0] a_arg, input signed [39:0] b_arg, input [7:0] cc_arg);

reg signed [39:0] fResult;
reg signed [80:0] mResult;
reg [7:0] cc_new;

begin
	mResult = 0;
	cc_new = cc_arg;
	case ( operation ) // function to perform 0-15
		FPU_ADD:
			fResult = a_arg + b_arg;
		FPU_SUB:
			fResult = b_arg - a_arg;
		FPU_NEG:
			fResult = -a_arg;
		FPU_COM:
			fResult = ~a_arg;
		FPU_LSL: // asl/lsl
			fResult = {a_arg[38:0], 1'b0};
		FPU_LSR: // lsr
			fResult = {1'b0, a_arg[39:1]};
		FPU_ASR: // asr
			fResult = {a_arg[39], a_arg[39:1]};
		FPU_MUL: begin
			mResult = a_arg * b_arg;
			fResult = mResult[80-16:40-16]; // 32.48 back to 16.24 around decimal point?
			end
		default: begin
			fResult = a_arg;
			end
	endcase
	FPU = {cc_new, fResult}; // return result
end
endfunction
reg [3:0] FPUOp;
reg signed [39:0]  FPUArgA;
reg signed [39:0]  FPUArgB;
reg [7:0] FPUArgCC;
reg [39:0]  fpislots [0:3]; // CC,B,X,Y  40-bit value w/CC
reg [39:0]  fpislots_nxt [0:3]; // CC,B,X,Y  40-bit value w/CC
wire [47:0] FPUResult = FPU(FPUOp, FPUArgA, FPUArgB, FPUArgCC);




// CPU state machine
always @(*)
begin

    rLIC       =  1'b0;
    rAVMA      =  1'b1;
    rBUSY      =  1'b0;
    
    addr_nxt   =  16'HFFFF;
    pc_p1      =  (pc+16'H1);
    pc_p2      =  (pc+16'H2);
    pc_p3      =  (pc+16'H3);
    pc_p4      =  (pc+16'H4);
    pc_p5      =  (pc+16'H5);
    s_p1       =  (s+16'H1);
    s_m1       =  (s-16'H1);
    u_p1       =  (u+16'H1);
    u_m1       =  (u-16'H1);
    addr_p1    =  (addr+16'H1);
    ea_p1      =  (ea+16'H1);
    BS_nxt     =  1'b0;
    BA_nxt     =  1'b0;
    
    // These may be overridden below, but the "next" version by default should be
    // the last latched version.
    IntType_nxt = IntType;
    NMIClear_nxt = NMIClear;
    NextState_nxt = NextState;
	 md_nxt		=	md;
    a_nxt      =  a;
    b_nxt      =  b;
    e_nxt      =  e;
    f_nxt      =  f;
    x_nxt      =  x;
    y_nxt      =  y;
    s_nxt      =  s;
    u_nxt      =  u;
    v_nxt      =  v;
    z_nxt      =  z;
    zz_nxt     =  zz;
    cc_nxt     =  cc;
    dp_nxt     =  dp;
    pc_nxt     =  pc;
    tmp_nxt    =  tmp;
    ALUTmp_nxt    =  ALUTmp;
    ea_nxt     =  ea;
	 fpislots_nxt <= fpislots;
    
// ALU parameters are cleared on each cycle by default.
// They must be set to the proper values in the same cycle as the operation and result are expected.

	ALU8_A      =  8'H00;
	ALU8_B      =  8'H00;
	ALU8_CC     =  8'H00;
	ALU8_OP     =  ALU8OP_INVALID;
    
	ALU16_OP   =  ALUOP16_INVALID;
	ALU16_A    =  16'H0000;
	ALU16_B    =  16'H0000;
	ALU16_CC   =  8'H00;

	ALU32_OP   =  ALUOP32_INVALID;
	ALU32_A    =  32'H00000000;
	ALU32_B    =  32'H00000000;
	ALU32_CC   =  8'H00;
	 
	FPUOp		= FPU_NOP;
	FPUArgA = 40'b0;
	FPUArgB = 40'b0;
	FPUArgCC = 8'b0;
    
    DOutput       =  8'H00;
    RnWOut     =  1'b1;     // read
    
    Inst1_nxt  =  Inst1;
    Inst2_nxt  =  Inst2;
    Inst3_nxt  =  Inst3;
    InstPage2_nxt  =  InstPage2;
    InstPage3_nxt  =  InstPage3;
    
    CpuState_nxt   =  CpuState;
    
    case (CpuState)
    CPUSTATE_RESET:
    begin
        addr_nxt   =  16'HFFFF;
		  md_nxt		= 0;
        a_nxt      =  0;
        b_nxt      =  0;
		  e_nxt		= 0;
		  f_nxt		= 0;
        x_nxt      =  0;
        y_nxt      =  0;
        s_nxt      =  16'HFFFD;    // Take care about removing the reset of S.  There's logic depending on the delta between s and s_nxt to clear NMIMask.
        u_nxt      =  0;
//        v_nxt      =  0;  // V does not clear on a reset!
        z_nxt      =  0;
        zz_nxt     =  0;
        cc_nxt     =  CC_F | CC_I; // reset disables interrupts
        dp_nxt     =  0;
        ea_nxt     =  16'HFFFF;
//		  fpislots_nxt <= 48'H0;

//			fpslotrw_nxt = 1;
        
        RnWOut     =  1;        // read
        rLIC       =  1'b0;     // Instruction incomplete
        NMIClear_nxt= 1'b0;
        rAVMA = 1'b1; // default is Valid Memory Cycle Yes
        IntType_nxt = INTTYPE_NONE; // enum
        CpuState_nxt   =  CPUSTATE_RESET0; // enum
    end
    
    CPUSTATE_RESET0:
    begin
        addr_nxt       =  `RESET_VECTOR;
        rBUSY          =  1'b1;
        pc_nxt[15:8]   =  D[7:0];
        BS_nxt         =  1'b1; // ACK RESET
        rAVMA = 1'b1;
        rLIC = 1'b1;
        CpuState_nxt   =  CPUSTATE_RESET2;
    end
    
    CPUSTATE_RESET2:
    begin
        addr_nxt       =  addr_p1;
        BS_nxt         =  1'b1; // ACK RESET        
        pc_nxt[7:0]    =  D[7:0];
        rAVMA = 1'b1;
        rLIC = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end
    
    CPUSTATE_FETCH_I1:
    begin
	 
//			if (~fpslotrw)
//				fpislots = FPUInt;
	 
        if (~DMABREQLatched)
        begin
            addr_nxt      = pc;
            RnWOut        = 1'b1;
            rAVMA         = 1'b0;
            tmp_nxt       = {tmp[15:4], 4'b1111}; // initialize a 16-cycle counter
            BS_nxt         = 1'b1;
            BA_nxt         = 1'b1;
            rLIC           = 1'b1;
            CpuState_nxt  = CPUSTATE_DMABREQ;
        end
        else if (~HALTLatched)
        begin
            addr_nxt       = pc;
            RnWOut         = 1'b1;
            rAVMA          = 1'b0;
            BS_nxt         = 1'b1;
            BA_nxt         = 1'b1;
            rLIC           = 1'b1;            
            CpuState_nxt = CPUSTATE_HALTED;
        end
        else // not halting, run the inst byte fetch
        begin
            addr_nxt       =  pc;   // Set the address bus for the next instruction, first byte
            pc_nxt =  pc_p1;
            RnWOut =  1;            // Set for a READ
            Inst1_nxt  =  MappedInstruction;
            InstPage2_nxt  =  0;
            InstPage3_nxt  =  0;
            
            // New instruction fetch; service interrupts pending
            if (NMILatched == 0)
            begin
                pc_nxt = pc;
                rAVMA = 1'b1;
                CpuState_nxt = CPUSTATE_NMI_START;
            end
            else if ((FIRQLatched == 0) && (cc[CC_F_BIT] == 0))
            begin
                pc_nxt = pc;
                rAVMA = 1'b1;
                CpuState_nxt = CPUSTATE_FIRQ_START;
            end
            else if ((IRQLatched == 0) && (cc[CC_I_BIT] == 0))
            begin
                pc_nxt = pc;
                rAVMA = 1'b1;
                CpuState_nxt = CPUSTATE_IRQ_START;
            end
            
            // The actual 1st byte checks
            else if (Inst1_nxt == 8'H10) // Page 2  Note, like the 6809, $10 $10 $10 $10 has the same effect as a single $10.
            begin
                InstPage2_nxt  =  1; // InstPage2=1 InstPage3=0
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_FETCH_I1V2;
            end
            else if (Inst1_nxt == 8'H11)    // Page 3
            begin
                InstPage3_nxt  =  1; // InstPage2=0 InstPage3=1
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_FETCH_I1V2;
            end
            else
            begin
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_FETCH_I2; // then Inst1_nxt -> Inst
            end
        end // if not halting
    end
    
    CPUSTATE_FETCH_I1V2:
    begin
        addr_nxt   =  pc;            // Set the address bus for the next instruction, first byte
        pc_nxt     =  pc_p1;
        RnWOut     =  1;            // Set for a READ
        Inst1_nxt  =  MappedInstruction; // fetch new opcode

        if (Inst1_nxt == 8'H10)         // Page 2  Note, like the 6809, $10 $10 $10 $10 has the same effect as a single $10.
        begin
            if (InstPage3 == 0)             // $11 $11 $11 $11 ... $11 $10 still = Page 3
                InstPage2_nxt  =  1;
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1V2;
        end
        else if (Inst1_nxt == 8'H11)    // Page 3
        begin
            if (InstPage2 == 0)             // $10 $10 ... $10 $11 still = Page 2
                InstPage3_nxt  =  1;
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1V2;
        end
        else
        begin
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I2;
        end
    end
    
    CPUSTATE_FETCH_I2:      // We've fetched the first byte.  If a $10 or $11 (page select), mark those flags and fetch the next byte as instruction byte 1.
    begin
        addr_nxt   =  addr_p1;    // Address bus++
        pc_nxt     =  pc_p1; // default is to point to address past postbyte, assumes 2+byte instruction, for 1 byte instruction pc_nxt will be pc
        Inst2_nxt  =  D; // postbyte
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;

// previous code checked for illegal instruction here, but the fall-through will catch unsupported instructions the same

			// First byte Decode for this stage
			case (AddrModeType)
				 TYPE_INDEXED: begin
					rAVMA = 1'b1;
					CpuState_nxt   =  CPUSTATE_INDEXED_BASE;
					end
				 
				 TYPE_EXTENDED: begin
					ea_nxt[15:8]   =  Inst2_nxt;
					rAVMA = 1'b1;
					CpuState_nxt   =  CPUSTATE_EXTENDED_ADDRLO;
					end
				 
				 TYPE_DIRECT: begin
					ea_nxt =  {dp, Inst2_nxt};
					rAVMA = 1'b0;
					CpuState_nxt   =  CPUSTATE_DIRECT_DONTCARE;
					end

					TYPE_INHERENT: begin
						if (Inst1 == OPCODE_INH_NOP) begin
							rLIC = 1'b1; // Instruction done!
							rAVMA = 1'b1;
							CpuState_nxt = CPUSTATE_FETCH_I1;    
							end

						else if ((InstPage2 == 1) & (Inst1 == OPCODE_INH_DAA)) begin
							FPUOp = a[3:0];
							FPUArgA = {b, x, y};
							FPUArgCC = cc;
							
							if ( a[6] == 1'b1 )
								FPUArgB = fpislots[a[5:4]]; // get argb from slot instead of registers
							else
								FPUArgB = {b, x, y};
							
							if ( a[7] == 1'b1 ) // put result back in specified slot #?
								fpislots_nxt[a[5:4]] = FPUResult[39:0]; // exclude the CC register at MSByte, put result into slot instea of registers
							else
								{cc_nxt, b_nxt, x_nxt, y_nxt} = FPUResult;

							CpuState_nxt = CPUSTATE_FETCH_I1;
							rLIC = 1'b1; // Instruction done!
							rAVMA = 1'b1;
							end

						else if (Inst1 == OPCODE_INH_DAA) begin
							if ( ((cc[CC_C_BIT]) || (a[7:4] > 4'H9)) ||
								  ((a[7:4] > 4'H8) && (a[3:0] > 4'H9)) )
								 tmp_nxt[7:4] = 4'H6;
							else
								 tmp_nxt[7:4] = 4'H0;
								 
							if ((cc[CC_H_BIT]) || (a[3:0] > 4'H9))
								 tmp_nxt[3:0] = 4'H6;
							else
								 tmp_nxt[3:0] = 4'H0;

							// DAA handles carry in the weirdest way.  
							// If it's already set, it remains set, even if carry-out is 0.
							// If it wasn't set, but the output of the operation is set, carry-out gets set.
							{tmp_nxt[8], a_nxt} = {1'b0, a} + tmp_nxt[7:0];
							cc_nxt[CC_C_BIT] = cc_nxt[CC_C_BIT] | tmp_nxt[8];
							cc_nxt[CC_N_BIT] = a_nxt[7];
							cc_nxt[CC_Z_BIT] = (a_nxt == 8'H00);
							rLIC = 1'b1; // Instruction done!
							rAVMA = 1'b1;
							CpuState_nxt = CPUSTATE_FETCH_I1;
							end

						
					 else if (Inst1 == OPCODE_INH_SYNC)
					  begin
							CpuState_nxt = CPUSTATE_SYNC;
							rLIC = 1'b1;
							rAVMA = 1'b0;
					  end
					 else if (Inst1 == OPCODE_INH_MUL)
					  begin
							tmp_nxt = 16'H0000;
							ea_nxt[15:8] = 8'H00;
							ea_nxt[7:0] = a;
							a_nxt = 8;
							rAVMA = 1'b0;
							CpuState_nxt = CPUSTATE_MUL_ACTION;
					  end
					 else if (Inst1 == OPCODE_INH_RTS)
					  begin
							rAVMA = 1'b1;
							CpuState_nxt   =  CPUSTATE_RTS_HI;
					  end
					 else if (Inst1 == OPCODE_INH_RTI)
					  begin
							rAVMA = 1'b1;
							tmp_nxt = 16'H1001; // Set tmp[12] to indicate an RTI being processed, and at least pull CC.
							CpuState_nxt = CPUSTATE_PUL_ACTION;
							NextState_nxt = CPUSTATE_FETCH_I1;
					  end
					 else if (Inst1 == OPCODE_INH_SWI)
					  begin
							rAVMA = 1'b1;
							CpuState_nxt = CPUSTATE_SWI_START;
					  end
					 else if (Inst1 == OPCODE_INH_CWAI)
					  begin
							rAVMA = 1'b1;
							CpuState_nxt = CPUSTATE_CWAI;
					  end
					 else if (Inst1 == OPCODE_INH_SEX)
					  begin
							a_nxt = {8{b[7]}};
							cc_nxt[CC_N_BIT] = b[7];
							cc_nxt[CC_Z_BIT] = {b == 8'H00};
							cc_nxt[CC_V_BIT] = 1'b0;								
							rLIC = 1'b1; // Instruction done!
							rAVMA = 1'b1;
							CpuState_nxt = CPUSTATE_FETCH_I1;
					  end
					 else if (Inst1 == OPCODE_INH_ABX)
							  begin
									x_nxt  =  x + b;
									rAVMA = 1'b0;
									CpuState_nxt   =  CPUSTATE_ABX_DONTCARE;
							  end
						
					else if (Is8BitInst) // 8-bit inherent = clra, clrb, inc, dec, tst, bit, neg, com, asl, lsl, asr, lsr, ror, rol
					  begin
							ALU8_OP =  ALU8Op;
							case (ALU8Reg)
								TARGETREG_A:
									ALU8_A = a;
								TARGETREG_B:
									ALU8_A = b;
								TARGETREG_E:
									ALU8_A = e;
								TARGETREG_F:
									ALU8_A = f;
								default:
								begin
								end
							endcase  

							ALU8_B  =  0;
							ALU8_CC =  cc;
							cc_nxt =  ALU8[15:8];
							
							if (ALU8Writeback)
							begin
								case (ALU8Reg)
									TARGETREG_A:
										a_nxt  =  ALU8[7:0];
									TARGETREG_B:
										b_nxt  =  ALU8[7:0];
									TARGETREG_E:
										e_nxt  =  ALU8[7:0];
									TARGETREG_F:
										f_nxt  =  ALU8[7:0];
									default:
									begin
									end
								endcase  
							end
							rLIC = 1'b1; // Instruction done!
							rAVMA = 1'b1;
							CpuState_nxt = CPUSTATE_FETCH_I1;  
					  end
					  
					else if (IsALU16Op) begin // must be 16-bit inherent comd/w, negd, lsrd/w, rord/w, asrd, lsld, rold/w, decd/w, incd/w, tstd/w, clrd/w
//								addr_nxt       =  ea;
							case (ALU16Reg)
								ALU16_REG_D:
									 ALU16_A        =  {a, b};
								ALU16_REG_W:
									 ALU16_A        =  {e, f};
								default:
								begin
								end
							endcase
							ALU16_OP       =  ALU16Op;
							ALU16_CC       =  cc;
							ALU16_B        =  {tmp[15:8], D[7:0]};
						  
							if (ALU16OpWriteback)
							begin
							case (ALU16Reg)
								ALU16_REG_D:
									{cc_nxt, a_nxt, b_nxt} =  ALU16;
								ALU16_REG_W:
									{cc_nxt, e_nxt, f_nxt} =  ALU16;
								default:
								begin
								end
							endcase
							end

							rLIC = 1'b1; // Instruction done!
							rAVMA = 1'b1;
							CpuState_nxt = CPUSTATE_FETCH_I1;  
						end

					 if (IsOneByteInstruction(Inst1))        // This check is probably superfluous.  Every inherent instruction is 1 byte on the 6809.
						 pc_nxt =  pc;                       // The 6809 auto-reads 2 bytes for every instruction.  :(  Adjust by not incrementing PC on the 2nd byte read.
					end
				 
				 TYPE_IMMEDIATE: begin

//						if (Inst1 == OPCODE_IMM_LDQ) begin

						if (IsSpecialImmediate) begin
					  
							if ((InstPage3 == 1) && (Inst1 == OPCODE_IMM_LDMD) ) begin
								pc_nxt = pc_p1; // skip over postbyte 
								md_nxt  =  D; // D same as Inst2_nxt
								rAVMA = 1'b0; // next cycle doesn't use RAM
								CpuState_nxt   =  CPUSTATE_LDMD; // need 5 cycles according to 6309 docs, this is 3rd?
								end
							
							else if ((InstPage3 == 1) && (Inst1 == OPCODE_IMM_LDBT)) begin
								pc_nxt = pc_p1; // next cycle point to 3rd instruction byte
								ALUTmp_nxt[7:0] = D; // get Reg,DestBit#,SourceBit# code (RRDDDSSS)
								rAVMA = 1'b1; // next cycle we access RAM
								CpuState_nxt   =  CPUSTATE_LOAD_BIT;
								end

							else if ((InstPage3 == 1) && (Inst1 == OPCODE_IMM_BITMD)) begin
								cc_nxt[CC_N_BIT] = md[7] & D[7];
								cc_nxt[CC_Z_BIT] = ((md & D) == 8'H00);
								cc_nxt[CC_V_BIT] = 1'b0;
								rAVMA = 1'b1;
								rLIC = 1'b1; // Instruction done!        
								CpuState_nxt   =  CPUSTATE_FETCH_I1;
								end
							
							else if ((InstPage2 == 1) && ((Inst1 == OPCODE_IMM_PSHSW) || (Inst1 == OPCODE_IMM_PSHUW)) ) begin // $1038pc
								 pc_nxt = pc; // no operand to skip over
								 tmp_nxt[15] = 1'b0;
								 tmp_nxt[14] = Inst1[1]; // Mark whether to save to U or S.
								 tmp_nxt[13:0] = 14'b00001100000000; // bits 9..8 specify E and F registers (W), Not pushing due to an interrupt (bit 13)
								 rAVMA = 1'b0;
								 CpuState_nxt = CPUSTATE_PSH_DONTCARE1;
								 NextState_nxt = CPUSTATE_FETCH_I1;
								end
							
							else if ((InstPage2 == 1) && ((Inst1 == OPCODE_IMM_PULSW) || (Inst1 == OPCODE_IMM_PULUW)) ) begin
								 pc_nxt = pc; // no operand to skip over
								 tmp_nxt[15] = 1'b0;
								 tmp_nxt[14] = Inst1[1]; // Mark whether to save to U or S.
								 tmp_nxt[13:0] = 14'b00001100000000; // E and F registers (W)
								 rAVMA = 1'b0;
								 CpuState_nxt = CPUSTATE_PUL_DONTCARE1;
								 NextState_nxt = CPUSTATE_FETCH_I1;
								end
					  
							else if (Inst1 == OPCODE_IMM_ANDCC) begin
							  //  pc_nxt = pc_p1; // is already done earlier
								 cc_nxt = cc & D; //cc_nxt & Inst2_nxt;
								 rAVMA = 1'b1;
								 CpuState_nxt = CPUSTATE_CC_DONTCARE;
								end
							
							else if (Inst1 == OPCODE_IMM_ORCC) begin
							 //   pc_nxt = pc_p1; // is already done earlier
								 cc_nxt = cc | D; //cc_nxt | Inst2_nxt;
								 rAVMA = 1'b1;
								 CpuState_nxt = CPUSTATE_CC_DONTCARE;
								end
							
							else if ( (Inst1 == OPCODE_IMM_PSHS) | (Inst1 == OPCODE_IMM_PSHU) ) begin
								// pc_nxt = pc_p1; // is already done earlier
								 tmp_nxt[15] = 1'b0;
								 tmp_nxt[14] = Inst1[1]; // Mark whether to save to U or S.
								 tmp_nxt[13] = 1'b0; // Not pushing due to an interrupt.
								 tmp_nxt[12:8] = 5'H00;
								 tmp_nxt[7:0] = Inst2_nxt;
								 rAVMA = 1'b0;
								 CpuState_nxt = CPUSTATE_PSH_DONTCARE1;
								 NextState_nxt = CPUSTATE_FETCH_I1;
								end
						
							else if ( (Inst1 == OPCODE_IMM_PULS) | (Inst1 == OPCODE_IMM_PULU) ) begin
								// pc_nxt = pc_p1; // is already done earlier
								 tmp_nxt[15] = 1'b0;
								 tmp_nxt[14] = Inst1[1]; // S (0) or U (1) stack in use.
								 tmp_nxt[13:8] = 6'H00;
								 tmp_nxt[7:0] = Inst2_nxt;
								 rAVMA = 1'b0;
								 CpuState_nxt = CPUSTATE_PUL_DONTCARE1;
								 NextState_nxt = CPUSTATE_FETCH_I1;
								end
		
							else if (Inst1 == OPCODE_IMM_TFR) begin
								 // The second byte lists the registers; Top nybble is reg #1, bottom is reg #2.
								 rAVMA = 1'b0;
								 CpuState_nxt   =  CPUSTATE_TFR_DONTCARE1;

								 case (Inst2_nxt[3:0])
									  EXGTFR_REG_W:
											{e_nxt,f_nxt}  =  EXGTFRRegA;
									  EXGTFR_REG_D:
											{a_nxt,b_nxt}  =  EXGTFRRegA;
									  EXGTFR_REG_X:
											x_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_Y:
											y_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_U:
											u_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_S:
											s_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_V:
											v_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_Z:
											z_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_ZZ:
											zz_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_PC:
											pc_nxt =  EXGTFRRegA;
									  EXGTFR_REG_DP:
											dp_nxt =  EXGTFRRegA[7:0];
									  EXGTFR_REG_A:
											a_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_B:
											b_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_E:
											e_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_F:
											f_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_CC:
											cc_nxt =  EXGTFRRegA[7:0];
									  default:
									  begin
									  end
								 endcase                          
								end
							else if (Inst1 == OPCODE_IMM_EXG) begin
								 // The second byte lists the registers; Top nybble is reg #1, bottom is reg #2.
				  
								 case (Inst2_nxt[7:4])
									  EXGTFR_REG_W:
											{e_nxt,f_nxt}  =  EXGTFRRegB;
									  EXGTFR_REG_D:
											{a_nxt,b_nxt}  =  EXGTFRRegB;
									  EXGTFR_REG_X:
											x_nxt  =  EXGTFRRegB;
									  EXGTFR_REG_Y:
											y_nxt  =  EXGTFRRegB;
									  EXGTFR_REG_U:
											u_nxt  =  EXGTFRRegB;
									  EXGTFR_REG_S:
											s_nxt  =  EXGTFRRegB;
									  EXGTFR_REG_V:
											v_nxt  =  EXGTFRRegB;
									  EXGTFR_REG_Z:
											z_nxt  =  EXGTFRRegB;
									  EXGTFR_REG_ZZ:
											zz_nxt  =  EXGTFRRegB;
									  EXGTFR_REG_PC:
											pc_nxt =  EXGTFRRegB;
									  EXGTFR_REG_DP:
											dp_nxt =  EXGTFRRegB[7:0];
									  EXGTFR_REG_A:
											a_nxt  =  EXGTFRRegB[7:0];
									  EXGTFR_REG_B:
											b_nxt  =  EXGTFRRegB[7:0];
									  EXGTFR_REG_E:
											e_nxt  =  EXGTFRRegB[7:0];
									  EXGTFR_REG_F:
											f_nxt  =  EXGTFRRegB[7:0];
									  EXGTFR_REG_CC:
											cc_nxt =  EXGTFRRegB[7:0];
									  default:
									  begin
									  end
								 endcase
		 
								 case (Inst2_nxt[3:0])
									  EXGTFR_REG_W:
											{e_nxt,f_nxt}  =  EXGTFRRegA;
									  EXGTFR_REG_D:
											{a_nxt,b_nxt}  =  EXGTFRRegA;
									  EXGTFR_REG_X:
											x_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_Y:
											y_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_U:
											u_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_S:
											s_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_V:
											v_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_Z:
											z_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_ZZ:
											zz_nxt  =  EXGTFRRegA;
									  EXGTFR_REG_PC:
											pc_nxt =  EXGTFRRegA;
									  EXGTFR_REG_DP:
											dp_nxt =  EXGTFRRegA[7:0];
									  EXGTFR_REG_A:
											a_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_B:
											b_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_E:
											e_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_F:
											f_nxt  =  EXGTFRRegA[7:0];
									  EXGTFR_REG_CC:
											cc_nxt =  EXGTFRRegA[7:0];
									  default:
									  begin
									  end
								 endcase                               
								 rAVMA = 1'b0;
								 CpuState_nxt   =  CPUSTATE_EXG_DONTCARE1;  
								end // EXG
							
							end // SpecialImmediate

							
						else if (IsALU32Op) begin // 32-bit Immediate mode
							rAVMA = 1'b1;
							CpuState_nxt   =  CPUSTATE_32IMM_B3116; // gather 4 postbytes, store in Q register and set CC
							end

						
					  // Not SpecialImmediate, Determine if this is an 8-bit ALU operation.
					  else if (Is8BitInst) begin
							ALU8_OP =  ALU8Op;
								case (ALU8Reg)
									TARGETREG_A:
										ALU8_A  =  a;
									TARGETREG_B:
										ALU8_A  =  b;
									TARGETREG_E:
										ALU8_A  =  e;
									TARGETREG_F:
										ALU8_A  =  f;
									default:
									begin
									end
								endcase  

							ALU8_B  =  Inst2_nxt;
							ALU8_CC =  cc;
							cc_nxt =  ALU8[15:8];
  
							if (ALU8Writeback)
							begin
								case (ALU8Reg)
									TARGETREG_A:
										a_nxt  =  ALU8[7:0];
									TARGETREG_B:
										b_nxt  =  ALU8[7:0];
									TARGETREG_E:
										e_nxt  =  ALU8[7:0];
									TARGETREG_F:
										f_nxt  =  ALU8[7:0];
									default:
									begin
									end
								endcase
							end
							rLIC = 1'b1; // Instruction done!               
							rAVMA = 1'b1;
							CpuState_nxt   =  CPUSTATE_FETCH_I1;
						end
					  
					  else if (IsALU16Op) begin // 16-bit Immediate Mode
							
								 rAVMA = 1'b1;
								 CpuState_nxt   =  CPUSTATE_16IMM_LO;
							end

					end

				 TYPE_RELATIVE: begin
				 
					  // Is this a LB** or a B**?
					  // If InstPage2 is set, it's a long branch; if clear, a normal branch.
					  if ( (InstPage2) || (Inst1 == INST_LBRA) || (Inst1 == INST_LBSR) )
					  begin
							rAVMA = 1'b1;
							CpuState_nxt   =  CPUSTATE_LBRA_OFFSETLOW;
					  end
					  else
					  begin
							rAVMA = 1'b0;
							CpuState_nxt   =  CPUSTATE_BRA_DONTCARE;
					  end

				 end
				 default:
				 begin
					  CpuState_nxt = CPUSTATE_FETCH_I1;
				 end
			endcase
    end


    CPUSTATE_LBRA_OFFSETLOW:
    begin
        addr_nxt   =  pc;
        pc_nxt     =  pc_p1;
        Inst3_nxt  =  D[7:0];
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_LBRA_DONTCARE;
    end

    CPUSTATE_LBRA_DONTCARE:
    begin
        addr_nxt       =  16'HFFFF;
        if ( TakeBranch )
        begin
            rAVMA = 1'b0;
            CpuState_nxt   =  CPUSTATE_LBRA_DONTCARE2;
        end
        else
        begin
            rLIC = 1'b1; // Instruction done!  
            rAVMA = 1'b1;            
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end            
    end

    CPUSTATE_BRA_DONTCARE:
    begin
        addr_nxt   =  16'HFFFF;
        tmp_nxt    =  pc;
        if (TakeBranch)
        begin
            pc_nxt =  pc + { {8{Inst2[7]}}, Inst2[7:0]}; // Sign-extend the 8 bit offset to 16.

            if (Inst1 == INST_BSR)
            begin
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_BSR_DONTCARE1;
            end
            else
            begin
                rLIC = 1'b1; // Instruction done!  
                rAVMA = 1'b1;                
                CpuState_nxt   =  CPUSTATE_FETCH_I1;
            end
        end
        else
        begin
            rLIC = 1'b1;
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end

    end

    CPUSTATE_LBRA_DONTCARE2:
    begin
        tmp_nxt=  pc;
        addr_nxt   =  16'HFFFF;

        // Take branch
        pc_nxt     =  pc + {Inst2[7:0], Inst3[7:0]};
        if (Inst1 == INST_LBSR)
        begin
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_BSR_DONTCARE1;
        end
        else
        begin
            rLIC = 1'b1; // Instruction done!        
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end
    end

    CPUSTATE_BSR_DONTCARE1:
    begin
        addr_nxt   =  pc;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_BSR_DONTCARE2;
    end

    CPUSTATE_BSR_DONTCARE2:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_BSR_RETURNLOW;
    end

    CPUSTATE_BSR_RETURNLOW:
    begin
        addr_nxt       =  s_m1;
        s_nxt  =  s_m1;
        DOutput[7:0]  =  tmp[7:0];
        RnWOut     =  0;
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_BSR_RETURNHIGH;
    end

    CPUSTATE_BSR_RETURNHIGH:
    begin
        addr_nxt       =  s_m1;
        s_nxt  =  s_m1;
        DOutput[7:0]  =  tmp[15:8];
        RnWOut     =  0;
        rLIC = 1'b1; // Instruction done!
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;    // after this, RnWOut must go to 1, and the bus needs the PC placed on it.
    end


	 
    CPUSTATE_TFR_DONTCARE1:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_TFR_DONTCARE2;
    end            

    CPUSTATE_TFR_DONTCARE2:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_TFR_DONTCARE3;
    end            

    CPUSTATE_TFR_DONTCARE3:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_TFR_DONTCARE4;
    end            

    CPUSTATE_TFR_DONTCARE4:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b1;
        rLIC = 1'b1; // Instruction done!        
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end            

    CPUSTATE_EXG_DONTCARE1:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_EXG_DONTCARE2;
    end            

    CPUSTATE_EXG_DONTCARE2:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_EXG_DONTCARE3;
    end            

    CPUSTATE_EXG_DONTCARE3:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_EXG_DONTCARE4;
    end            

    CPUSTATE_EXG_DONTCARE4:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_EXG_DONTCARE5;
    end    

    CPUSTATE_EXG_DONTCARE5:
    begin
        rAVMA = 1'b0;
        addr_nxt       =  16'HFFFF;
        CpuState_nxt   =  CPUSTATE_EXG_DONTCARE6;
    end

    CPUSTATE_EXG_DONTCARE6:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b1;
        rLIC = 1'b1; // Instruction done!        
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end
	 
    CPUSTATE_ABX_DONTCARE:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b1;
        rLIC = 1'b1; // Instruction done!        
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end            

    CPUSTATE_RTS_HI:
    begin
        addr_nxt       =  s;
        s_nxt  =  s_p1;
        pc_nxt[15:8]   =  D[7:0];
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_RTS_LO;
    end

    CPUSTATE_RTS_LO:
    begin
        addr_nxt       =  s;
        s_nxt  =  s_p1;
        pc_nxt[7:0]    =  D[7:0];
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_RTS_DONTCARE2;
    end

    CPUSTATE_RTS_DONTCARE2:
    begin
        addr_nxt       =  16'HFFFF;
        rLIC = 1'b1; // Instruction done!        
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end

    CPUSTATE_16IMM_LO: // account for both bytes for Immediate #value
    begin
        addr_nxt       =  pc;	// points to XX in LDD #$00XX
        pc_nxt =  pc_p1;
        
        ALU16_OP   =  ALU16Op;
        ALU16_CC   =  cc;
        ALU16_B    =  {Inst2, D[7:0]}; // Inst2 is from Fetch2, D is what's on data bus, so 16-bit value is now known for ALU

        case (ALU16Reg)
            ALU16_REG_X:
                ALU16_A    =  x;
            ALU16_REG_D:
                ALU16_A    =  {a, b};
            ALU16_REG_W:
                ALU16_A    =  {e, f};
            ALU16_REG_Y:
                ALU16_A    =  y;
            ALU16_REG_U:
                ALU16_A    =  u;
            ALU16_REG_S:
                ALU16_A    =  s;
            default:
                ALU16_A    =  16'H0;
        endcase

        if (ALU16OpWriteback)
        begin
            case (ALU16Reg)
                ALU16_REG_X:
                    {cc_nxt, x_nxt}        =  ALU16; 
                ALU16_REG_D:
                    {cc_nxt, a_nxt, b_nxt} =  ALU16;
                ALU16_REG_W:
                    {cc_nxt, e_nxt, f_nxt} =  ALU16;
                ALU16_REG_Y:
                    {cc_nxt, y_nxt}        =  ALU16;
                ALU16_REG_U:
                    {cc_nxt, u_nxt}        =  ALU16;
                ALU16_REG_S:
                    {cc_nxt, s_nxt}        =  ALU16;
                default:
                begin
                end
            endcase
        end
        else
            cc_nxt = ALU16[23:16];

        if (ALU16_OP == ALUOP16_LD)
        begin
            rLIC = 1'b1; // Instruction done!        
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end
        else
        begin
            rAVMA = 1'b0;
            CpuState_nxt   =  CPUSTATE_16IMM_DONTCARE;
        end
    end

	 
	CPUSTATE_32IMM_B3116: begin
		addr_nxt = pc;	// points to #$_,X,_,_
		pc_nxt =  pc_p1;
		ALUTmp_nxt[23:08] = {Inst2, D}; // remember first byte and byte on bus
		rAVMA = 1'b1;
		CpuState_nxt = CPUSTATE_32IMM_B1508;
		end

    CPUSTATE_32IMM_B1508: begin
		addr_nxt = pc;	// points to #$_,_,X,_
		pc_nxt = pc_p1;
		ALUTmp_nxt[7:0] = D; // remember byte on bus LDQ #__X_
		rAVMA = 1'b1;
		CpuState_nxt = CPUSTATE_32IMM_B0700; // last step uses ALU
		end

	CPUSTATE_32IMM_B0700: begin
		addr_nxt = pc;	// points to #_,_,_,X
		pc_nxt = pc_p1;
		ALU32_OP = ALU32Op;
		ALU32_CC = cc;
		ALU32_A = 32'H0;
		ALU32_B = {ALUTmp, D};
		if (ALU32OpWriteback)
			{cc_nxt, a_nxt, b_nxt, e_nxt, f_nxt} = ALU32;
		else cc_nxt = ALU32[39:32];
		rLIC = 1'b1; // Instruction done!        
		rAVMA = 1'b1;
		CpuState_nxt   =  CPUSTATE_FETCH_I1;
		end
	 
	CPUSTATE_DIRECT_DONTCARE: begin
		addr_nxt       =  16'HFFFF;
		if (IsJMP(InstPage2, InstPage3, Inst1)) begin
			pc_nxt =  ea;
			rLIC = 1'b1; // Instruction done!            
			rAVMA = 1'b1;
			CpuState_nxt   =  CPUSTATE_FETCH_I1;
			end
		else begin
			rAVMA = 1'b1;
			CpuState_nxt   =  CPUSTATE_ALU_EA;
			end
		end

    CPUSTATE_ALU_EA:
    begin

		  if (IsStore32) begin
					addr_nxt = ea;
					ea_nxt = ea_p1;
					DOutput = a; // a,b,e,f
					RnWOut         =  0;        // Write reg.a
					rAVMA          =  1'b1;
					rBUSY          =  1'b1;
					CpuState_nxt   =  CPUSTATE_ST32_B2316;
					end

        else if (IsALU32Op & (ALU32Op == ALUOP32_LD)) begin // not 32-bit store, check for 32-bit Load, assume Q
				addr_nxt = ea;
            ea_nxt = ea_p1;
				a_nxt = D;
				ALUTmp_nxt[23:16] = D;
            rAVMA = 1'b1;
            rBUSY = 1'b1;
            CpuState_nxt = CPUSTATE_LD32_B2316;
				end

        // Is Figure 18/5 Column 2?  JMP (not Immediate Mode)
        // This actually isn't done here.  All checks passing in to ALU_EA should check for a JMP; FIXME EVERYWHERE

        // Is Figure 18/5 Column 8?  TST (not immediate mode)
        // THIS IS BURIED IN THE COLUMN 3 section with comparisons to ALUOP_TST.
        
        // Is Figure 18/5 Column 3?
        else if (IsALU8Set1(Inst1))
        begin
            addr_nxt   =  ea;
            
            ALU8_OP     =  ALU8Op;
            ALU8_B      =  D[7:0];
            ALU8_CC     =  cc;
				case (ALU8Reg)
					TARGETREG_A:
						ALU8_A  =  a;
					TARGETREG_B:
						ALU8_A  =  b;
					TARGETREG_E:
						ALU8_A  =  e;
					TARGETREG_F:
						ALU8_A  =  f;
					default:
					begin
					end
				endcase  
 
            cc_nxt =  ALU8[15:8];

            if ( (ALU8Writeback) )
            begin
					case (ALU8Reg)
						TARGETREG_A:
							a_nxt  =  ALU8[7:0];
						TARGETREG_B:
							b_nxt  =  ALU8[7:0];
						TARGETREG_E:
							e_nxt  =  ALU8[7:0];
						TARGETREG_F:
							f_nxt  =  ALU8[7:0];
						default:
						begin
						end
					endcase  
            end

            rLIC = 1'b1; // Instruction done!             
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end

        // Is Figure 18/5 Column 4? (Store, 8 bits)
        else if (IsStore8)
        begin
            addr_nxt       =  ea;
            RnWOut =  0;    // write

            ALU8_OP     =  ALU8OP_LD;  // load has the same CC characteristics as store
            ALU8_A      =  8'H00;
            ALU8_CC     =  cc;

            case (Store8RegisterNum)
                ST8_REG_A:
                begin
                    DOutput   =  a;
                    ALU8_B  =  a;
                end
                ST8_REG_B:
                begin
                    DOutput   =  b;                                                
                    ALU8_B  =  b;
                end
                ST8_REG_E:
                begin
                    DOutput   =  e;                                                
                    ALU8_B  =  e;
                end
                ST8_REG_F:
                begin
                    DOutput   =  f;                                                
                    ALU8_B  =  f;
                end
            endcase

            cc_nxt =  ALU8[15:8];

            rLIC = 1'b1; // Instruction done!            
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end

        // Is Figure 18/5 Column 5?  (Load, 16 bits)
        else if (IsALU16Op & (ALU16Op == ALUOP16_LD)) begin
            addr_nxt   =  ea;
            ea_nxt     =  ea_p1;
            case (ALU16Reg)
                ALU16_REG_X:
                    x_nxt[15:8]    =  D[7:0];
                ALU16_REG_D:
                    a_nxt          =  D[7:0];
                ALU16_REG_W:
                    e_nxt          =  D[7:0];
                ALU16_REG_Y:
                    y_nxt[15:8]    =  D[7:0];
                ALU16_REG_S:
                    s_nxt[15:8]    =  D[7:0];                                
                ALU16_REG_U:
                    u_nxt[15:8]    =  D[7:0];
                default:
                begin
                end
            endcase
            rAVMA = 1'b1;
            rBUSY = 1'b1;
            CpuState_nxt   =  CPUSTATE_LD16_LO;
				end

        // Is Figure 18/5 Column 6?  (Store, 16 bits)
        else if (IsStore16)
        begin
            addr_nxt       =  ea;
            ea_nxt         =  ea_p1;

            ALU16_OP       =  ALUOP16_LD;   // LD and ST have the same CC characteristics
            ALU16_CC       =  cc;
            ALU16_A        =  8'H00;

            case (StoreRegisterNum)
                ST16_REG_X:
                begin
                    DOutput[7:0]  =  x[15:8];
                    ALU16_B    =  x;
                end
                ST16_REG_Y:
                begin
                    DOutput[7:0]  =  y[15:8];
                    ALU16_B    =  y;
                end
                ST16_REG_U:
                begin
                    DOutput[7:0]  =  u[15:8];
                    ALU16_B    =  u;                    
                end
                ST16_REG_S:
                begin
                    DOutput[7:0]  =  s[15:8];
                    ALU16_B    =  s;                    
                end
                ST16_REG_D:
                begin
                    DOutput[7:0]  =  a[7:0];
                    ALU16_B    =  {a,b};
                end
                ST16_REG_W:
                begin
                    DOutput[7:0]  =  e[7:0];
                    ALU16_B    =  {e,f};
                end
                default:
                begin
                end
            endcase

            cc_nxt = ALU16[23:16];

            RnWOut         =  0;        // Write
            rAVMA          =  1'b1;
            rBUSY          =  1'b1;
            CpuState_nxt   =  CPUSTATE_ST16_LO;
        end

        // Is Figure 18/5 Column 7?
        else if (IsALU8Set0(Inst1))
        begin
            // These are registerless instructions, ala
            // ASL, ASR, CLR, COM, DEC, INC, (LSL), LSR, NEG, ROL, ROR
            // and TST (special!)
            // They require READ, Modify (the operation above), WRITE.  Between the Read and the Write cycles, there's actually a /VMA
            // cycle where the 6809 likely did the operation.  We'll include a /VMA cycle for accuracy, but we'll do the work primarily in the first cycle.              
            addr_nxt       =  ea;
            
            ALU8_OP =  ALU8Op;       
            ALU8_A  =  D[7:0];
            ALU8_CC =  cc;
            tmp_nxt[15:8] = cc;  // for debug only
            tmp_nxt[7:0]   =  ALU8[7:0];
            cc_nxt =  ALU8[15:8];
            if (ALU8Op == ALU8OP_TST)
            begin
                rAVMA = 1'b0;
                CpuState_nxt = CPUSTATE_TST_DONTCARE1;
            end
            else
            begin
                rAVMA = 1'b0;
                rBUSY = 1'b1;
                CpuState_nxt   =  CPUSTATE_ALU_DONTCARE;
            end

        end

        // Is Figure 18/5 Column 8?  TST
        // NOTE:
        // THIS IS BURIED IN THE COLUMN 3 section with comparisons to ALUOP_TST.  [Directly above.]

        // Is Figure 18/5 Column 9?  (16-bit ALU ops, non-load)
        else if (IsALU16Op && (ALU16Op != ALUOP16_LD) && ((Inst1 < 8'H30) || (Inst1 > 8'H33)) ) // 30-33 = LEAX, LEAY, LEAS, LEAU; don't include them here.
        begin
            addr_nxt       =  ea;
            ea_nxt =  ea_p1;
            
            tmp_nxt[15:8]  =  D[7:0];
            rAVMA = 1'b1;
            rBUSY = 1'b1;
            CpuState_nxt   =  CPUSTATE_ALU16_LO;
            
        end

        // Is Figure 18/5 Column 10?  JSR (not Immediate Mode)
        else if ((Inst1 == 8'H9D) || (Inst1 == 8'HAD) || (Inst1 == 8'HBD))      // JSR
        begin
            pc_nxt =  ea;
            addr_nxt   =  ea;
            tmp_nxt    =  pc;
            rAVMA = 1'b0;
            CpuState_nxt   =  CPUSTATE_JSR_DONTCARE;
        end
        // Is Figure 18/5 Column 11?  LEA(X,Y,S,U)
        else if ((Inst1 >= 8'H30) && (Inst1<= 8'H33))
        begin
            addr_nxt = 16'HFFFF; // Ack, actually a valid cycle, this isn't a dontcare (/VMA) cycle!

            ALU16_OP       =  ALU16Op;
            ALU16_CC       =  cc;
            ALU16_A        =  ea;

            case (ALU16Reg)
                ALU16_REG_X:
                    {cc_nxt, x_nxt}    =  ALU16; 
                ALU16_REG_Y:
                    {cc_nxt, y_nxt}    =  ALU16;
                ALU16_REG_U:
                    u_nxt = ALU16[15:0];
                ALU16_REG_S:
                    s_nxt = ALU16[15:0];
                default:
                begin
                end
            endcase

            rLIC = 1'b1; // Instruction done!        
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;

        end

    end

    CPUSTATE_ALU_DONTCARE:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b1;
        rBUSY = 1'b1; // We do nothing here, but on the real 6809, they did the modify phase here.  :|
        CpuState_nxt   =  CPUSTATE_ALU_WRITEBACK;
    end

    CPUSTATE_ALU_WRITEBACK:
    begin
        addr_nxt       =  ea;
        RnWOut =  0;    // Write
        DOutput   =  tmp[7:0];
        rLIC = 1'b1; // Instruction done!      
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end

    CPUSTATE_LD16_LO: begin
        addr_nxt       =  ea;
        case (ALU16Reg)
            ALU16_REG_X:
            begin
                x_nxt[7:0] =  D[7:0];
                ALU16_B[15:8] = x[15:8]; // entire ALU16_B must be set in this cycle;
            end
            ALU16_REG_D:
            begin
                b_nxt      =  D[7:0];
                ALU16_B[15:8] = a;
            end
            ALU16_REG_W:
            begin
                f_nxt      =  D[7:0];
                ALU16_B[15:8] = e;
            end
            ALU16_REG_Y:
            begin
                y_nxt[7:0] =  D[7:0];
                ALU16_B[15:8] = y[15:8];                
            end
            ALU16_REG_S:
            begin
                s_nxt[7:0] =  D[7:0];                                
                ALU16_B[15:8] = s[15:8];                
            end
            ALU16_REG_U:
            begin
                u_nxt[7:0] =  D[7:0];                                
                ALU16_B[15:8] = u[15:8];                
            end
            default:
            begin
            end
        endcase
        ALU16_OP       =    ALU16Op;
        ALU16_CC       =    cc;
        ALU16_A        =    8'H00;        
        ALU16_B[7:0]   =    D[7:0];
        cc_nxt         =    ALU16[23:16];
        rLIC = 1'b1; // Instruction done!        
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
		end
		
		
		CPUSTATE_LD32_B2316: begin
			addr_nxt = ea;
			ea_nxt = ea_p1;
			b_nxt = D;
			ALUTmp_nxt[15:8] = D;
			rAVMA = 1'b1;
			CpuState_nxt = CPUSTATE_LD32_B1508;
			end
		CPUSTATE_LD32_B1508: begin
			addr_nxt = ea;
		ea_nxt = ea_p1;
			e_nxt = D;
			ALUTmp_nxt[7:0] = D;
			rAVMA = 1'b1;
			CpuState_nxt = CPUSTATE_LD32_B0700;
			end
		CPUSTATE_LD32_B0700: begin
			addr_nxt = ea;
			f_nxt = D;
			ALU32_OP = ALU32Op;
			ALU32_CC = cc;
			ALU32_A = 32'H00000000;
			ALU32_B = {ALUTmp[23:0], D};
			cc_nxt = ALU32[39:32];
			rAVMA = 1'b1;
			CpuState_nxt = CPUSTATE_FETCH_I1;
			rLIC = 1'b1; // Instruction done!        
			end
	 
	 
	 CPUSTATE_ST32_B2316:
	 begin
		addr_nxt = ea;
		ea_nxt = ea_p1;
		DOutput = b;
		RnWOut = 0; // Write
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_ST32_B1508;   
	 end
	 CPUSTATE_ST32_B1508:
	 begin
		addr_nxt = ea;
		ea_nxt = ea_p1;
		DOutput = e;
		RnWOut = 0; // Write
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_ST32_B0700;   
	 end
	 CPUSTATE_ST32_B0700:
	 begin
		addr_nxt = ea;
		ea_nxt = ea_p1;
		DOutput = f;
		ALU32_OP = ALUOP32_LD;  // LD and ST have the same CC characteristics
		ALU32_CC = cc;
		ALU32_A = 32'H00000000;
		ALU32_B = {a,b,e,f}; // 32-bit value to store is already known this early, so go ahead and run it through ALU
		cc_nxt = ALU32[39:32]; // get CC byte from live ALU function result
		RnWOut = 0; // Write
       rLIC = 1'b1; // Instruction done!        
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;   
	 end

    CPUSTATE_ST16_LO:
    begin
        addr_nxt       =  ea;
        ea_nxt =  ea_p1;
        case (StoreRegisterNum)
            ST16_REG_X:
                DOutput[7:0]  =  x[7:0];
            ST16_REG_Y:
                DOutput[7:0]  =  y[7:0];
            ST16_REG_U:
                DOutput[7:0]  =  u[7:0];
            ST16_REG_S:
                DOutput[7:0]  =  s[7:0];
            ST16_REG_D:
                DOutput[7:0]  =  b[7:0];
            ST16_REG_W:
                DOutput[7:0]  =  f[7:0];
            default:
            begin
            end
        endcase
        RnWOut     =  0;        // write
 
        rLIC = 1'b1; // Instruction done!        
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;                
    end

    CPUSTATE_ALU16_LO: // no 32-bit ALU instructions so no need to try to dupe this state?
    begin
        addr_nxt       =  ea;

        ALU16_OP       =  ALU16Op;
        ALU16_CC       =  cc;

        ALU16_B        =  {tmp[15:8], D[7:0]};

        case (ALU16Reg)
            ALU16_REG_X:
                ALU16_A        =  x;
            ALU16_REG_D:
                ALU16_A        =  {a, b};
            ALU16_REG_W:
                ALU16_A        =  {e, f};
            ALU16_REG_Y:
                ALU16_A        =  y;
            ALU16_REG_S:
                ALU16_A        =  s;                                
            ALU16_REG_U:
                ALU16_A        =  u;      
            default:
                ALU16_A        =  16'H0;
   
        endcase

        if (ALU16OpWriteback)
        begin
            case (ALU16Reg)
                ALU16_REG_X:
                    {cc_nxt, x_nxt}        =  ALU16; 
                ALU16_REG_D:
                    {cc_nxt, a_nxt, b_nxt} =  ALU16;
                ALU16_REG_W:
                    {cc_nxt, e_nxt, f_nxt} =  ALU16;
                ALU16_REG_Y:
                    {cc_nxt, y_nxt}        =  ALU16;
                ALU16_REG_U:
                    {cc_nxt, u_nxt}        =  ALU16;
                ALU16_REG_S:
                    {cc_nxt, s_nxt}        =  ALU16;
                default:
                begin
                end
            endcase
        end
        else
            cc_nxt = ALU16[23:16];
			rAVMA = 1'b0;
			CpuState_nxt   =  CPUSTATE_ALU16_DONTCARE;
    end

    CPUSTATE_ALU16_DONTCARE:
    begin
        addr_nxt = 16'HFFFF;
        rLIC = 1'b1; // Instruction done!        
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end

    
    CPUSTATE_JSR_DONTCARE:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_JSR_RETLO;
    end
    
    CPUSTATE_JSR_RETLO:
    begin
        addr_nxt       =  s_m1;
        s_nxt  =  s_m1;
        RnWOut =  0;
        DOutput   =  tmp[7:0];
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_JSR_RETHI;
    end
    
    CPUSTATE_JSR_RETHI:
    begin
        addr_nxt       =  s_m1;
        s_nxt  =  s_m1;
        RnWOut =  0;
        DOutput   =  tmp[15:8];
        rLIC = 1'b1; // Instruction done!        
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_FETCH_I1;
    end
    
    CPUSTATE_EXTENDED_ADDRLO:
    begin
        addr_nxt       =  pc;
        pc_nxt =  pc_p1;
        ea_nxt[7:0]    =  D[7:0];
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_EXTENDED_DONTCARE;
    end
    
    CPUSTATE_EXTENDED_DONTCARE:
    begin
        addr_nxt       =  16'HFFFF;
        if (IsJMP(InstPage2, InstPage3, Inst1))
        begin
            pc_nxt =  ea;
            rLIC = 1'b1; // Instruction done!            
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end
        else
        begin
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_ALU_EA;
        end
    end
    
    CPUSTATE_INDEXED_BASE:
    begin
        addr_nxt       =  pc;

        Inst3_nxt      =  D[7:0];
        
        case (IndexedRegister)
            IDX_REG_X:
                ALU16_A        =  x;
            IDX_REG_Y:
                ALU16_A        =  y;
            IDX_REG_U:
                ALU16_A        =  u;
            IDX_REG_S:
                ALU16_A        =  s;
				IDX_REG_W:
					ALU16_A = {e, f};
            IDX_REG_PC:
                ALU16_A        =  pc_p1;
            default:
                ALU16_A        =  16'H0;
        endcase
        ALU16_OP       =  ALUOP16_ADD;                    
        
        case (IndexedMode)
            IDX_MODE_NOOFFSET:
            begin
                case (IndexedRegister)
                    IDX_REG_X:
                        ea_nxt =  x;
                    IDX_REG_Y:
                        ea_nxt =  y;
                    IDX_REG_U:
                        ea_nxt =  u;
                    IDX_REG_S:
                        ea_nxt =  s;
							IDX_REG_W:
								ea_nxt = {e, f};
                    default:
                        ea_nxt =  16'H0;
                endcase
                
                if (IndexedIndirect)
                begin
                    rAVMA = 1'b1;
                    CpuState_nxt   =  CPUSTATE_INDIRECT_HI;
                end
                else
                begin
                    if (IsJMP(InstPage2, InstPage3, Inst1))
                    begin
                        pc_nxt =  ea_nxt;
                        rLIC = 1'b1; // Instruction done!                        
                        rAVMA = 1'b1;
                        CpuState_nxt   =  CPUSTATE_FETCH_I1;
                    end
                    else
                    begin
                        rAVMA = 1'b1;
                        CpuState_nxt   =  CPUSTATE_ALU_EA;
                    end
                end
            end
            
            IDX_MODE_5BIT_OFFSET:
            begin
                // The offset is the bottom 5 bits of the Index Postbyte, which is Inst2 here.
                // We'll sign-extend it to 16 bits.
                ALU16_B    =  { {11{Inst2[4]}}, Inst2[4:0] };
                ea_nxt     =  ALU16[15:0]; 
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_DONTCARE3;
            end


            IDX_MODE_8BIT_OFFSET_PC:
            begin
                ALU16_B        =  { {8{D[7]}}, D[7:0] };
                pc_nxt =  pc_p1;
                ea_nxt =  ALU16[15:0];
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_DONTCARE3;
            end
            
            IDX_MODE_8BIT_OFFSET:
            begin
                ALU16_B        =  { {8{D[7]}}, D[7:0] };
                pc_nxt =  pc_p1;
                ea_nxt =  ALU16[15:0];
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_DONTCARE3;
            end
            
            IDX_MODE_A_OFFSET:
            begin
                ALU16_B        =  { {8{a[7]}}, a[7:0] };
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_DONTCARE3;
                ea_nxt =  ALU16[15:0];
            end
            
            IDX_MODE_E_OFFSET:
            begin
                ALU16_B        =  { {8{e[7]}}, e[7:0] };
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_DONTCARE3;
                ea_nxt =  ALU16[15:0];
            end

            IDX_MODE_B_OFFSET:
            begin
                ALU16_B    =  { {8{b[7]}}, b[7:0] };
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_DONTCARE3;
                ea_nxt =  ALU16[15:0];
            end
            
            IDX_MODE_F_OFFSET:
            begin
                ALU16_B    =  { {8{f[7]}}, f[7:0] };
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_DONTCARE3;
                ea_nxt =  ALU16[15:0];
            end

            IDX_MODE_D_OFFSET:
            begin
                ALU16_B    =  {a, b};
                
                ea_nxt     =  ALU16[15:0];
                rAVMA = 1'b1;
                CpuState_nxt = CPUSTATE_IDX_DOFF_DONTCARE1;
            end
            
            IDX_MODE_W_OFFSET:
            begin
                ALU16_B    =  {e, f};
                
                ea_nxt     =  ALU16[15:0];
                rAVMA = 1'b1;
                CpuState_nxt = CPUSTATE_IDX_DOFF_DONTCARE1;
            end

            IDX_MODE_POSTINC1:
            begin
                ALU16_B    =  16'H1;
                ea_nxt     =  ALU16_A;
                case (IndexedRegister)
                IDX_REG_X:
                    x_nxt      =  ALU16[15:0];
                IDX_REG_Y:
                    y_nxt      =  ALU16[15:0];
                IDX_REG_U:
                    u_nxt      =  ALU16[15:0];
                IDX_REG_S:
                    s_nxt      =  ALU16[15:0];
					IDX_REG_W:
							{e_nxt, f_nxt} = ALU16[15:0];
                default:
                begin
                end
                endcase
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE2;  
            end
            
            IDX_MODE_POSTINC2:
            begin
                ALU16_B        =  16'H2;
                ea_nxt =  ALU16_A;
                case (IndexedRegister)
                    IDX_REG_X:
                        x_nxt  =  ALU16[15:0];
                    IDX_REG_Y:
                        y_nxt  =  ALU16[15:0];
                    IDX_REG_U:
                        u_nxt  =  ALU16[15:0];
                    IDX_REG_S:
                        s_nxt  =  ALU16[15:0];
							IDX_REG_W:
									{e_nxt, f_nxt} = ALU16[15:0];
                    default:
                    begin
                    end
                endcase
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE0;
            end
            
            IDX_MODE_PREDEC1:
            begin
                ALU16_B        =  16'HFFFF;     // -1
                case (IndexedRegister)
                    IDX_REG_X:
                        x_nxt  =  ALU16[15:0];
                    IDX_REG_Y:
                        y_nxt  =  ALU16[15:0];
                    IDX_REG_U:
                        u_nxt  =  ALU16[15:0];
                    IDX_REG_S:
                        s_nxt  =  ALU16[15:0];
							IDX_REG_W:
									{e_nxt, f_nxt} = ALU16[15:0];
                    default:
                    begin
                    end
                endcase
                ea_nxt =  ALU16[15:0];
                rAVMA = 1'b0;
                CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE2;                              
            end
            
            IDX_MODE_PREDEC2:
            begin
                ALU16_B        =  16'HFFFE;     // -2
                case (IndexedRegister)
                    IDX_REG_X:
                        x_nxt  =  ALU16[15:0];
                    IDX_REG_Y:
                        y_nxt  =  ALU16[15:0];
                    IDX_REG_U:
                        u_nxt  =  ALU16[15:0];
                    IDX_REG_S:
                        s_nxt  =  ALU16[15:0];
							IDX_REG_W:
									{e_nxt, f_nxt} = ALU16[15:0];
                    default:
                    begin
                    end
                endcase
                ea_nxt =  ALU16[15:0];
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE0;                            
            end
            
            IDX_MODE_16BIT_OFFSET_PC:            
            begin
                tmp_nxt[15:8]  =  D[7:0];
                pc_nxt =  pc_p1;
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_IDX_16OFFSET_LO;
            end

            IDX_MODE_16BIT_OFFSET:
            begin
                tmp_nxt[15:8]  =  D[7:0];
                pc_nxt =  pc_p1;
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_IDX_16OFFSET_LO;
            end

            IDX_MODE_EXTENDED_INDIRECT:
            begin
                ea_nxt[15:8] = D[7:0];
                pc_nxt =  pc_p1;
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_IDX_EXTIND_LO;
            end
            
            default:
            begin
                rLIC = 1'b1;
                CpuState_nxt = PostIllegalState;
            end
            
        endcase
    end
    
    CPUSTATE_IDX_OFFSET_LO:
    begin
        tmp_nxt[7:0]   =  D[7:0];
        addr_nxt       =  pc;
        pc_nxt =  pc_p1;
        ALU16_B    =  tmp_nxt;
        
        case (IndexedRegister)
            IDX_REG_X:
                ALU16_A    =  x;
            IDX_REG_Y:
                ALU16_A    =  y;
            IDX_REG_U:
                ALU16_A    =  u;
            IDX_REG_S:
                ALU16_A    =  s;
				IDX_REG_W:
					ALU16_A = {e, f};
            IDX_REG_PC:
                ALU16_A    =  pc;
            default:
                ALU16_A    =  16'H0;
        endcase
        ALU16_OP   =  ALUOP16_ADD;                    
        
        ea_nxt     =  ALU16[15:0];
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE1;
    end
    
    
    CPUSTATE_IDX_DONTCARE3:
    begin
        addr_nxt   =  16'HFFFF;
        if (IndexedIndirect)
        begin
            rAVMA = 1'b1;
            CpuState_nxt = CPUSTATE_INDIRECT_HI;
        end
        else
        begin
            if (IsJMP(InstPage2, InstPage3, Inst1))
            begin
                pc_nxt =  ea;
                rLIC = 1'b1; // Instruction done!                
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_FETCH_I1;
            end
            else
            begin
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_ALU_EA;
            end
        end

    end                
    
    CPUSTATE_IDX_16OFFSET_LO:
    begin
        addr_nxt       =  pc;
        pc_nxt =  pc_p1;

        case (IndexedRegister)
            IDX_REG_X:
                ALU16_A    =  x;
            IDX_REG_Y:
                ALU16_A    =  y;
            IDX_REG_U:
                ALU16_A    =  u;
            IDX_REG_S:
                ALU16_A    =  s;
				IDX_REG_W:
						ALU16_A = {e, f};
            IDX_REG_PC:
                ALU16_A    =  pc_nxt;  // Whups; tricky; not part of the actual pattern
            default:
                ALU16_A    =  x; // Default to something
        endcase

        ALU16_OP   =  ALUOP16_ADD;                    
        
        ALU16_B    =  {tmp[15:8], D[7:0]};
        
        ea_nxt     =  ALU16[15:0];
        rAVMA = 1'b1;
        CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE1;
    end
    
    CPUSTATE_IDX_16OFF_DONTCARE1:
    begin
        addr_nxt       =  pc;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE2;
    end

    CPUSTATE_IDX_16OFF_DONTCARE0:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE2;
    end

    CPUSTATE_IDX_16OFF_DONTCARE2:
    begin
        addr_nxt       =  16'HFFFF;
        if (IndexedRegister == IDX_REG_PC)
        begin
            rAVMA = 1'b0;
            CpuState_nxt = CPUSTATE_IDX_PC16OFF_DONTCARE;
        end
        else        
        begin
            rAVMA = 1'b0;
            CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE3;
        end
    end
    
    CPUSTATE_IDX_PC16OFF_DONTCARE:
    begin
        addr_nxt       =  16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt   =  CPUSTATE_IDX_16OFF_DONTCARE3;
    end
    
    
    CPUSTATE_IDX_16OFF_DONTCARE3:
    begin
        addr_nxt       =  16'HFFFF;
        if (IndexedIndirect)
        begin
            rAVMA = 1'b1;
            CpuState_nxt = CPUSTATE_INDIRECT_HI;
        end
        else
        begin
            if (IsJMP(InstPage2, InstPage3, Inst1))
            begin
                pc_nxt =  ea;
                rLIC = 1'b1; // Instruction done!                
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_FETCH_I1;
            end
            else
            begin
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_ALU_EA;        
            end
        end
    end

    CPUSTATE_IDX_DOFF_DONTCARE1:
    begin
        addr_nxt = pc_p1;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_IDX_DOFF_DONTCARE2;
    end

    CPUSTATE_IDX_DOFF_DONTCARE2:
    begin
        addr_nxt = pc_p2;
        rAVMA = 1'b0;
        CpuState_nxt = CPUSTATE_IDX_16OFF_DONTCARE2;
    end

//    CPUSTATE_IDX_DOFF_DONTCARE3:
//    begin
//        addr_nxt = pc_p3;
//        rAVMA = 1'b1;
//        CpuState_nxt = CPUSTATE_IDX_DOFF_DONTCARE2;
//    end

    CPUSTATE_IDX_EXTIND_LO:
    begin
        ea_nxt[7:0]   =  D[7:0];
        addr_nxt       =  pc;
        pc_nxt =  pc_p1;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_IDX_EXTIND_DONTCARE;        
    end
    
    CPUSTATE_IDX_EXTIND_DONTCARE:
    begin
        addr_nxt = pc;
        if (IndexedIndirect)
        begin
            rAVMA = 1'b1;
            CpuState_nxt = CPUSTATE_INDIRECT_HI;
        end
        else
        begin
            if (IsJMP(InstPage2, InstPage3, Inst1))
            begin
                pc_nxt =  ea;
                rLIC = 1'b1; // Instruction done!                
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_FETCH_I1;
            end
            else
            begin
                rAVMA = 1'b1;
                CpuState_nxt   =  CPUSTATE_ALU_EA;        
            end
        end
    end
    
    CPUSTATE_INDIRECT_HI:
    begin
        addr_nxt = ea;
        tmp_nxt[15:8] = D[7:0];
        rAVMA = 1'b1;
        rBUSY = 1'b1;
        CpuState_nxt = CPUSTATE_INDIRECT_LO;
    end                        

    CPUSTATE_INDIRECT_LO:
    begin
        addr_nxt = ea_p1;
        ea_nxt[15:8] = tmp_nxt[15:8];
        ea_nxt[7:0] = D[7:0];
        rAVMA = 1'b0;
        CpuState_nxt = CPUSTATE_INDIRECT_DONTCARE;
    end
 
    CPUSTATE_INDIRECT_DONTCARE:
    begin
        addr_nxt = 16'HFFFF;
        if (IsJMP(InstPage2, InstPage3, Inst1))
        begin
            pc_nxt =  ea;
            rLIC = 1'b1; // Instruction done!            
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_FETCH_I1;
        end
        else
        begin
            rAVMA = 1'b1;
            CpuState_nxt   =  CPUSTATE_ALU_EA;
        end
    end
    
    CPUSTATE_MUL_ACTION:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b0;
        // tmp = result
        // ea = additor (the shifted multiplicand)
        // a = counter
        // b is the multiplier (which gets shifted right)
        if (a != 8'H00) // on each E cycle do this segment, when MUL is completely done, code will continue
        begin // always 11 cycles?
            if (b[0])
            begin
                tmp_nxt = tmp + ea;
            end
            ea_nxt = {ea[14:0], 1'b0};
            b_nxt = {1'b0, b[7:1]};
            a_nxt = a - 8'H1;
        end
        else
        begin
            {a_nxt, b_nxt} = tmp;
            
            cc_nxt[CC_Z_BIT] = (tmp == 0);
            cc_nxt[CC_C_BIT] = tmp[7];
            rLIC = 1'b1; // Instruction done!            
            rAVMA = 1'b1;
            CpuState_nxt = CPUSTATE_FETCH_I1;
        end
    end

	CPUSTATE_LDMD: begin
		addr_nxt = 16'HFFFF;
		rAVMA = 1'b0; // next cycle doesn't use RAM
		CpuState_nxt   =  CPUSTATE_LDMD_DONTCARE;
		end
	CPUSTATE_LDMD_DONTCARE: begin
		addr_nxt = 16'HFFFF;
		rAVMA = 1'b1;
		CpuState_nxt   =  CPUSTATE_FETCH_I1;
		end		
		
	 
	CPUSTATE_LOAD_BIT: begin // need to fetch 3rd instruction byte, then read the contents of that memory address, then do ALU cycle

//		addr_nxt = pc; // points to instruction byte containing the 8-bit address to read from
//		pc_nxt = pc_p1; // skip over it
//		// tell ALU8 what to do
//		ALU8_A = ALUTmp[7:0]; // from prev cycle
//		ALU8_B = D[7:0];
//		ALU8_CC = cc;
//		ALU8_OP = ALU8Op; // assign whatever op was deduced from instruction
//		case ALUTmp[7:6]
//			2'b00: begin // store bit to CC register
//				cc_nxt = ALU8[7:0]; get back CC from ALU8
//				end
//			2'b01: begin // store bit to A register
//				cc_nxt = ALU8[15:8]; get back CC from ALU8
//				end
//			2'b02: begin // store bit to B register
//				cc_nxt = ALU8[15:8]; get back CC from ALU8
//				end
//			default:
//				cc_nxt = ALU8[15:8]; get back CC from ALU8
//		endcase
		rLIC = 1'b1; // Instruction done!            
		rAVMA = 1'b1;
		CpuState_nxt = CPUSTATE_FETCH_I1;
		end
		
		
		
	 
    CPUSTATE_PSH_DONTCARE1:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt = CPUSTATE_PSH_DONTCARE2;
    end

    CPUSTATE_PSH_DONTCARE2:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_PSH_DONTCARE3;
    end
    
    CPUSTATE_PSH_DONTCARE3:
    begin
        addr_nxt = (Inst1[1]) ? u : s;
//        rAVMA = 1'b1; // was missing from Miller's code
        CpuState_nxt = CPUSTATE_PSH_ACTION;
    end    

    CPUSTATE_PSH_ACTION:
    begin
        rAVMA = 1'b1;
        if (tmp[7] & ~(tmp[15]))                    // PC_LO
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = pc[7:0];
            RnWOut = 1'b0; // write
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[7] & (tmp[15]))                    // PC_HI
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = pc[15:8];
            RnWOut = 1'b0; // write
            tmp_nxt[7] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end
        else if (tmp[6] & ~(tmp[15]))                    // U/S_LO
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = (tmp[14]) ? s[7:0] : u[7:0]; 
            RnWOut = 1'b0; // write
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[6] & (tmp[15]))                    // U/S_HI
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = (tmp[14]) ? s[15:8] : u[15:8]; 
            RnWOut = 1'b0; // write
            tmp_nxt[6] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end
        else if (tmp[5] & ~(tmp[15]))                    // Y_LO
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = y[7:0];
            RnWOut = 1'b0; // write
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[5] & (tmp[15]))                    // Y_HI
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = y[15:8];
            RnWOut = 1'b0; // write
            tmp_nxt[5] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end        
        else if (tmp[4] & ~(tmp[15]))                    // X_LO
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = x[7:0];
            RnWOut = 1'b0; // write
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[4] & (tmp[15]))                    // X_HI
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = x[15:8];
            RnWOut = 1'b0; // write
            tmp_nxt[4] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end
        else if (tmp[3])                    // DP
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = dp;
            RnWOut = 1'b0; // write
            tmp_nxt[3] = 1'b0;        
        end
        else if (tmp[9])                    // F
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = f;
            RnWOut = 1'b0; // write
            tmp_nxt[9] = 1'b0;            
        end
        else if (tmp[8])                    // E
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = e;
            RnWOut = 1'b0; // write
            tmp_nxt[8] = 1'b0;
        end
        else if (tmp[2])                    // B
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = b;
            RnWOut = 1'b0; // write
            tmp_nxt[2] = 1'b0;        
        end
        else if (tmp[1])                    // A
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = a;
            RnWOut = 1'b0; // write
            tmp_nxt[1] = 1'b0;        
        end
        else if (tmp[0])                    // CC
        begin
            addr_nxt = (tmp[14]) ? u_m1 : s_m1;
            if (tmp[14])
                u_nxt = u_m1;
            else
                s_nxt = s_m1;
            DOutput = cc;
            RnWOut = 1'b0; // write
            tmp_nxt[0] = 1'b0;        
        end
        if (tmp[13]) // Then we're pushing for an IRQ, and LIC is supposed to be set.
            rLIC = 1'b1;
        if (tmp_nxt[9:0] == 10'b0000000000)
        begin
            if (NextState == CPUSTATE_FETCH_I1)
            begin
                rAVMA = 1'b1;
                rLIC = 1'b1;
            end
            else
                rAVMA = 1'b0;
            CpuState_nxt  = NextState;
        end                                           
    end
    
    CPUSTATE_PUL_DONTCARE1:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt = CPUSTATE_PUL_DONTCARE2;
    end

    CPUSTATE_PUL_DONTCARE2:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_PUL_ACTION;
    end    

    CPUSTATE_PUL_ACTION:
    begin
        rAVMA = 1'b1;
        if (tmp[0])                    // CC
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
					cc_nxt = D[7:0];
            if (tmp[12] == 1'b1) // This pull is from an RTI, the E flag comes from the retrieved CC, and set the tmp_nxt accordingly, indicating what other registers to retrieve
            begin
                if (D[CC_E_BIT])
                    tmp_nxt[9:0] = { md[0], md[0], 8'HFE };     // Retrieve all registers (ENTIRE) [CC is already retrieved]
                else
                    tmp_nxt[9:0] = { 1'b0, 1'b0, 8'H80 };     // Retrieve PC and CC [CC is already retrieved]
            end
            else
                tmp_nxt[0] = 1'b0;
        end 
        else if (tmp[1])                    // A
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            a_nxt = D[7:0];
            tmp_nxt[1] = 1'b0;
        end         
        else if (tmp[2])                    // B
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            b_nxt = D[7:0];
            tmp_nxt[2] = 1'b0;
        end
        else if (tmp[8])                    // E
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            e_nxt = D[7:0];
            tmp_nxt[8] = 1'b0;
        end
        else if (tmp[9])                    // F
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            f_nxt = D[7:0];
            tmp_nxt[9] = 1'b0;            
        end
        else if (tmp[3])                    // DP
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            dp_nxt = D[7:0];
            tmp_nxt[3] = 1'b0;
        end        
        else if (tmp[4] & (~tmp[15]))                    // X_HI
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            x_nxt[15:8] = D[7:0];
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[4] & tmp[15])                    // X_LO
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            x_nxt[7:0] = D[7:0];
            tmp_nxt[4] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end
        else if (tmp[5] & (~tmp[15]))                    // Y_HI
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            y_nxt[15:8] = D[7:0];
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[5] & tmp[15])                    // Y_LO
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            y_nxt[7:0] = D[7:0];
            tmp_nxt[5] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end
        else if (tmp[6] & (~tmp[15]))                    // U/S_HI
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            if (tmp[14])
                s_nxt[15:8] = D[7:0];
            else
                u_nxt[15:8] = D[7:0];
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[6] & tmp[15])                    // U/S_LO
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            if (tmp[14])
                s_nxt[7:0] = D[7:0];
            else
                u_nxt[7:0] = D[7:0];
            tmp_nxt[6] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end
        else if (tmp[7] & (~tmp[15]))                    // PC_HI
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            pc_nxt[15:8] = D[7:0];
            tmp_nxt[15] = 1'b1;            
        end
        else if (tmp[7] & tmp[15])                    // PC_LO
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (tmp[14])
                u_nxt = u_p1;
            else
                s_nxt = s_p1;
            pc_nxt[7:0] = D[7:0];
            tmp_nxt[7] = 1'b0;
            tmp_nxt[15] = 1'b0;            
        end
        else
        begin
            addr_nxt = (tmp[14]) ? u : s;
            if (NextState == CPUSTATE_FETCH_I1)
            begin
                rAVMA = 1'b1;
                rLIC = 1'b1;
            end
            else
                rAVMA = 1'b0;
            CpuState_nxt  = NextState;
        end  
    end

	 
    CPUSTATE_NMI_START: // Save to the S stack, PC, U, Y, X, DP, F?, E?, B, A, CC; set LIC on every push 
    begin
        NMIClear_nxt = 1'b1;
        addr_nxt = pc;
			tmp_nxt = {6'b001000, md[0], md[0], 8'b11111111}; // either $20FF or $23FF  (E/F to stack if native 6309 mode)
        IntType_nxt = INTTYPE_NMI;
        CpuState_nxt = CPUSTATE_IRQ_DONTCARE;
        NextState_nxt = CPUSTATE_IRQ_DONTCARE2;
        cc_nxt[CC_E_BIT] = 1'b1;
        rAVMA = 1'b0;
    end

	 
    CPUSTATE_IRQ_START: // Save to the S stack, PC, U, Y, X, DP, F?, E?, B, A, CC; set LIC on every push 
    begin
        addr_nxt = pc;
			tmp_nxt = {6'b001000, md[0], md[0], 8'b11111111}; // either $20FF or $23FF  (E/F to stack if native 6309 mode)
        NextState_nxt = CPUSTATE_IRQ_DONTCARE2;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_IRQ_DONTCARE;
        IntType_nxt = INTTYPE_IRQ;        
        cc_nxt[CC_E_BIT] = 1'b1;
    end

	 
	CPUSTATE_FIRQ_START: // Save to the S stack, PC, CC; set LIC on every push 
	begin
		addr_nxt = pc;
		tmp_nxt = {8'b00100000, 8'b10000001}; //  PC,-,-,-,-,-,-,cc
//		tmp_nxt = 16'H2081;
		IntType_nxt = INTTYPE_FIRQ;
		if ( md[1] ) // 6309 - treat FIRQ like IRQ
			begin
				IntType_nxt = INTTYPE_IRQ;
				tmp_nxt = {6'b001000, md[0], md[0], 8'b11111111}; // either $20FF or $23FF  (E/F to stack if native 6309 mode) but also Entire state?
			end
		CpuState_nxt = CPUSTATE_IRQ_DONTCARE;
		NextState_nxt = CPUSTATE_IRQ_DONTCARE2;
		cc_nxt[CC_E_BIT] = 1'b0;
		rAVMA = 1'b1;
	end

	
    CPUSTATE_SWI_START: // Save to the S stack, PC, U, Y, X, DP, F?, E?, B, A, CC
    begin
        addr_nxt = pc;
			tmp_nxt = {6'b000000, md[0], md[0], 8'b11111111}; // either $20FF or $23FF  (E/F to stack if native 6309 mode)
        NextState_nxt = CPUSTATE_IRQ_DONTCARE2;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_IRQ_DONTCARE;
        if (InstPage3)
            IntType_nxt = INTTYPE_SWI3;
        if (InstPage2)
            IntType_nxt = INTTYPE_SWI2;
        else
            IntType_nxt = INTTYPE_SWI;        
        cc_nxt[CC_E_BIT] = 1'b1;
    end
    
    CPUSTATE_IRQ_DONTCARE:
    begin
        NMIClear_nxt = 1'b0;    
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_PSH_ACTION;
    end
    
    
    CPUSTATE_IRQ_DONTCARE2:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_IRQ_VECTOR_HI;
        rLIC = 1'b1;
    end
    
    CPUSTATE_IRQ_VECTOR_HI:
    begin
        case (IntType)
            INTTYPE_NMI:
            begin
                addr_nxt = `NMI_VECTOR;
                BS_nxt         =  1'b1; // ACK Interrupt
            end
            INTTYPE_IRQ:
            begin
                addr_nxt = `IRQ_VECTOR;
                BS_nxt         =  1'b1; // ACK Interrupt
            end
            INTTYPE_SWI:
            begin
                addr_nxt = `SWI_VECTOR;
            end
            INTTYPE_FIRQ:
            begin
                addr_nxt = `FIRQ_VECTOR;
                BS_nxt         =  1'b1; // ACK Interrupt
            end
            INTTYPE_SWI2:
            begin
                addr_nxt = `SWI2_VECTOR;
            end
            INTTYPE_SWI3:
            begin
                addr_nxt = `SWI3_VECTOR;
            end
            default: // make the default an IRQ, even though it really should never happen 
            begin
                addr_nxt = `IRQ_VECTOR;
                BS_nxt         =  1'b1; // ACK Interrupt
            end
        endcase
        
        pc_nxt[15:8] = D[7:0];
        rAVMA = 1'b1;
        rBUSY = 1'b1;
        rLIC = 1'b1;
        CpuState_nxt = CPUSTATE_IRQ_VECTOR_LO;
        
        
    end
    
    CPUSTATE_IRQ_VECTOR_LO:
    begin
        case (IntType)
            INTTYPE_NMI:
            begin
                addr_nxt = `NMI_VECTOR+16'H1;
                cc_nxt[CC_I_BIT] = 1'b1;
                cc_nxt[CC_F_BIT] = 1'b1;
                BS_nxt         =  1'b1; // ACK Interrupt
            end                
            INTTYPE_IRQ:
            begin
                addr_nxt = `IRQ_VECTOR+16'H1;
                cc_nxt[CC_I_BIT] = 1'b1;                
                BS_nxt         =  1'b1; // ACK Interrupt
            end  
            INTTYPE_SWI:
            begin
                addr_nxt = `SWI_VECTOR+16'H1;
                cc_nxt[CC_F_BIT] = 1'b1;
                cc_nxt[CC_I_BIT] = 1'b1;
                rLIC = 1'b1;
            end                  
            INTTYPE_FIRQ:
            begin
                addr_nxt = `FIRQ_VECTOR+16'H1;
                cc_nxt[CC_F_BIT] = 1'b1;                                
                cc_nxt[CC_I_BIT] = 1'b1;
                BS_nxt         =  1'b1; // ACK Interrupt
            end                  
            INTTYPE_SWI2:
            begin
                addr_nxt = `SWI2_VECTOR+16'H1;
                rLIC = 1'b1;                
            end                  
            INTTYPE_SWI3:
            begin
                addr_nxt = `SWI3_VECTOR+16'H1;
                rLIC = 1'b1;
            end                
            default:
            begin
            end
        endcase
    
        pc_nxt[7:0] = D[7:0];
        rAVMA = 1'b1;
        rLIC = 1'b1;
        CpuState_nxt = CPUSTATE_INT_DONTCARE;
    end
    
    CPUSTATE_INT_DONTCARE:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        rLIC = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end

    CPUSTATE_CC_DONTCARE:
    begin
        addr_nxt = pc;
        rLIC = 1'b1;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end

    CPUSTATE_TST_DONTCARE1:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b0;
        CpuState_nxt = CPUSTATE_TST_DONTCARE2;
    end

    CPUSTATE_TST_DONTCARE2:
    begin
        addr_nxt = 16'HFFFF;
        rLIC = 1'b1;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end

    CPUSTATE_DEBUG:
    begin
        addr_nxt = tmp;
        rLIC = 1'b1;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end
    
    CPUSTATE_16IMM_DONTCARE:
    begin
        addr_nxt = 16'HFFFF;
        rLIC = 1'b1;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end
    
    CPUSTATE_SYNC:
    begin
        addr_nxt = 16'HFFFF;
        BA_nxt = 1'b1;
        rLIC   = 1'b1;
        rAVMA  = 1'b0;

        if (~(NMILatched & FIRQLatched & IRQLatched))
        begin
            CpuState_nxt = CPUSTATE_SYNC_EXIT;
        end
    end

    CPUSTATE_SYNC_EXIT:
    begin
        addr_nxt = 16'HFFFF;
        BA_nxt = 1'b1;
        rLIC   = 1'b1;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end


    CPUSTATE_DMABREQ:
    begin
        rAVMA = 1'b0;
        addr_nxt = 16'HFFFF;
        BS_nxt = 1'b1;
        BA_nxt = 1'b1;
        rLIC   = 1'b1;
        tmp_nxt[3:0] = tmp[3:0] - 1'b1; // count down 15-cycle timer
        if ( (tmp[3:0] == 4'H0) | (DMABREQLatched) ) // exit when counter reaches 0, or DMAREQ is released
        begin
            CpuState_nxt = CPUSTATE_DMABREQ_EXIT;
        end
    end
    
    CPUSTATE_DMABREQ_EXIT:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end
    
    CPUSTATE_HALTED:
    begin
        rAVMA = 1'b0;
        addr_nxt = 16'HFFFF;
        BS_nxt = 1'b1;
        BA_nxt = 1'b1;
        rLIC   = 1'b1;
        if (HALTSample2) // if (HALTLatched)
        begin
            CpuState_nxt = CPUSTATE_HALT_EXIT2;
        end
    end


    CPUSTATE_HALT_EXIT2:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_FETCH_I1;
    end

    CPUSTATE_STOP:
    begin
        addr_nxt = 16'HDEAD;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_STOP2;
    end

    CPUSTATE_STOP2:
    begin
        addr_nxt = pc;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_STOP3;
    end

    CPUSTATE_STOP3:
    begin
        addr_nxt = 16'H0000; //{Inst1, Inst2};
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_STOP;
    end

	 
    // The otherwise critically useful Figure 18 in the 6809 datasheet contains an error;
    // it lists that CWAI has a tri-stated bus while it waits for an interrupt.
    // That is not true.  SYNC tristates the bus, as do things like /HALT and /DMABREQ.
    // CWAI does not.  It waits with /VMA cycles on the bus until an interrupt occurs.
    // The implementation here fits with the 6809 Programming Manual and other Motorola
    // sources, not with that typo in Figure 18.
    CPUSTATE_CWAI:
    begin
        addr_nxt = pc;
        cc_nxt = {1'b1, (cc[6:0] & Inst2[6:0])}; // Set E flag, AND CC with CWAI argument
        tmp_nxt = 16'H00FF; // Save to the S stack, PC, U, Y, X, DP, B, A, CC

        NextState_nxt = CPUSTATE_CWAI_POST;
        rAVMA = 1'b0;
        CpuState_nxt = CPUSTATE_CWAI_DONTCARE1;
    end
    
    CPUSTATE_CWAI_DONTCARE1:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b1;
        CpuState_nxt = CPUSTATE_PSH_ACTION;
    end
    
    CPUSTATE_CWAI_POST:
    begin
        addr_nxt = 16'HFFFF;
        rAVMA = 1'b0;

        CpuState_nxt = CPUSTATE_CWAI_POST;

        // Wait for an interrupt
        if (NMILatched == 0)
        begin
            rAVMA = 1'b1;
            IntType_nxt = INTTYPE_NMI;
            cc_nxt[CC_F_BIT] = 1'b1;
            cc_nxt[CC_I_BIT] = 1'b1;
            CpuState_nxt = CPUSTATE_IRQ_VECTOR_HI;
        end
        else if ((FIRQLatched == 0) && (cc[CC_F_BIT] == 0))
        begin
            rAVMA = 1'b1;
            cc_nxt[CC_F_BIT] = 1'b1;
            cc_nxt[CC_I_BIT] = 1'b1;
            IntType_nxt = INTTYPE_FIRQ;
            CpuState_nxt = CPUSTATE_IRQ_VECTOR_HI;
        end
        else if ((IRQLatched == 0) && (cc[CC_I_BIT] == 0))
        begin
            rAVMA = 1'b1;
            cc_nxt[CC_I_BIT] = 1'b1;
            IntType_nxt = INTTYPE_IRQ;
            CpuState_nxt = CPUSTATE_IRQ_VECTOR_HI;
        end
    end

    default: // Picky darned Verilog.
    begin
        CpuState_nxt = PostIllegalState;
    end
    
    endcase
end

endmodule

