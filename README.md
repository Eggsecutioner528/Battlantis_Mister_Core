# Battlantis - MiSTer FPGA Core

**Status: Beta.** Fully playable on real hardware: video, sound, and
input are all confirmed working. See the Status table below for the
full subsystem breakdown and the **2026-08-27 sync** note for what
changed to reach this point.

Author/creator: **Eggsecutioner**. This project was made with the assistance of
Gemini and Claude. This core is meant to be free and no one shall charge for
this core.

This is a from-scratch Verilog/SystemVerilog reimplementation of the 1987 Konami arcade
game **Battlantis** (Twin-16 hardware family: MC6809 main CPU, Z80 + dual
YM3812 sound, K007342 tilemap generator, K007420 sprite generator) for the
[MiSTer FPGA](https://github.com/MiSTer-devel) platform.

This is not based on Jotego's JT-series cores. It was built by cross-referencing
MAME's driver source (`battlnts.cpp`, `k007342.cpp`, `k007420.cpp`) for
ground-truth bit-level timing and addressing, verified against real Battlantis
arcade hardware.  However this work would not have been possible without Jotego's work
mainly thanks to his work on other cores and documentation.  I am deeply greatful
for this information.

This folder is a clean snapshot of the working tree, most recently re-synced
**2026-08-16** (containing only the files actually compiled into the core,
audited against `Template.qsf` / `files.qip` and every module instantiation,
not just copied wholesale). The active working tree runs far ahead of this
snapshot at any given time -- it accumulates diagnostic instrumentation and
in-progress experiments (SignalTap-style overlays, shadow-verification state
machines, isolation tests) needed to actually find and confirm bugs, none of
which belongs in a public release build. This snapshot is re-synced
periodically by hand-porting only the specific, proven fixes out of that
working tree, with all diagnostic scaffolding stripped back out.

**2026-08-27 sync, Beta.** The core is now fully playable end-to-end on
real hardware. Highlights since the last sync:
- **Sound fully fixed** (Task #8, closed): a one-cycle-early timing bug in
  the third-party `jtopl` OPL2 core's envelope-generator persistent-storage
  delay lines, plus an earlier T80 core accumulator register-grouping bug
  that had been silently blocking the sound CPU from booting at all.
  Confirmed by direct listening test on real hardware.
- **Stage 1 speed fixed** (Task #15, closed): the game played roughly
  36-38% too slow compared to real PCB reference footage. Root cause: the
  6809's `LEAX -1,X`-style instructions leave `$FFFF` on the address bus
  during their internal-arithmetic cycle (real, documented 6809 behavior),
  which this core's IRQ-acknowledge logic was mistaking for a genuine
  interrupt-vector fetch and silently acking real vblank interrupts before
  the CPU could service them. Fixed by wiring the CPU's real `BS`/`BA`
  (Bus Status/Bus Available) signals and using the genuine hardware
  acknowledge condition instead. Confirmed on real hardware, the residual
  timing gap versus reference footage is now within ~0.06%.
- **DIP switches verified against the real owner's manual** (Task #9):
  found and fixed a real discrepancy in one DIP's fresh-boot default value
  that had been wrong on 4 of 5 fields.
- A tile-cache aliasing bug (Task #25) and a K007342 "32 columns" scroll
  mode register (Task #18) were also found and fixed.
- OSD menu reordered for a more logical layout; the non-functional "Flip
  Screen" option (confirmed on hardware to do nothing) was removed.
- Two additional real ROM revisions added: World version F and Japan
  version E, alongside the existing World version G. See "Installing
  ROMs" below.
- A significant dead-code cleanup pass removed ~75 leftover diagnostic
  signals plus 101 files/~20,800 lines of unreferenced third-party
  scaffolding that never compiled into the core in the first place.

**2026-08-16 sync -- major milestone**: with a boot-time hang found and fixed
(a video timing change had an unresolved side effect; reverted to the prior,
confirmed-working value pending further investigation), the core could
finally be played through for the first time in a while, surfacing and
confirming two significant fixes: (1) a K007342 sprite Y-wrap register
(0x02 bit 7) was completely unimplemented, causing a full-screen-height
duplicate "shadow" on some sprites -- implemented and confirmed fixed on
hardware. (2) A one-cycle-early BRAM read in the sprite fetch pipeline was
producing shear/ghosting specifically during sprite zoom transitions,
including visible seams between the separate pieces that make up composite
multi-sprite bosses (e.g. the Red Dragon) -- fixed by correcting the tile
boundary math to match MAME's real per-tile rounding exactly (see
`rtl/tile_bound1-4.hex`, replacing the previous single flat reciprocal
table). Both fixes are confirmed on real hardware; the previously-listed
"sprite halo/outline artifact" and "Red Dragon" known issues below are
resolved as of this sync. **Sound was also directly tested for the first
time this sync and is confirmed NOT working** -- see Known Issues.

**2026-08-15 sync**: a full architecture change from the previous snapshot --
both the background tilemap (`k007342.v`) and sprite engine (`k007420.v`)
changed how they store ROM data. Sprites now hold their entire 256KB ROM
statically in BRAM (previously a 64KB cache plus six hand-patched slots for
specific problem addresses, falling back to SDRAM for everything else), which
eliminated sprite SDRAM traffic entirely. That freed enough BRAM for
backgrounds to move the other way: instead of a full 256KB local ROM copy, a
64KB direct-mapped cache now serves tiles from BRAM and fills itself from
SDRAM on a miss. This also fixed the actual root cause of the black-background
bug from the previous snapshot: the SDRAM arbiter's reset was tied to a signal
the MiSTer framework holds asserted for the entire ROM download (not just
initial core bring-up, as commonly assumed), freezing the arbiter and
silently blocking every SDRAM write during download -- backgrounds render
correctly now that the arbiter's reset excludes the download window.

## Installing ROMs

This repo ships the compiled core (`output_files/Battlantis.rbf`) and the
`.mra` files, but **not the arcade ROM dump itself**. Battlantis is
Konami's copyrighted game data, and redistributing it isn't something
this project does, in line with every other MiSTer core. You'll need to
legally obtain your own dump and package it yourself:

1. Get a `battlnts.zip` (MAME romset name) containing (at minimum) the
   World version G set: `777_g02.7e`, `777_g03.8e`, `777_c01.10a`,
   `777c04.13a`, `777c05.13e`.
2. For the World version F or Japan version E variants (optional,
   `Battlantis (version F).mra` / `Battlantis (Japan).mra`), add
   `battlntsa/777_f02.7e` + `battlntsa/777_f03.8e`, or
   `battlntsj/777_e02.7e` + `battlntsj/777_e03.8e`, into the same zip
   under those subfolder names (standard MAME clone-set layout, since
   the sound/tile/sprite ROMs are byte-identical across all three
   revisions and only need to exist once at the zip's top level).
3. Copy `battlnts.zip` to your MiSTer's ROM search path for this core
   (typically `games/Battlantis/`; MiSTer resolves this from more than
   one folder depending on your setup, so check where your other arcade
   ROMs already live if this path doesn't work).
4. Copy `Battlantis.rbf` to `/media/fat/_Arcade/cores/` and the `.mra`
   file(s) you want to `/media/fat/_Arcade/` on the MiSTer's SD card.

## Building

Requires Quartus Prime 17.0.x (Lite is fine) targeting Cyclone V
(`5CGXFC7C7F23C8`, the MiSTer main board).

```
quartus_sh --flow compile Template
```

`build_and_deploy.bat` wraps this and also deploys the resulting `.rbf` +
`Battlantis.mra` to a MiSTer over SCP (edit `MISTER_IP` for your setup;
default MiSTer credentials are `root` / `1`). If you wish for `build_and_deploy.bat` to actually deploy you will have to change the IP address to what is listed on your mister.  Looks for 10.0.0. and you will find the IP address that needs to be changed.  It should be near the top.  If deploy fails, the comile will still be successful and can still be manualy deployed.

## Status

| Subsystem | Status |
|---|---|
| MC6809 main CPU | Working: boots, runs game logic, real BS/BA-based interrupt handling (Task #15) |
| K007342 tilemap (backgrounds, text, scroll) | Working: 256KB tile ROM served via a 64KB SDRAM-backed cache; a tile-cache aliasing bug (Task #25) and the "32 columns" scroll mode register (Task #18) have both been found and fixed |
| K007420 sprites | Working: entire 256KB sprite ROM held statically in BRAM, no SDRAM sprite traffic |
| Palette RAM | Working |
| Screen rotation / OSD | Working: Orientation, Flip Monitor, and Aspect Ratio confirmed correct on hardware (MiSTerCade-style rotated cabinet monitor). Direct Video (CRT via the Analog IO board) is Portrait-only by design; see the project's task history for why a non-rotated-CRT Landscape mode isn't feasible on this FPGA's available on-chip RAM. |
| DIP switches | Verified against the real Konami owner's manual (Task #9), which found and fixed a real default-value bug affecting 4 of 5 fields on one DIP |
| Sound (Z80 + dual YM3812) | **Working, confirmed by listening test on real hardware (Task #8).** Root cause of the earlier silence was a T80 core accumulator register-grouping bug plus a one-cycle envelope-timing bug in the third-party `jtopl` OPL2 core |
| Regional ROM revisions | World version G (default), World version F, and Japan version E all supported. See "Installing ROMs" |

## Known issues

- **Stage 1 timing residual gap**: after the Task #15 interrupt-ack fix,
  the core's steady-state vblank-service rate is 99.94% (vs. real
  hardware's effective ~100%). Close enough that the user could not
  perceive any difference from real PCB reference footage in direct A/B
  testing, but not mathematically identical. Closing the remaining
  0.06% is left for community/further review.
- **Direct Video is Portrait-only**: the CRT connected via the Analog IO
  board (Direct Video mode) bypasses the DDR3 framebuffer/scaler
  entirely by design, so there's no framebuffer available to rotate for
  a Landscape/non-rotated-CRT setup. A dedicated on-chip frame buffer for
  this was scoped but found infeasible, since this FPGA's design already
  uses 100% of its on-chip RAM blocks. Landscape/non-rotated-CRT users
  should use the existing Orientation/Flip Monitor/Aspect Ratio OSD
  options via scaled VGA/HDMI output instead.
- **Palette RAM addressing question, not yet resolved**: the display
  read path only forms a 9-bit palette index into a 1024-entry palette
  RAM array that the CPU can write with a full 10-bit address, meaning
  entries 512-1023 are writable but never displayed. Flagged during a
  code-cleanup pass as a genuine open functional question (is this
  correct real-hardware behavior, or a bug?) rather than something
  patched blindly. Needs checking against real K007342 documentation
  or hardware before any change.

## Third-party cores

- `rtl/mc6809/mc6809i.v` - Greg Miller's cycle-accurate MC6809 core. License:
  see `rtl/mc6809/documentation/LICENSE.md`.
- `rtl/t80/*.vhd` - the open-source T80 Z80-compatible core (used via the
  `T80s` wrapper, instantiated from `rtl/cpu_z80.v`).
- `rtl/jtopl/hdl/*.v` - Jose Tejada's (Jotego) `jtopl` YM3812/OPL2 core.
  License: GPLv3, see `rtl/jtopl/LICENSE`.

## Notes on this file set

- `rtl/jtkcpu/*` (Jotego's HD6309 core) and `rtl/mc6809/mc6809.v` (a wrapper
  module, `mc6809is`, adapting `jtkcpu` to the MC6809 interface) - neither is
  ever instantiated by `Battlantis.sv`, which uses `mc6809i` (Greg Miller's
  core) directly.
- `rtl/t80/T80pa.vhd` - an alternate T80 top-level wrapper not used; the
  design instantiates `T80s` only.
