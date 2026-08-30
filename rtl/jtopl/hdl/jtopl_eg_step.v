/*  This file is part of JTOPL.

    JTOPL is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTOPL is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTOPL.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 17-6-2020

    */

module jtopl_eg_step(
    input             attack,
    input      [ 4:0] base_rate,
    input      [ 3:0] keycode,
    input      [14:0] eg_cnt,
    input             cnt_in,
    input             ksr,
    output            cnt_lsb,
    output reg        step,
    output reg [ 5:0] rate,
    output reg        sum_up
);

reg  [6:0]   pre_rate;
wire [1:0]   shby;

assign shby = ksr ? 2'd1 : 2'd3;

always @(*) begin : pre_rate_calc
    if( base_rate == 5'd0 )
        pre_rate = 7'd0;
    else
        pre_rate = { 1'b0, base_rate, 1'b0 } +  // base_rate LSB is always zero except for RR
            ({ 3'b0, keycode } >> shby);
end

always @(*)
    rate = pre_rate>=7'b1111_00 ? 6'b1111_11 : pre_rate[5:0];

reg [2:0] cnt;

reg [4:0] mux_sel;
always @(*) begin
    mux_sel = attack ? (rate[5:2]+4'd1): {1'b0,rate[5:2]};
end

always @(*) 
    case( mux_sel )
        5'h0:    cnt = eg_cnt[13:11];
        5'h1:    cnt = eg_cnt[12:10];
        5'h2:    cnt = eg_cnt[11: 9];
        5'h3:    cnt = eg_cnt[10: 8];
        5'h4:    cnt = eg_cnt[ 9: 7];
        5'h5:    cnt = eg_cnt[ 8: 6];
        5'h6:    cnt = eg_cnt[ 7: 5];
        5'h7:    cnt = eg_cnt[ 6: 4];
        5'h8:    cnt = eg_cnt[ 5: 3];
        5'h9:    cnt = eg_cnt[ 4: 2];
        5'ha:    cnt = eg_cnt[ 3: 1];
        default: cnt = eg_cnt[ 2: 0];
    endcase

////////////////////////////////
reg [7:0] step_idx;

always @(*) begin : rate_step
    if( rate[5:4]==2'b11 ) begin // 0 means 1x, 1 means 2x
        if( rate[5:2]==4'hf && attack)
            step_idx = 8'b11111111; // Maximum attack speed, rates 60&61
        else
        case( rate[1:0] )
            2'd0: step_idx = 8'b00000000;
            2'd1: step_idx = 8'b10001000; // 2
            2'd2: step_idx = 8'b10101010; // 4
            2'd3: step_idx = 8'b11101110; // 6
        endcase
    end
    else begin
        if( rate[5:2]==4'd0 && !attack)
            step_idx = 8'b11111110; // limit slowest decay rate
        else
        case( rate[1:0] )
            2'd0: step_idx = 8'b10101010; // 4
            2'd1: step_idx = 8'b11101010; // 5
            2'd2: step_idx = 8'b11101110; // 6
            2'd3: step_idx = 8'b11111110; // 7
        endcase
    end
    // a rate of zero keeps the level still
    step = rate[5:1]==5'd0 ? 1'b0 : step_idx[ cnt ];
end

assign cnt_lsb = cnt[0];

// 2026-08-20, task #8 round 68: real, verified, deterministic bug found and
// fixed (not a Cyclone V synthesis artifact, not metastability). At the
// maximum attack rate (rate[5:2]==4'hf, the same condition already
// special-cased above for step_idx), mux_sel = rate[5:2]+1 = 16 during
// ATTACK -- outside the case statement's explicit 0-10 range above, so it
// falls to `default: cnt=eg_cnt[2:0]`, selecting eg_cnt's own bit 0. Since
// this engine time-multiplexes exactly 18 operator slots round-robin
// (SLOTS=18 throughout jtopl_eg.v), this same slot's own cnt[0]/cnt_in
// comparison happens exactly 18 cenop cycles apart -- and because 18 is
// even while bit 0 has period 2, that comparison can NEVER see a
// difference: verified computationally (zero transitions in a direct
// simulation of this exact bit-vs-18-cycle-delay relationship, vs. every
// other bit position 1-13 all showing real, working transitions). This
// structurally prevents sum_up from ever firing for this one specific,
// narrow rate/attack combination -- independent of any FPGA vendor,
// device, or synthesis tool -- which is exactly the parameter combination
// Battlantis's own real channel-0 note lands on (AR=15 saturates rate to
// 63 given this note's keycode=0). Fixed the same way the step_idx special
// case above already implies real hardware intent for maximum attack rate
// (unconditional maximum step every opportunity): force sum_up true too,
// under the identical guard, rather than relying on a toggle-detection
// scheme that cannot work for this one case. Every other rate/mux_sel
// combination (i.e. every case already explicitly enumerated above) is
// completely unaffected.
wire max_attack_case = rate[5:2]==4'hf && attack;
always @(*) begin
    sum_up = max_attack_case ? 1'b1 : (cnt[0] != cnt_in);
end

endmodule // eg_step