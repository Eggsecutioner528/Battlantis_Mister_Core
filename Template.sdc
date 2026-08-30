derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ==============================================================================
# SDRAM interface I/O timing constraints
# ==============================================================================
# Confirmed via Template.sta.rpt's "Unconstrained Output Ports" report: SDRAM_CLK,
# SDRAM_A[*], SDRAM_BA[*], SDRAM_DQ[*], SDRAM_DQML/H, SDRAM_nRAS/nCAS/nWE were ALL
# completely unconstrained even after switching SDRAM_CLK to a real PLL-derived,
# phase-shifted clock -- derive_pll_clocks only defines the CLOCK itself, not the
# I/O delay relationship to the external chip, so the fitter had zero timing-
# driven reason to route these signals well regardless of SDRAM_CLK's phase.
# This is almost certainly why two very different phase_shift values (180deg,
# 90deg) made no observed difference on real hardware.
#
# Numbers: tAC=5.4ns (max), tOH=3.0ns (min) are Micron's own MT48LC16M16A2
# datasheet values (matches jtcores_ref's official Micron behavioral model,
# jtcores_ref/modules/jtframe/hdl/ver/mt48lc16m16a2.v). tIS=1.5ns / tIH=0.8ns
# are the chip's standard datasheet input setup/hold for this speed grade.
# Board trace delay is not measured for this specific board -- using a
# conservative 1.5ns one-way estimate (SDRAM sits close to the FPGA on
# MiSTer's main board). These are reasoned engineering estimates grounded in
# real datasheet numbers, not exact measured values -- but far better than
# the confirmed current state of zero I/O timing constraint at all.
# Both output AND input delay must reference clk_sys (general[0], UNshifted) --
# that's the ACTUAL clock every launching/capturing register in sdram.sv uses
# (`always @(posedge clk) ...`), including SDRAM_A/BA/DQM/nRAS/nCAS/nWE and
# SDRAM_DQ-as-write. sdram_clk (general[1]) is only the external chip's own
# clock pin -- correct as the *physical* timing reference for the chip's real
# datasheet requirement, but WRONG as the SDC -clock argument, since SDC's
# -clock names the clock that actually launches/captures the FPGA-side
# register, not the external device's clock. Using sdram_clk there produced a
# large, systematic-looking violation (~-7.4ns on ~30 endpoints, -256ns TNS)
# that didn't move at all when only the input side was fixed -- confirming the
# output side had the identical mistake. Values below are adjusted by the
# 5.208ns phase offset (general[1] is 90deg/5.208ns AFTER general[0]) to
# express the same real-world timing relative to the correct reference edge:
# output launches 5.208ns before the chip's own sampling edge (extra margin,
# so the values go more negative), input's known-valid window is 5.208ns
# later than a general[0]-relative CAS-latency calculation would suggest (so
# those values go more positive) -- see git history for the intermediate,
# still-wrong attempt that referenced sdram_clk directly for either side.
set clk_sys_name {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

# THE MISSING PIECE (2026-08-11): the header comment above already correctly
# diagnosed that SDRAM_CLK itself was unconstrained, but the fix below it only
# ever added set_output_delay/set_input_delay for the OTHER SDRAM pins --
# SDRAM_CLK was never actually given a constraint, and Template.sta.rpt's
# "Unconstrained Output Ports" report confirms it's STILL listed there ("No
# output delay, min/max delays, false-path exceptions, or max skew
# assignments found") even now. derive_pll_clocks only names the PLL's
# INTERNAL clock nodes (confirmed via the .sta.rpt: the internal
# general[1]...divclk node -- 48MHz, 90deg phase-shifted, sourced from
# general[0]'s vcoph[0] -- already shows as "Generated ; Constrained"); it does
# NOT know that this internal clock is then forwarded, through sdram.sv's
# `assign SDRAM_CLK = sdram_clk_in;`, out to the actual SDRAM_CLK output PIN.
# Without telling TimeQuest that pin carries a real clock, the fitter has zero
# timing-driven reason to preserve SDRAM_CLK's phase relationship to the other
# SDRAM_* signals during placement/routing -- exactly the kind of gap that
# passes clean in (delay-free) RTL simulation, can vary compile-to-compile,
# and would explain real hardware failing under access patterns simulation
# never exercises. Fixes it by declaring the pin as a generated clock sourced
# from that same internal PLL node.
set sdram_clk_src {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
create_generated_clock -source $sdram_clk_src -name SDRAM_CLK [get_ports {SDRAM_CLK}]

# REVISED METHODOLOGY (2026-08-11): now that SDRAM_CLK is a properly declared
# generated clock (immediately above) with a known phase relationship to
# clk_sys via their shared PLL, the fragile manual "-clock clk_sys, offset by
# +/-5.208ns by hand" approach used previously is no longer necessary --
# and was risky, since every future phase_shift change would require
# correctly re-deriving that offset by hand or silently going stale.
# Reference SDRAM_CLK directly instead, which is also the textbook-correct
# way to constrain a forwarded-clock interface:
#  - OUTPUT constraints (FPGA -> SDRAM address/control/write-data): the
#    external chip samples these relative to ITS OWN clock pin, i.e.
#    SDRAM_CLK, not clk_sys -- so SDRAM_CLK is the physically correct -clock
#    reference. TimeQuest resolves the real clk_sys-launch-to-SDRAM_CLK-
#    capture relationship automatically via the PLL's derived phase.
#  - INPUT constraints (SDRAM_DQ, SDRAM -> FPGA reads): the chip drives DQ
#    referenced to the SAME SDRAM_CLK edge it received, so SDRAM_CLK is again
#    the correct launch-clock reference; TimeQuest finds the actual capturing
#    register's clock (clk_sys) from the port's fanout automatically.
# Referencing the forwarded clock also lets most of the (unmeasured) board
# trace delay cancel out algebraically, since SDRAM_CLK and the other SDRAM_*
# signals travel the same physical distance on the same board -- what's left
# is just the chip's own datasheet numbers plus a modest allowance for
# clock-to-data trace-length MISMATCH (not the full one-way board delay).
# TRIED widening to 2.0ns (2026-08-11): produced a confirmed real violation
# (SDRAM_CLK setup slack -0.398ns, TNS -5.102ns) -- not deployed. Confirms
# the real available budget at 90deg phase is tight, somewhere between 1.0ns
# and 2.0ns of margin; not much room to push further in this direction.
# Reverted to the last known-passing value (+0.603ns margin at 90deg).
set sdram_skew_margin 1.0
set sdram_tIS 1.5
set sdram_tIH 0.8
set sdram_tAC 5.4
set sdram_tOH 3.0

set_output_delay -clock [get_clocks {SDRAM_CLK}] -max [expr {$sdram_tIS + $sdram_skew_margin}]  [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_DQ[*]}]
set_output_delay -clock [get_clocks {SDRAM_CLK}] -min [expr {-($sdram_tIH + $sdram_skew_margin)}] [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_DQ[*]}]

set_input_delay -clock [get_clocks {SDRAM_CLK}] -max [expr {$sdram_tAC + $sdram_skew_margin}] [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock [get_clocks {SDRAM_CLK}] -min [expr {$sdram_tOH - $sdram_skew_margin}] [get_ports {SDRAM_DQ[*]}]
