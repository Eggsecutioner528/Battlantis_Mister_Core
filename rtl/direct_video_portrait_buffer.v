// Prototype (simulation-only, not yet wired into Battlantis.sv): write-time-
// capture / read-time-transpose frame buffer for Task #24's Direct Video
// portrait rotation. Captures the native 256x224 landscape-shaped raw raster
// into a ping-pong buffer, then reads it back out in transposed order to
// reconstruct the game's true 224(wide) x 256(tall) portrait orientation.
//
// CANDIDATE is a prototype-only switch to empirically confirm which of two
// plausible transpose formulas matches the ground truth established by
// sys/arcade_video.v's screen_rotate module (rotate_ccw=0, do_flip=0 path):
//   out_row = src_col, out_col = 223 - src_row
//   => native_h = out_row, native_v = 223 - out_col   (CANDIDATE=0)
// CANDIDATE=1 is the other plausible mapping, kept only so the testbench can
// show the wrong one really does come out wrong.
module direct_video_portrait_buffer #(
    parameter CANDIDATE = 0
) (
    input clk,

    // Write side: native raw raster, 256 active columns x 224 active rows.
    input        wr_en,       // pulse once per native active pixel
    input  [7:0] wr_col,      // 0-255 (native h_cnt within active window)
    input  [7:0] wr_row,      // 0-223 (native v_cnt within active window)
    input [23:0] wr_pixel,    // {r,g,b}
    input        wr_frame_end, // pulse once at native vblank boundary (swap)

    // Read side: output raster, 224 active columns x 256 active rows.
    input        rd_en,
    input  [7:0] rd_col,      // 0-223
    input  [8:0] rd_row,      // 0-255
    output reg [23:0] rd_pixel
);

    // Two ping-pong buffers sized for the native active window.
    reg [23:0] buf0 [0:(256*224)-1];
    reg [23:0] buf1 [0:(256*224)-1];
    reg        write_sel = 0; // which buffer is currently being written

    wire [16:0] wr_addr = wr_row * 256 + wr_col;

    always @(posedge clk) begin
        if (wr_en) begin
            if (write_sel == 0) buf0[wr_addr] <= wr_pixel;
            else                buf1[wr_addr] <= wr_pixel;
        end
        if (wr_frame_end) write_sel <= ~write_sel;
    end

    // Read side always reads the buffer NOT currently being written.
    wire [7:0] native_h = (CANDIDATE == 0) ? rd_row[7:0] : (8'd255 - rd_row[7:0]);
    wire [7:0] native_v = (CANDIDATE == 0) ? (8'd223 - rd_col) : rd_col;
    wire [16:0] rd_addr = native_v * 256 + native_h;

    always @(posedge clk) begin
        if (rd_en) begin
            if (write_sel == 0) rd_pixel <= buf1[rd_addr]; // read the OTHER buffer
            else                rd_pixel <= buf0[rd_addr];
        end
    end

endmodule
