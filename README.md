![Battlantis](docs/readme/banner.jpg)

# Battlantis for MiSTer

**Version 2.0.2** (release `releases/Battlantis_20261018b.rbf`).

Konami's 1987 arcade shooter **Battlantis** (GX777 board), rebuilt from scratch for the MiSTer FPGA. Three versions in one core, scores that save, a sharp picture on a CRT, and an OSD you can understand at a glance.


![Battlantis: title screen, stage 1, a power box, the snow stage, the dragon and the final stage](docs/readme/gallery.png)

## At a glance

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/logo.png" width="96"> | **Game** | Clear every enemy off the screen to move on. 16 stages, and the Emperor Asmodeus waits at the end |
| <img src="docs/readme/icons/ver.png" width="48"> | **Versions** | World (G), version F and Japan (E), picked in the OSD |
| <img src="docs/readme/icons/pads2.png" width="48"> | **Players** | 1 or 2, Can share a controller or each with their own controller |
| <img src="docs/readme/icons/trophy.png" width="48"> | **High scores** | Load by themselves, save with one button, can be reset to the original table |
| <img src="docs/readme/icons/crt.png" width="48"> | **Picture** | HDMI (rotated for a normal TV) and analog CRT (rotated, sized and smoothed from the OSD) |
| <img src="docs/readme/icons/cocktail.png" width="48"> | **Cocktail table** | Real cocktail cabinet support: the picture flips for player 2 on the analog output |
| <img src="docs/readme/icons/speaker.png" width="48"> | **Sound** | Two YM3812 FM chips, mono or split stereo, a Treble option, volume per chip |

## How to play

![Instruction card, English translation, both halves](docs/readme/instruction_card.jpg)

*The arcade game's instruction card, translated into English by the author. Battlantis and the original card artwork are Konami's.*

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/joy.png" width="48"> | **Move and shoot** | Move left, right, up and down, and shoot with one button |
| <img src="docs/readme/icons/enemies.png" width="48"> | **Clear the screen** | Clear every enemy off the screen to finish the stage. If the enemies take over your castle wall, it is over |
| <img src="docs/readme/icons/pbox.png" width="48"> | **Destroy the P-Box** | Shooting the P-Box gives you a power up. The Power-up Crests can be seen below. |
| <img src="docs/readme/icons/lives.png" width="48"> | **Lives** | Choose 2, 3, 5 or 7 lives with the Lives DIP switch (OSD, DIP Switches page). The factory setting is 3 lives |
| <img src="docs/readme/icons/coin.png" width="48"> | **Continue** | You can continue after losing all lives. The Continues DIP switch sets how many times you can: 5 (the factory setting) or 3 |

**Power items**

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/invisibility.png" height="72"> | **Invisibility** | The player becomes invisible |
| <img src="docs/readme/icons/bowgun.png" height="72"> | **Bow-gun** | Destroys all enemies struck (the shot passes through) |
| <img src="docs/readme/icons/nitro.png" height="72"> | **Nitro grenade** | A big explosion clears a wide area |
| <img src="docs/readme/icons/stopclock.png" height="72"> | **Stop clock** | Enemies freeze for several seconds |
| <img src="docs/readme/icons/rapidfire.png" height="72"> | **Rapid fire** | Fire 4 shots instead of 2 |
| <img src="docs/readme/icons/speedup.png" height="72"> | **Speed-up** | The player's speed increases |

## Install

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/chip.png" width="48"> | **You need** | The MiSTer **SDRAM module** and your own legally obtained ROM set |
| <img src="docs/readme/icons/folder.png" width="48"> | **1. Core file** | Copy the core file (`Battlantis_20261018b.rbf`) to `/media/fat/_Arcade/cores/` |
| <img src="docs/readme/icons/doc.png" width="48"> | **2. MRA file** | Copy `Battlantis.mra` to `/media/fat/_Arcade/` |
| <img src="docs/readme/icons/zip.png" width="48"> | **3. ROM set** | Put `battlnts.zip` in `/media/fat/games/mame/`. It must also contain the files of the other two versions (folders `battlntsa` and `battlntsj`), as in the full MAME set |
| <img src="docs/readme/icons/play.png" width="48"> | **4. Play** | Start **Battlantis** from the Arcade menu |

