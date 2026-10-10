# Battlantis (Konami GX777) MiSTer FPGA Core

A MiSTer FPGA port of Konami's 1987 arcade game **Battlantis**, written from scratch in Verilog and SystemVerilog around the real board's chips.

**Version 1.0** (release `releases/Battlantis_20261010.rbf`).

One core, one `.mra`: you choose the version in the OSD (**Game Version**):

- Battlantis (version G, World)
- Battlantis (version F)
- Battlantis (Japan version E)

This is the "Simple Arcade" build: the picture on the HDMI output can be rotated, flipped and shaped from the OSD, and the analog (CRT) output is left as the raw, unrotated raster the arcade board itself produces, with only picture position options.

The earlier beta releases (v0.1 to v0.3, with the on-chip CRT rotation buffer) are kept on the `crt-rotation` branch.

---

## About the Game

Battlantis is a fixed screen shooter: you destroy every enemy on the screen to move on to the next stage, up to the Emperor Asmodeus on stage 16. It runs on Konami's **GX777** board, the same chip family as Rack 'Em Up (GX765) and Blades of Steel (GX797): a K007342 tilemap chip, a K007420 sprite chip, an HD6309E main CPU, a Z80 sound CPU and two YM3812 FM chips. The game is a vertical monitor game.

---

## Installing

You need the MiSTer SDRAM module (the sprite ROM lives in SDRAM) and your own legally obtained ROM set in `/media/fat/games/mame/`:

- `battlnts.zip` (MAME name `battlnts`). It must also hold the files of the other two versions in the folders `battlntsa` (version F) and `battlntsj` (Japan version E), exactly as in the full MAME set.

1. Copy `Battlantis_20261010.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy `Battlantis.mra` to `/media/fat/_Arcade/`.
3. Put `battlnts.zip` in `/media/fat/games/mame/`.
4. Start **Battlantis** from the Arcade menu.

All three versions are loaded together. This repository contains no ROM data.

---

## OSD Options

The video options live in two sub menus, **HDMI Video** and **CRT Video** (press Back to return to the main menu).

**HDMI Video**

- **Orientation**: Horizontal (default) rotates the picture so the vertical monitor game stands upright on a normal landscape display, with black bars at the sides. Vertical sends the raw raster, for a display that is itself mounted vertically.
- **Flip Monitor**: turns the picture 180 degrees.
- **Aspect ratio**: Original (the arcade monitor's 4:3, shown as 3:4 once rotated), Pixel Perfect (square pixels), Full Screen.

**CRT Video** (analog output only, HDMI is not affected)

- **CRT V Position** and **CRT H Position** nudge the picture on the tube. The analog output is not rotated or reshaped: it carries the raw 15 kHz raster of the real board, so a vertical arcade monitor or a CRT turned on its side shows the game exactly as the original hardware would.

**Game settings** (the first entry of every option is the factory default, so a fresh install plays like the real board):

- **Game Version**: Battlantis (version G), Battlantis (version F), Battlantis (Japan version E). Changing it restarts the game.
- Lives: 3, 5, 7 or 2
- Bonus Life: 30k and every 70k, 40k and every 80k, 40k, 50k
- Difficulty: Normal, Easy, Difficult, Very Difficult
- Demo Sounds: On or Off
- Continues: 5 or 3 times
- Cabinet: Upright or Cocktail
- Upright Controls: Single or Dual
- Flip Screen: Off or On
- Service Mode: Off or On (toggling it restarts the game, because the game only reads the service switch at start up)
- Coin A and Coin B: 1 coin 1 credit by default, with the full 16 entry Konami coinage table and a Free Play or No Coin B entry

**Controls** are mirrored for the two players: the first controller is player 1 and the second controller is player 2, each with the same layout. The buttons are Fire, Coin and Start. Map each controller model once in MiSTer's own button mapping screen (Define joystick buttons); two identical pads share the mapping. On the keyboard, 5 and 6 are the coins, 1 and 2 are the starts, and player 2 plays on R F D G with A for the button.

---

## How This Core Came Together

1. The real board was studied from the schematics and the MAME driver (`battlnts.cpp`, which covers the whole GX765 and GX777 family).
2. The CPU, sound and chip cores were brought in from open projects (see the credits) and checked against MAME frame by frame, using a GPU accelerated pixel comparison of this core's picture against MAME's.
3. The black holes and lines that earlier builds showed in the background were a memory timing problem: the background graphics were read from SDRAM and sometimes did not reach the screen in time. In this version the whole background tile ROM lives in on chip memory, which always answers on time, and only the sprite ROM is read through an SDRAM cache. The holes are gone in all three versions, including the stage 16 boss, the Emperor Asmodeus.
4. All three versions are loaded into SDRAM at once; a small copy engine moves the chosen version's program and tile ROM into the on chip memory and restarts the game whenever Game Version changes.

---

## Known Open Issues

- The analog output is the raw raster and is not rotated: a vertical arcade monitor or a CRT turned on its side is needed to see the game upright on it. A rotated analog output is planned as a later update.
- Game speed and sound have not been measured side by side against a real board.

---

## A Note on Development Process

This core was developed with substantial assistance from **Claude** (Anthropic's AI assistant) and, earlier in the project, Google's **Gemini**, used for RTL implementation, cross checking against the MAME driver and the schematics, simulation and hardware debugging. It is disclosed here so nobody mistakes this for an entirely machine generated core: the direction, the testing on a real MiSTer, every decision about what was acceptable and the final judgement of what works were the author's.

---

## Bibliography and Credits

- **Roger Taylor**: [Nitrobotics/hd6309](https://github.com/Nitrobotics/hd6309), the Hitachi HD6309 native mode CPU core the main program needs.
- **Jose Tejada (jotego)**: the `jtopl` (YM3812 / OPL2) core from the [JTCORES](https://github.com/jotego/jtcores) project, GPL 3, used for both FM chips. His other cores and documentation were also a constant reference.
- **Daniel Wallner and the T80 contributors**: the T80 Z80 core used for the sound CPU.
- **Sorgelig and the MiSTer FPGA project**: the platform framework (`sys/`, `hps_io`, `arcade_video`, `screen_rotate`) and the SDRAM controller this core's `sdram.sv` is built on.
- **The MAME project** (mamedev.org): `battlnts.cpp`, `k007342.cpp`, `k007420.cpp` and `konamipt.h` were the authoritative reference for the ROM layout, the chip behaviour and the draw order.
- **Konami**: the original 1987 arcade hardware and games. All game assets and ROM content remain Konami's property.
- The Rack 'Em Up / The Hustler and Blades of Steel cores by the same author, whose chip implementations this core shares.

The code is released under the GNU General Public License (see `LICENSE` and the header of each file; the `jt*` cores are GPL 3).
