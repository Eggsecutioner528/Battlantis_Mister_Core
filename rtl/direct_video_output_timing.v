// Prototype (simulation-only, not yet wired into Battlantis.sv): output-side
// timing generator for Task #24's Direct Video portrait rotation buffer.
//
// Deliberately keeps the horizontal rate identical to the native raster
// (H_total=384 @ 6MHz = 15,625 Hz, same as Battlantis.sv's existing h_cnt) --
// only the active window narrows from 256 to 224 columns and re-centers,
// giving 80 blanked columns on each side (pillarbox bars). The hsync pulse
// keeps the exact same absolute position/width as the native generator
// (Battlantis.sv:2060, h_cnt>=320 && h_cnt<352) since that falls entirely
// within the new trailing blank segment (304-383) and doesn't need to move.
//
// Vertical grows from V_total=262/264 (224 active) to V_total=288 (256
// active), giving 32 blanking lines instead of ~38-40 -- still enough for a
// real front/back porch + sync pulse, at a frame rate of 15625/288 ~= 54.25Hz.
// vsync is placed proportionally within the new, smaller blanking budget the
// same way the native generator places it within its own blanking budget
// (Battlantis.sv:2061, v_cnt>=244 && v_cnt<247 -- offset ~20 lines into a
// ~38-line blanking region, roughly mid-blanking); scaled down here to
// roughly mid-blanking in the new, smaller 32-line window.
module direct_video_output_timing (
    input clk,
    input ce_pix, // pixel-rate enable; tie high in this prototype

    output reg [8:0] out_h_cnt, // 0-383
    output reg [8:0] out_v_cnt, // 0-287
    output           out_hsync,
    output           out_vsync,
    output           out_active, // true within the centered 224x256 window
    output     [7:0] out_col,    // 0-223, valid when out_active
    output     [8:0] out_row     // 0-255, valid when out_active
);

    localparam H_TOTAL = 384;
    localparam V_TOTAL = 288;

    localparam H_ACTIVE   = 224;
    localparam H_BORDER   = (H_TOTAL - H_ACTIVE) / 2; // 80
    localparam H_ACT_START = H_BORDER;                // 80
    localparam H_ACT_END   = H_BORDER + H_ACTIVE;     // 304 (exclusive)

    localparam V_ACTIVE = 256;

    always @(posedge clk) begin
        if (ce_pix) begin
            if (out_h_cnt == H_TOTAL - 1) begin
                out_h_cnt <= 0;
                out_v_cnt <= (out_v_cnt == V_TOTAL - 1) ? 9'd0 : out_v_cnt + 9'd1;
            end else begin
                out_h_cnt <= out_h_cnt + 9'd1;
            end
        end
    end

    // Same absolute position/width as the native hsync -- falls entirely
    // within the new trailing blank segment (304-383), no collision with
    // the re-centered active window (80-303).
    assign out_hsync = (out_h_cnt >= 320 && out_h_cnt < 352);

    // Mid-blanking placement scaled to the new 32-line blanking budget
    // (256 active + 32 blank = 288 total): 16 lines back porch, 3-line
    // pulse, 13 lines front porch -- proportionally similar to the native
    // generator's ~20-line-in/3-wide/~15-16-remaining split over ~38 lines.
    assign out_vsync = (out_v_cnt >= 272 && out_v_cnt < 275);

    assign out_active = (out_h_cnt >= H_ACT_START && out_h_cnt < H_ACT_END) &&
                         (out_v_cnt < V_ACTIVE);

    assign out_col = out_h_cnt[7:0] - H_ACT_START[7:0]; // 0-223 when active
    assign out_row = out_v_cnt;                          // 0-255 when active

endmodule