No ROM data is included in this repository.

## Controls

![Controls](docs/readme/controls.png)

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/pad.png" width="48"> | **Single controls (the default)** | One set of controls. One pad plays everything: with two players the game takes turns and you pass the pad. **Start 2** begins a two player game. The game only reads the first pad, so a second pad does nothing in this mode |
| <img src="docs/readme/icons/pads2.png" width="48"> | **Dual controls** | Each player has their own controller: player 1 uses the first pad, player 2 the second. The game takes turns, so each pad is live on its player's turn. Use it for a cabinet with two sides, a cocktail table, or two pads on a couch |
| <img src="docs/readme/icons/gear.png" width="48"> | **How to switch** | **OSD > DIP Switches > Upright Controls**, Single or Dual. The game reads that switch only at start up, as the real board does, so the core restarts the game by itself when you change it. You do not need to reset anything. **Cocktail** cabinet always counts as Dual, so Upright Controls is greyed out while it is selected |
| <img src="docs/readme/icons/joy.png" width="48"> | **Which pad is which** | The first pad you press a button on becomes player 1 and the next one player 2 (the MiSTer decides that). The controls work out of the box with each pad's default layout. To change it, use **Define joystick buttons** (OSD, press Right for the System menu) and press the buttons it asks for on that pad. Each controller **model** keeps its own map (a PS4 and a PS5 pad are two models), and two pads of the same model share one. The **Controller Setup** page in the OSD lists these steps and follows the Single or Dual setting |

## The OSD at a glance

![OSD map](docs/readme/osd_map.png)

Open the OSD with the button on your controller or **F12** on a keyboard. The first choice of every option is the factory setting.

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/ver.png" width="48"> | **Game Version** | Restarts the game when you change it |
| <img src="docs/readme/icons/tv.png" width="48"> | **Video** | Separate options for HDMI and for the analog CRT output. The CRT options do nothing on HDMI and the other way round |
| <img src="docs/readme/icons/size.png" width="48"> | **CRT Size and Smoothing** | 182x208 is the default and the sharpest: every tile of the picture lands on a whole number of pixels. CRT Smoothing keeps the scaled picture even; turn it Off for plain pixels |
| <img src="docs/readme/icons/tv.png" width="48"> | **VGA Scaler** | Off by default. When On, the analog port carries the HDMI picture (the rotated, sized and smoothed one) instead of the raw 15 kHz raster, so a VGA or other 31 kHz monitor works. Leave it Off for a 15 kHz CRT. It is the same switch as `vga_scaler=1` in `MiSTer.ini` |
| <img src="docs/readme/icons/speaker.png" width="48"> | **Treble** | Under Sound Settings. Softens the FM chips for listeners who find them harsh. Original is the unfiltered sound |
| <img src="docs/readme/icons/gear.png" width="48"> | **Service Mode** | Restarts the game when toggled, because the game only reads that switch at start up. Leave it Off for normal play |
| <img src="docs/readme/icons/cocktail.png" width="48"> | **Cocktail Cabinet and Upright Cabinet Controls** | Both restart the game when you change them, for the same reason. **Cocktail** always counts as Dual controls, so Upright Controls is greyed out while Cocktail is selected |
| <img src="docs/readme/icons/pads2.png" width="48"> | **Controller Setup** | A page that tells you the steps to set up your pad (or two pads), and follows the Single or Dual setting |

## High scores

