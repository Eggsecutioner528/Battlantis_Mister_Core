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
    Date: 10-10-2021

    */

module jtopl2(
    input                  rst,        // rst should be at least 6 clk&cen cycles long
    input                  clk,        // CPU clock
    input                  cen,        // optional clock enable, it not needed leave as 1'b1
    input           [ 7:0] din,
    input                  addr,
    input                  cs_n,
    input                  wr_n,
    output          [ 7:0] dout,
    output                 irq_n,
    // combined output
    output  signed  [15:0] snd,
    output                 sample,

    // 2026-08-19, task #8 round 40: diagnostic-only pass-through -- see
    // jtopl.v's port declaration comment for the full reasoning.
    output          [ 9:0] dbg_eg_V,
    output                  dbg_ch0car_valid,
    output          [14:0] dbg_eg_cnt,
    output                  dbg_keyon_now_I,
    output                  dbg_ch0car_valid_I,
    output                  dbg_sum_up_II,
    output                  dbg_cenop,
    output      [9:0]       dbg_eg_in_I,
    output                  dbg_step_II,
    output      [2:0]       dbg_state_in_I,
    output                  dbg_attack_II,
    output                  dbg_joint_hit_II,
    output                  dbg_joint_hit_III,
    output      [3:0]       dbg_arate_I,
    output      [5:0]       dbg_rate_II,
    output                  dbg_ar_dr_applied_ch0car,
    output                  dbg_up_ar_dr_raw,
    output                  dbg_ar_dr_clobbered,
    output                  dbg_pending_was_ch0car,

    // 2026-08-22, task #8 round 115: diagnostic-only pass-through -- see
    // jtopl.v's port declaration comment for the full reasoning.
    output                  dbg_ch4car_valid_I,
    output      [3:0]       dbg_keycode_II,
    output                  dbg_ksr_II,

    // 2026-08-22, task #8 round 121: diagnostic-only pass-through -- see
    // jtopl.v's port declaration comment for the full reasoning.
    output                  dbg_car_ch_valid,
    output      [3:0]       dbg_car_ch_num,

    // 2026-08-24, task #8 round 144: diagnostic-only pass-through -- see
    // jtopl.v's port declaration comment for the full reasoning.
    output                  dbg_ch7car_valid_I,
    output                  dbg_ch8car_valid_I
);

    `define JTOPL2
    jtopl #(.OPL_TYPE(2)) u_base(
        .rst    ( rst       ),
        .clk    ( clk       ),
        .cen    ( cen       ),
        .din    ( din       ),
        .addr   ( addr      ),
        .cs_n   ( cs_n      ),
        .wr_n   ( wr_n      ),
        .dout   ( dout      ),
        .irq_n  ( irq_n     ),
        .snd    ( snd       ),
        .sample ( sample    ),
        .dbg_eg_V         ( dbg_eg_V         ),
        .dbg_ch0car_valid ( dbg_ch0car_valid ),
        .dbg_eg_cnt       ( dbg_eg_cnt       ),
        .dbg_keyon_now_I    ( dbg_keyon_now_I    ),
        .dbg_ch0car_valid_I ( dbg_ch0car_valid_I ),
        .dbg_sum_up_II ( dbg_sum_up_II ),
        .dbg_cenop     ( dbg_cenop     ),
        .dbg_eg_in_I   ( dbg_eg_in_I   ),
        .dbg_step_II   ( dbg_step_II   ),
        .dbg_state_in_I( dbg_state_in_I),
        .dbg_attack_II ( dbg_attack_II ),
        .dbg_joint_hit_II ( dbg_joint_hit_II ),
        .dbg_joint_hit_III ( dbg_joint_hit_III ),
        .dbg_arate_I ( dbg_arate_I ),
        .dbg_rate_II ( dbg_rate_II ),
        .dbg_ar_dr_applied_ch0car ( dbg_ar_dr_applied_ch0car ),
        .dbg_up_ar_dr_raw ( dbg_up_ar_dr_raw ),
        .dbg_ar_dr_clobbered ( dbg_ar_dr_clobbered ),
        .dbg_pending_was_ch0car ( dbg_pending_was_ch0car ),
        .dbg_ch4car_valid_I ( dbg_ch4car_valid_I ),
        .dbg_keycode_II ( dbg_keycode_II ),
        .dbg_ksr_II ( dbg_ksr_II ),
        .dbg_car_ch_valid ( dbg_car_ch_valid ),
        .dbg_car_ch_num   ( dbg_car_ch_num   ),
        .dbg_ch7car_valid_I ( dbg_ch7car_valid_I ),
        .dbg_ch8car_valid_I ( dbg_ch8car_valid_I )
    );

endmodule