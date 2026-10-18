// Mixer for the two YM3812 chips of the GX7 series sound board (Sound Settings OSD page).
//
// vol1 / vol2 select the level of each chip in sixteenths: index 0 = 16/16 (100%, the real board), 1 = 15/16 ... 15 = 1/16, 16 or more = off.
// With both at index 0 and stereo low the output is EXACTLY the old mix (rounded average of the two chips, identical on both outputs), because
// (x * 16) >>> 4 is x: the defaults reproduce the original audio bit for bit (checked in verilator_ddr/snd_mixer_tb.cpp).
// stereo high splits the chips: chip 1 on the left output, chip 2 on the right, each at its own level.
module snd_mixer (
    input  signed [15:0] ym1,
    input  signed [15:0] ym2,
    input          [4:0] vol1,
    input          [4:0] vol2,
    input                stereo,
    output signed [15:0] audio_l,
    output signed [15:0] audio_r
);

wire [4:0] g1 = (vol1 > 5'd16) ? 5'd0 : (5'd16 - vol1);   // gain in sixteenths, 0..16
wire [4:0] g2 = (vol2 > 5'd16) ? 5'd0 : (5'd16 - vol2);

wire signed [21:0] p1 = ym1 * $signed({1'b0, g1});
wire signed [21:0] p2 = ym2 * $signed({1'b0, g2});
wire signed [15:0] s1 = p1 >>> 4;
wire signed [15:0] s2 = p2 >>> 4;

wire signed [16:0] mixed_raw     = $signed(s1) + $signed(s2);
wire signed [16:0] mixed_rounded = mixed_raw + 17'sd1;
wire signed [15:0] mixed_audio   = mixed_rounded >>> 1;    // rounded average of the two chips, as the board mixes them

assign audio_l = stereo ? s1 : mixed_audio;
assign audio_r = stereo ? s2 : mixed_audio;

endmodule
