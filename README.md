# Battlantis - MiSTer FPGA Core

This project was made with the assitance of Gemini and Claude.  This core is meant to be free and no one shall charge for thie core.  

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

This folder is a clean snapshot of the working tree as of **2026-08-08**,
containing only the files actually compiled into the core (audited against
`Template.qsf` / `files.qip` and every module instantiation, not just copied
wholesale). It follows on from the last prior commit,
[`9f09c8b`](../Template_MiSTer%20-%20Copy) (2026-07-16); everything since
the sprite BRAM+SDRAM hybrid engine, scroll prefetch rework, tile ROM
byte-swap fix, and roughly 118 documented debug iterations existed only in
an uncommitted working tree full of debug media and MAME reference dumps
until now.  

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
| MC6809 main CPU | Working - boots, runs game logic, RAM test passes |
| K007342 tilemap (backgrounds, text, scroll) | Working - title screen scrolling and tile ROM addressing fixed |
| K007420 sprites | Working for the large majority of sprites/sizes; see known issues |
| Palette RAM | Working - sprite palette bank bug fixed and confirmed on hardware |
| Screen rotation / OSD | Working - Orientation, Flip Monitor, and aspect ratio confirmed correct on hardware (MisterCade-style cabinet) |
| DIP switches | Wired up (Coinage, Lives, Difficulty, Bonus Life, Demo Sounds, Cabinet, Flip Screen, Upright Controls, Mode, Continues) per the owner's manual and MAME source; not yet verified against a physical PCB |
| Sound (Z80 + dual YM3812) | Wired into `Battlantis.sv`; not yet verified on real hardware |

## Known issues

- **Upper-address sprites**: sprites served from the upper SDRAM-backed ROM
  range (Gargoyle, Grimlock, Ogre wall-climb, Carriage, Red Dragon, stage
  bosses) intermittently render as missing or as corrupted lines/streaks
  instead of clean sprite art. Top priority open issue.
- **Ogre 16×16 wall-climb static**: the Ogre's 8×8 wall-running form renders
  correctly, but its 16×16 wall-climb form progressively degrades into static
  as it climbs. Leading theory is SDRAM Port 3 bandwidth contention (16×16
  needs ~4x the byte-fetches of 8×8 per instance), unconfirmed. Likely related
  to the upper-address sprite issue above.
- **Sprite halo/outline artifact**: an unresolved visual artifact on some
  sprites. An earlier attempt to explain this by borrowing a "shadow pixel"
  convention from Jotego's unrelated Twin-16 (`007779/007781/007783`) colmix
  core was wrong. Battlantis's actual K007420 has no shadow feature
  (`k007420.cpp` only ever uses plain `transpen`/`zoom_transpen`) — and was
  reverted. Needs fresh diagnosis grounded in K007420's real behavior.
- **Sound** is wired in but not yet verified against real hardware.
- **DIP switches** are fully wired to the OSD but have not been verified
  against physical PCB behavior.

## Third-party cores

- `rtl/mc6809/mc6809i.v` - Greg Miller's cycle-accurate MC6809 core. License:
  see `rtl/mc6809/documentation/LICENSE.md`.
- `rtl/t80/*.vhd` - the open-source T80 Z80-compatible core (used via the
  `T80s` wrapper, instantiated from `rtl/cpu_z80.v`).
- `rtl/jtopl/hdl/*.v` - Jose Tejada's (Jotego) `jtopl` YM3812/OPL2 core.
  License: GPLv3, see `rtl/jtopl/LICENSE`.

## Notes on this file set

This snapshot deliberately excludes two things that were found to be dead
code during the audit for this commit, even though they were listed in the
original `files.qip`/`Template.qsf`:

- `rtl/jtkcpu/*` (Jotego's HD6309 core) and `rtl/mc6809/mc6809.v` (a wrapper
  module, `mc6809is`, adapting `jtkcpu` to the MC6809 interface) — neither is
  ever instantiated by `Battlantis.sv`, which uses `mc6809i` (Greg Miller's
  core) directly.
- `rtl/t80/T80pa.vhd` - an alternate T80 top-level wrapper not used; the
  design instantiates `T80s` only.

SignalTap debug probes (`debug.stp`) were also stripped from `Template.qsf`
for this clean build.
