module sdram_arbiter (
    input clk,
    input reset,

    // Port 0: IOCTL (Highest Priority, Write Only)
    input         p0_req,
    input  [24:0] p0_addr,
    input   [7:0] p0_din,
    output reg    p0_ready,
    output wire   p0_busy,

    // Port 1: CPU (Read Only)
    input         p1_req,
    input  [24:0] p1_addr,
    output reg [7:0] p1_dout,
    output reg    p1_ready,

    // Port 2: Tilemap (Read Only)
    input         p2_req,
    input  [24:0] p2_addr,
    output reg [7:0] p2_dout,
    output reg    p2_ready,

    // Port 3: Sprites (Read Only)
    input         p3_req,
    input  [24:0] p3_addr,
    output reg [7:0] p3_dout,
    output reg    p3_ready,

    // Port 3 in-flight indicator (2026-08-14, Test 221): exposes
    // latched_p3_req directly so other modules can tell whether a Port 3
    // transaction is registered/in-flight anywhere in the pipeline (from
    // the cycle p3_req is latched through dispatch/wait/complete/cooldown),
    // not just whether p3_req happens to be pulsing THIS exact cycle --
    // k007420 only asserts sprite_sdram_req for a single cycle, so a raw
    // p3_req check would see "idle" while a request is still fully
    // in-flight, letting a concurrent Port 2 request slip in and recreate
    // the same contention it was meant to avoid (caught by Gemini review
    // before this was ever deployed).
    output wire   p3_active,

    // SDRAM Controller Interface
    output reg [24:0] sdram_addr,
    output reg        sdram_rd,
    output reg        sdram_we,
    output reg [15:0] sdram_din,
    input      [15:0] sdram_dout,
    input             sdram_ready,
    output wire [1:0] sdram_wtbt
);

    reg [2:0] state;
    reg [1:0] active_port;
    reg wait_flag;
    reg rr_toggle; // Round-robin toggle between Tilemaps (Port 2) and Sprites (Port 3)

    // Test 215 (2026-08-14): under sustained P2+P3 contention, the round-robin
    // above previously flipped rr_toggle after every single transaction --
    // the maximum possible SDRAM bus switching rate. Tests 206/210/211 found a
    // stable ~35-46% read-corruption rate under exactly this concurrent
    // pattern that simulation cannot reproduce (Test 212: 1000/1000 pass in
    // an idealized model) and that more read-recovery margin didn't fix (Test
    // 211) -- consistent with a physical/electrical effect from rapid
    // switching between two usually-distant address regions (tile ROM vs
    // sprite ROM), not a logic bug. This batches up to BATCH_MAX consecutive
    // transactions per port before yielding, to test whether reducing the
    // switch *frequency* (not the total contention volume) reduces the
    // corruption rate. Diagnostic-only experiment: does not change dispatch
    // behavior when only one of P2/P3 is requesting.
    localparam [2:0] BATCH_MAX = 3'd7; // up to 8 consecutive transactions per port
    reg [2:0] batch_streak;

    // sdram.sv 8-bit mode: wtbt=2'b00 means sdram.sv uses addr[0] to select byte for WRITES.
    // However, for READS, sdram_dout is always the 16-bit word. We must select the correct byte.
    assign sdram_wtbt = 2'b00;
    
    // sdram.sv line 93 routes the requested byte (whether even or odd addr) into sdram_dout[15:8]
    wire [7:0] sdram_byte_out = sdram_dout[15:8];

    reg latched_p0_req, latched_p1_req, latched_p2_req, latched_p3_req;
    // p0_busy must reflect p0_req the SAME cycle it's first asserted, not one
    // cycle later once latched_p0_req has registered -- otherwise HPS's IOCTL
    // stream, which can sample ioctl_wait combinationally, sees "not busy" for
    // one cycle and advances to the next byte before the arbiter has actually
    // started processing the current one, silently dropping it during rapid
    // back-to-back streaming (confirmed via a local FPGA-internal SDRAM
    // loopback self-test: single isolated writes always succeed, but this is
    // the only difference between that and the real multi-byte IOCTL download).
    assign p0_busy = p0_req | latched_p0_req;

    reg [24:0] latched_p0_addr, latched_p1_addr, latched_p2_addr, latched_p3_addr;
    reg [7:0] latched_p0_din;
    
    reg last_p0_req;
    reg last_p0_addr_valid;

    // Removed latched_sdram_ready: sdram.sv's `ready` is a level signal that stays
    // high from the PREVIOUS idle period until it sees the rd/we edge in state 1 --
    // in the gap between leaving state 0 and that edge (states 4 and the start of
    // 1), state!=0 so the old latch's reset-clear no longer applied, while
    // sdram_ready was still the stale pre-request high value, so it latched true
    // almost immediately. State 2 then reported "done" before the real SDRAM
    // transaction had even been issued, sampling stale/zero data instead of
    // waiting out the actual CAS latency. Waiting on live sdram_ready directly is
    // correct here since it genuinely drops low once the request is registered.
    always @(posedge clk) begin
        if (reset) begin
            state <= 0;
            p0_ready <= 0;
            p1_ready <= 0;
            p2_ready <= 0;
            p3_ready <= 0;
            sdram_rd <= 0;
            sdram_we <= 0;
            latched_p0_req <= 0;
            latched_p1_req <= 0;
            latched_p2_req <= 0;
            latched_p3_req <= 0;
            last_p0_req <= 0;
            last_p0_addr_valid <= 0;
            rr_toggle <= 0;
            batch_streak <= 3'd0;
        end else begin
            // Port 0 handshaking for continuous or pulsed ioctl_wr from hps_io
            last_p0_req <= p0_req;
            if (p0_req && !latched_p0_req && (!last_p0_req || p0_addr != latched_p0_addr || last_p0_addr_valid == 1'b0)) begin 
                latched_p0_req <= 1; 
                latched_p0_addr <= p0_addr; 
                latched_p0_din <= p0_din; 
                last_p0_addr_valid <= 1'b1;
            end
            
            if (p1_req && !latched_p1_req) begin latched_p1_req <= 1; latched_p1_addr <= p1_addr; end

            if (p2_req && !latched_p2_req) begin latched_p2_req <= 1; latched_p2_addr <= p2_addr; end

            if (p3_req && !latched_p3_req) begin latched_p3_req <= 1; latched_p3_addr <= p3_addr; end

            // Default pulse clear
            p0_ready <= 0;
            p1_ready <= 0;
            p2_ready <= 0;
            p3_ready <= 0;
            
            case (state)
                0: begin // Idle / Arbitration
                    if (sdram_ready) begin
                        if (latched_p0_req) begin
                            sdram_addr <= latched_p0_addr;
                            sdram_din <= {latched_p0_din, latched_p0_din}; // sdram.v handles mask
                            active_port <= 0;
                            state <= 4; // Setup cycle: allow addr & din to stabilize on bus before command strobe
                        end else if (latched_p1_req) begin // CPU 6809 Main ROM
                            sdram_addr <= latched_p1_addr;
                            active_port <= 1;
                            state <= 4;
                        end else if (latched_p2_req && latched_p3_req) begin
                            // Both Tilemaps and Sprites requesting: batch up to
                            // BATCH_MAX consecutive transactions per port before
                            // flipping rr_toggle (Test 215 -- see comment at
                            // batch_streak's declaration above).
                            if (rr_toggle == 1'b0) begin
                                sdram_addr <= latched_p2_addr;
                                active_port <= 2;
                                if (batch_streak >= BATCH_MAX) begin
                                    rr_toggle <= 1'b1;
                                    batch_streak <= 3'd0;
                                end else begin
                                    batch_streak <= batch_streak + 3'd1;
                                end
                                state <= 4;
                            end else begin
                                sdram_addr <= latched_p3_addr;
                                active_port <= 3;
                                if (batch_streak >= BATCH_MAX) begin
                                    rr_toggle <= 1'b0;
                                    batch_streak <= 3'd0;
                                end else begin
                                    batch_streak <= batch_streak + 3'd1;
                                end
                                state <= 4;
                            end
                        end else if (latched_p2_req) begin
                            sdram_addr <= latched_p2_addr;
                            active_port <= 2;
                            state <= 4;
                        end else if (latched_p3_req) begin
                            sdram_addr <= latched_p3_addr;
                            active_port <= 3;
                            state <= 4;
                        end
                    end
                end

                4: begin // Strobe Command (sdram_addr & sdram_din are 100% stable and valid)
                    if (active_port == 0) begin
                        sdram_we <= 1;
                    end else begin
                        sdram_rd <= 1;
                    end
                    state <= 1;
                    wait_flag <= 1;
                end
                
                1: begin // Wait for SDRAM to accept command
                    sdram_rd <= 0;
                    sdram_we <= 0;
                    if (wait_flag) begin
                        wait_flag <= 0; // Wait 1 cycle for sdram.v to update ready flag
                    end else if (!sdram_ready) begin // Normal read/write
                        state <= 2;
                    end else begin // Fast-read (sdram.v cached the word and kept ready high)
                        state <= 2;
                    end
                end
                
                2: begin // Wait for SDRAM to finish
                    if (sdram_ready) begin
                        // Read or Write complete
                        if (active_port == 0) begin
                            p0_ready <= 1;
                        end else if (active_port == 1) begin
                            p1_dout <= sdram_byte_out;
                            p1_ready <= 1;
                        end else if (active_port == 2) begin
                            p2_dout <= sdram_byte_out;
                            p2_ready <= 1;
                        end else if (active_port == 3) begin
                            p3_dout <= sdram_byte_out;
                            p3_ready <= 1;
                        end
                        state <= 3;
                    end
                end
                
                3: begin // Cooldown (ensures requesters deassert their req)
                    // Reverted to pre-Test-169 form (2026-08-12, Test 176): Test 169's
                    // re-sample-instead-of-clear change is the prime suspect for the
                    // self-test (diag_byte1-3 RED) and GAME-OVER-background static
                    // regressions seen in every test since -- both persisted unchanged
                    // even with Test 171-175's p3_ready_sticky mechanism in k007420.v
                    // completely removed, isolating the cause to this file. Testing this
                    // revert in isolation to confirm before re-examining Test 169's
                    // actual back-to-back-request race on its own.
                    case (active_port)
                        0: latched_p0_req <= 0;
                        1: latched_p1_req <= 0;
                        2: latched_p2_req <= 0;
                        3: latched_p3_req <= 0;
                    endcase
                    state <= 0;
                end
            endcase
        end
    end

    assign p3_active = latched_p3_req;

endmodule
