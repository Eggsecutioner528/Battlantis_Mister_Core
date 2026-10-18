// Treble control for the final mixed audio: a one pole low pass filter, y += (x - y) / 2^N, updated at the 3 MHz YM3812 rate (ce).
//   mode 0  Original: the input is passed through untouched (bit for bit the mix)
//   mode 1  Soft:     N = 6, corner about 7.5 kHz
//   mode 2  Softer:   N = 7, corner about 3.7 kHz
//   mode 3  Muffled:  N = 8, corner about 1.9 kHz
// The filter keeps running in Original mode (with N = 6), so switching modes has no click. State: 16 bit sample times 512 (9 fractional bits, so even
// N = 8 settles to within half an LSB), the difference needs one more bit.
module audio_lp (
    input                clk,
    input                ce,
    input          [1:0] mode,
    input  signed [15:0] in_l,
    input  signed [15:0] in_r,
    output signed [15:0] out_l,
    output signed [15:0] out_r
);
    reg  signed [24:0] y_l = 25'sd0, y_r = 25'sd0;
    wire signed [25:0] d_l = $signed({in_l, 9'd0}) - y_l;
    wire signed [25:0] d_r = $signed({in_r, 9'd0}) - y_r;
    wire         [3:0] sh  = (mode == 2'd0) ? 4'd6 : (4'd5 + {2'b00, mode});   // 6, 6, 7, 8
    always @(posedge clk) if (ce) begin
        y_l <= y_l + (d_l >>> sh);
        y_r <= y_r + (d_r >>> sh);
    end
    assign out_l = (mode == 2'd0) ? in_l : y_l[24:9];
    assign out_r = (mode == 2'd0) ? in_r : y_r[24:9];
endmodule
