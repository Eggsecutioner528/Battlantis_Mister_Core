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
**2026-08-16** (containing only the files actually compiled into the core,
audited against `Template.qsf` / `files.qip` and every module instantiation,
not just copied wholesale). The active working tree runs far ahead of this
snapshot at any given time -- it accumulates diagnostic instrumentation and
in-progress experiments (SignalTap-style overlays, shadow-verification state
machines, isolation tests) needed to actually find and confirm bugs, none of
which belongs in a public release build. This snapshot is re-synced
periodically by hand-porting only the specific, proven fixes out of that
working tree, with all diagnostic scaffolding stripped back out.

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
| Sound (Z80 + dual YM3812) | **Confirmed NOT working on real hardware (2026-08-16): complete silence.** Diagnostic testing pinpointed the sound ROM's IOCTL download write strobe as never firing -- the Z80 sound CPU has no program to execute. Root cause not yet found (module wiring and address-range math both check out on inspection); a live diagnostic to trace the actual IOCTL address stream during download is the next step. See Known Issues. |

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
- **Ogre 16×16 wall-climb static, Gargoyle / tally-screen portraits**: were
  fixed in an earlier snapshot via hand-patched BRAM slots for their specific
  problem addresses; as of 2026-08-15 the entire sprite ROM is BRAM-resident
  unconditionally, so these should remain fixed, but haven't been
  individually re-confirmed since the architecture change (worth a targeted
  re-check rather than assuming carry-over).
- **Purple/magenta static on the Game Over / late-stage screen**: confirmed
  to be an intentional visual effect of the original arcade hardware, not a
  bug -- no fix needed.
- **Sprite halo/outline artifact -- RESOLVED 2026-08-16.** Two real, separate
  causes, both fixed and confirmed on hardware: a completely unimplemented
  K007342 sprite Y-wrap register (0x02 bit 7), and a one-cycle-early BRAM
  read in the sprite fetch pipeline causing shear/ghosting specifically
  during zoom transitions (which also produced visible seams in composite
  multi-piece bosses like the Red Dragon, separately confirmed fixed).
  Battlantis's actual K007420 still has no dedicated "shadow" hardware
  feature (`k007420.cpp` only ever uses plain `transpen`/`zoom_transpen`)
  -- an earlier theory borrowing that convention from Jotego's unrelated
  Twin-16 (`007779/007781/007783`) colmix core remains correctly reverted.
- **Spined Devil position**: reported incorrect on the green-void transition
  screen; not yet root-caused.
- **Sound: confirmed NOT working (2026-08-16), complete silence.** The
  clock-rate correctness of the Z80/YM3812 clocks was fixed first (and is
  believed correct), but that turned out not to be the actual problem --
  live diagnostic testing during real gameplay showed the sound ROM's
  IOCTL download write strobe never fires at all, meaning the Z80 sound
  CPU never receives a real program. The module wiring in
  `rtl/battlantis_sound.v` and the IOCTL address-range math in
  `Battlantis.sv` both look correct on static inspection; the actual
  IOCTL address stream during download needs to be traced live to find
  where the sound ROM's region is being missed. Not yet root-caused.
- **DIP switches** are wired to the OSD (including a 2026-08-14 fix for the
  physical Test/Service button, previously tied off and unable to exit
  service mode once entered) but have not been fully verified against
  physical PCB behavior.

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
  module, `mc6809is`, adapting `jtkcpu` to the MC6809 interface) - neither is
  ever instantiated by `Battlantis.sv`, which uses `mc6809i` (Greg Miller's
  core) directly.
- `rtl/t80/T80pa.vhd` - an alternate T80 top-level wrapper not used; the
  design instantiates `T80s` only.

SignalTap debug probes (`debug.stp`) were also stripped from `Template.qsf`
for this clean build.
