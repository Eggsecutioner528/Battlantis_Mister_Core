/*  2026-08-19, task #8 (Battlantis MiSTer core): RAM-based reimplementation
    of jtopl_sh_rst.v, used only for jtopl_eg.v's u_egsh instance (the
    envelope generator's persistent per-slot storage).

    Extensive real-hardware bisection (rounds 30-49, see
    project_history/debugging_log.md) individually verified every signal
    upstream of this component correct on real Cyclone V hardware -- the
    real bus-level Key-On write, the internal Key-On edge-detect, the
    shared envelope timebase, the rate calculation, the full CPU-side
    interrupt/ISR delivery path, and sum_up_II (the actual per-cycle
    "apply an update now" decision) all confirmed genuinely correct and
    active -- yet the envelope's stored value, read back both as the final
    TL-modulated eg_V and the raw pre-modulation eg_in_I directly, never
    updates even once across 40+ real seconds. The identical Verilog
    source produces a correct, audible-range envelope climb in ModelSim's
    behavioral simulation, isolating this to a real, synthesis-specific
    defect in jtopl_sh_rst.v's per-bit shift-register-array implementation
    at this specific instantiation's parameters (width=10, stages=15) --
    the only 10-bit-wide instance of that module in jtopl_eg.v; the two
    narrower instances (1-bit keyon_last_I, 3-bit state_in_I) are both
    confirmed working.

    This reimplements the exact same functional behavior -- an N-stage
    delay line, with a serial-fill reset requiring `stages` cycles of held
    reset to fully flush (matching jtopl_sh_rst.v's own real, already-
    verified-correct reset timing, round 42) -- using a RAM-inferred
    circular buffer (read-before-write same-address idiom) instead of a
    per-bit shift-register array, to route around whatever specific
    synthesis defect affects the wide/deep shift-register version on this
    device. jtopl_sh_rst.v itself is left completely untouched, still used
    by u_egstate/u_konsh, both confirmed working correctly.

    2026-08-24, task #8 round 146: the paragraph above is now STALE and
    describes only the round-50 state. Current, verified-against-the-actual-
    code status of every jtopl_sh_rst/jtopl_sh_rst_ram instance in this
    design:
      - jtopl_eg.v's u_egsh:    jtopl_sh_rst_ram (this module) -- the ONE
        instance with an independently confirmed real synthesis defect in
        jtopl_sh_rst.v (rounds 30-49, width=10/stages=15).
      - jtopl_eg.v's u_egstate: jtopl_sh_rst_ram, since round 52 -- applied
        speculatively "for consistency" per Gemini's round-51 theory, NEVER
        independently confirmed to have its own synthesis defect.
      - jtopl_eg.v's u_konsh:   jtopl_sh_rst_ram, since round 140 -- brought
        along to match u_egstate's timing; round 74's and round 140's own
        real-hardware tests of exactly this swap both found NO CHANGE to
        the channel-0/7/8 stuck-envelope symptom.
      - jtopl_csr.v's u_regch (the actual AR/DR/SL/RR/keycode register
        storage jtopl_eg_ctrl.v combines with the signals above): still
        plain jtopl_sh_rst (combinational read) -- round 69 tried swapping
        THIS to jtopl_sh_rst_ram too and it caused a real REGRESSION,
        reverted (see debugging_log.md line ~1048).

    Net effect: u_egsh/u_egstate/u_konsh are now mutually consistent with
    each other (all registered-read, `stages` cycles), but ALL THREE are
    one cycle further delayed than jtopl_csr.v's own u_regch (still
    combinational-read, `stages-1` cycles) -- a real, current, CONFIRMED
    mismatch between "this slot's persistent envelope state" and "this
    slot's register parameters" that neither of the two previously-tried
    "make them match" directions (round 74/140's and round 69's) actually
    fixed. The genuinely untested direction: u_egstate/u_konsh were never
    independently proven to need the RAM-based swap at all -- reverting
    THEM back to plain jtopl_sh_rst (keeping only u_egsh, which has an
    independently confirmed defect, on the RAM version) would restore
    every other delay line to the SAME relative timing as upstream jtopl2's
    own unmodified design (the same one Haunted Castle's real, working
    MiSTer core runs unmodified) -- not yet tried.
*/

module jtopl_sh_rst_ram #(parameter width=10, stages=15, rstval=1'b0)
(
    input                   rst,
    input                   clk,
    input                   cen,
    input      [width-1:0]  din,
    output reg [width-1:0]  drop
);

localparam AW = $clog2(stages);

// 2026-08-19, task #8 round 54: ptr needs a defined power-up value. On
// real Cyclone V hardware this is implicit (unreset FPGA registers power up
// to 0 by default, the same convention jtopl_sh.v's own unreset shift
// registers already rely on elsewhere in this design -- round 41). But
// ptr's update is self-referential (ptr <= (ptr==stages-1) ? 0 : ptr+1),
// unlike a plain shift register: if ptr ever starts as X (as ModelSim's
// behavioral simulation gives any register with no explicit initializer),
// (ptr==stages-1) evaluates to X forever, so ptr can never escape X no
// matter how long the testbench warms up -- a real simulation deadlock,
// not merely a slow-flush artifact. Confirmed directly: round 54's
// testbench run (identical source otherwise, reaches a real 3954 dB peak
// per round 29) came back fully X end-to-end (snd=x throughout) once this
// module replaced jtopl_sh_rst.v for u_egsh/u_egstate (rounds 50/52).
// Fixing with a standard initial-block power-up value -- Quartus supports
// this as the FPGA's actual power-up state for inferred registers, so it
// changes nothing about real hardware behavior, only makes simulation
// match it.
reg [AW-1:0]    ptr = {AW{1'b0}};
reg [width-1:0] mem [0:stages-1];

// ptr must keep advancing during reset (not freeze at a fixed address) so
// that the serial-fill reset sweeps through all `stages` entries over
// `stages` held-reset cycles, exactly matching jtopl_sh_rst.v's own real
// reset requirement.
always @(posedge clk) if (cen) begin
    ptr      <= (ptr == stages-1) ? {AW{1'b0}} : ptr + 1'b1;
    drop     <= mem[ptr];
    mem[ptr] <= rst ? {width{rstval[0]}} : din;
end

endmodule