![High score flow](docs/readme/high_scores.png)

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/restore.png" width="48"> | **Restored for you** | Saved scores are put back a few seconds after the core loads, and again after an OSD **Reset** |
| <img src="docs/readme/icons/sd.png" width="48"> | **Save High Scores** | Writes the current top 10 to `/media/fat/config/nvram/Battlantis.nvm`. Nothing saves on its own, so you decide which scores are worth keeping |
| <img src="docs/readme/icons/trash.png" width="48"> | **Clear High Scores** | Asks "Are you sure you want to clear your hi scores? They will be lost forever." **Yes** puts the original top 10 back (and saves it). Either answer returns you to the main menu |
| <img src="docs/readme/icons/trophy.png" width="48"> | **A real score** | The saved table is the game's own top 10, earned by playing it. There are no cheats in this build |

## Cabinet setups

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/cabinet.png" width="48"> | **A normal upright setup** | Cabinet **Upright**, Upright Controls **Single**. One set of controls, as on the factory default |
| <img src="docs/readme/icons/pads2.png" width="48"> | **Two controllers, side by side** | Upright Controls **Dual** (the game restarts by itself). Each player uses their own controller on their own turn |
| <img src="docs/readme/icons/cocktail.png" width="48"> | **A cocktail table** | Cabinet **Cocktail**, nothing else to set: Dual controls come with it. The game restarts by itself. On the analog output the picture flips for player 2, as the board does. HDMI is never flipped by it |

Konami's board has cocktail table support built into the game, so this is the real behaviour of the hardware, not an add-on.

## Picture on HDMI and on a CRT

![The core with the full bezel art](docs/readme/bezel_preview.jpg)

| | | HDMI | Analog CRT |
|:-:|---|---|---|
| <img src="docs/readme/icons/rot.png" width="48"> | **Orientation** | HDMI Orientation | CRT Orientation (Vertical raw, or Horizontal rotated) |
| <img src="docs/readme/icons/flip.png" width="48"> | **Flip** | Flip Monitor | CRT Flip |
| <img src="docs/readme/icons/aspect.png" width="48"> | **Size and shape** | Aspect ratio | CRT Size and CRT Aspect |
| <img src="docs/readme/icons/smooth.png" width="48"> | **Smoothing** | The MiSTer scaler | CRT Smoothing |
| <img src="docs/readme/icons/pos.png" width="48"> | **Position** | Not needed | CRT V Position and CRT H Position |

![Battlantis](docs/readme/background_strip.jpg)

## Credits

| | | |
|:-:|---|---|
| <img src="docs/readme/icons/person.png" width="48"> | **Roger Taylor** | [Nitrobotics/hd6309](https://github.com/Nitrobotics/hd6309), the Hitachi HD6309 native mode CPU core the main program needs |
| <img src="docs/readme/icons/speaker.png" width="48"> | **Jose Tejada (jotego)** | The `jtopl` (YM3812 / OPL2) core from the [JTCORES](https://github.com/jotego/jtcores) project, GPL 3, used for both FM chips. His other cores and documentation were also a constant reference |
| <img src="docs/readme/icons/chip.png" width="48"> | **Daniel Wallner and the T80 contributors** | The T80 Z80 core used for the sound CPU |
| <img src="docs/readme/icons/gear.png" width="48"> | **Sorgelig and the MiSTer FPGA project** | The platform framework (`sys/`, `hps_io`, `arcade_video`) and the SDRAM controller this core's `sdram.sv` is built on |
| <img src="docs/readme/icons/doc.png" width="48"> | **The MAME project** | `battlnts.cpp`, `k007342.cpp`, `k007420.cpp` and `konamipt.h` (mamedev.org) were the authoritative reference for the ROM layout, the chip behaviour and the draw order |
| <img src="docs/readme/icons/konami.png" width="64"> | **Konami** | The original 1987 arcade hardware and games. All game assets and ROM content remain Konami's property |

This core was developed with substantial assistance from **Claude** (Anthropic's AI assistant) and, earlier in the project, Google's **Gemini**, for RTL implementation, cross checking against the MAME driver and the schematics of related Konami boards, simulation and debugging. The direction, the testing on a real MiSTer, every decision about what was acceptable and the final judgement of what works were the author's.

The code is released under the GNU General Public License (see `LICENSE` and the header of each file; the `jt*` cores are GPL 3).
