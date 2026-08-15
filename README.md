# Battlantis - MiSTer FPGA Core

**Status: Pre-Alpha.**

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
**2026-08-15** (containing only the files actually compiled into the core,
audited against `Template.qsf` / `files.qip` and every module instantiation,
not just copied wholesale). The active working tree runs far ahead of this
snapshot at any given time -- it accumulates diagnostic instrumentation and
in-progress experiments (SignalTap-style overlays, shadow-verification state
machines, isolation tests) needed to actually find and confirm bugs, none of
which belongs in a public release build. This snapshot is re-synced
periodically by hand-porting only the specific, proven fixes out of that
working tree, with all diagnostic scaffolding stripped back out.

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
| K007342 tilemap (backgrounds, text, scroll) | Working - full 256KB tile ROM served via a 64KB SDRAM-backed cache; backgrounds confirmed rendering correctly on real hardware 2026-08-15 (see the sync note above) |
| K007420 sprites | Working for the large majority of sprites/sizes -- entire 256KB sprite ROM now held statically in BRAM (2026-08-15), eliminating SDRAM sprite traffic entirely; see known issues for remaining per-sprite bugs |
| Palette RAM | Working - sprite palette bank bug fixed and confirmed on hardware |
| Screen rotation / OSD | Working - Orientation, Flip Monitor, and aspect ratio confirmed correct on hardware (MisterCade-style cabinet) |
| DIP switches | Wired up (Coinage, Lives, Difficulty, Bonus Life, Demo Sounds, Cabinet, Flip Screen, Upright Controls, Mode, Continues) per the owner's manual and MAME source; not yet verified against a physical PCB |
| Sound (Z80 + dual YM3812) | Wired into `Battlantis.sv`; not yet verified on real hardware |

## Known issues

- **SDRAM Port 3 reliability for isolated/random-jump sprite fetches**: this
  was the root architectural constraint behind most sprite issues in earlier
  snapshots -- extensive testing (ModelSim simulation with a real Micron
  SDRAM behavioral model, plus controlled hardware A/B tests) proved
  isolated, randomly-jumping single-byte SDRAM reads (exactly how sprite
  fetching worked, hopping between OAM slots and ROM addresses every frame)
  fail essentially 100% of the time on this hardware/timing configuration,
  while fully sequential access is 100% reliable. **Resolved architecturally
  as of 2026-08-15**, not patched: the sprite engine now holds its entire
  256KB ROM statically in BRAM (see the sync note above) and never touches
  SDRAM at all, so this class of failure no longer applies to sprites.
  Backgrounds now use SDRAM instead (a 64KB tile cache, filled on a miss),
  but that access pattern -- one requester, mostly-sequential fills -- is the
  reliable case this testing already confirmed, not the isolated-jump case
  that failed.
- **Sprite halo/outline artifact**: an unresolved visual artifact on some
  sprites. An earlier attempt to explain this by borrowing a "shadow pixel"
  convention from Jotego's unrelated Twin-16 (`007779/007781/007783`) colmix
  core was wrong. Battlantis's actual K007420 has no shadow feature
  (`k007420.cpp` only ever uses plain `transpen`/`zoom_transpen`) and was
  reverted. Needs fresh diagnosis grounded in K007420's real behavior.
- **Sound** is wired in but not yet verified against real hardware.
   
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

SignalTap debug probes (`debug.stp`) were also stripped from `Template.qsf`
for this clean build.
