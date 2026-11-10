![World Rally banner](pocket/art/wrally-banner.png)

# World Rally for the Analogue Pocket

One of the great arcade racers of the 90s – World Rally is a top-down racing game with rally stages across Sanremo, Monte Carlo, the Acropolis and the 1000 Lakes. Developed by Zigurat and produced by Gaelco, the game was originally released in 1993.

## Supported ROMs

| ROM id | game | notes |
| --- | --- | --- |
| `wrally` | World Rally Championship (checksum DE0D, 8 Nov 1993) | The latest version, with the Toyota logo covered on the title screen |
| `wrallya` | World Rally Championship (checksum E586, 25 Jun 1993) | Marked "Japan" |
| `wrallyb` | World Rally Championship (checksum 8AA2) | Mask ROM board, with the latest title screen |
| `wrallyc` | World Rally Championship (checksum 3873, 6 Apr 1993) | An earlier version, with the Toyota logo still on the title screen |
| `wrallyd` | World Rally Championship (checksum 0E56, 6 Apr 1993) | As `wrallyc`, marked Spain |
| `wrallye` | World Rally Championship (checksum 3D84, 2 Apr 1993) | The oldest version |
| `wrallyac` | World Rally Championship (checksum C448) | Licensed to Automáticos Canarios |
| `wrallyat` | World Rally Championship (America, checksum 2CC1) | Licensed to Atari, mask ROM board |
| `wrallyata` | World Rally Championship (America, checksum 75A5, 16 Jun 1993) | Licensed to Atari, mask ROM board |

## Installation

No game data comes with this core – you will need to supply your own MAME ROM
sets (`wrally.zip`, plus `wrallyc.zip` etc. for the other versions if your
set is split).

### Make the game files

You can't just drag and drop your MAME files. The Analogue Pocket can't read
zips, and the core needs each game as one file with every chip in its correct
place. There's a script in the repository that puts this all together for you,
or you can use a tool like Pocket Updater.

1. Download this repository (**Code → Download ZIP**, then unzip it) or clone it. You'll need Python 3 to run the build script.
2. Put your MAME zips in a folder.
3. In a terminal, from the repository's folder, run the script with the ROM ids you want from the table above, separated by commas (or `all` for every one):
   
   ```sh
   python3 tools/pocket/build_rom.py wrally,wrallyc ~/path/to/roms build/pocket
   ```
   
   So this will write `build/pocket/wrally.rom` and `build/pocket/wrallyc.rom`. The script finds the right chips in whatever zips you have, merged or split, and checks them against MAME's checksums.

[`tools/pocket/README.md`](tools/pocket/README.md) includes more info on this.

### Copy to the Analogue Pocket

1. Copy the `Cores`, `Platforms` and `Assets` folders from a release onto your Pocket's SD card.
2. Copy your `.rom` files into `Assets/wrally/common/` – for example `Assets/wrally/common/wrally.rom`.
3. On the Pocket: openFPGA → Arcade → World Rally, and pick your rom.

## Controls

| Input | Action |
| --- | --- |
| D-pad | steer |
| A | accelerate |
| B | change gear (each press shifts between low and high) |
| Select | insert coin |
| Start | start |

A second controller can be used for two players with the Pocket docked.

The Pocket's own menu has the usual **Display Mode** and **Controls** entries,
and opening it pauses the game. Under **Core Settings** there are three
options:

- **Test Mode** – the arcade cabinet's operator menu
- **Reset Game**
- **Diagnostic overlay** – probably best to ignore this

## Technical details

- The core recreates Gaelco's World Rally board – the 68000, the DS5002FP security processor, the video and the OKI M6295 sound chip – in hardware logic, built on [jlrh's World Rally MiSTer core](https://github.com/jlrh/gaelco-fpga) with a Pocket shell.
- It's been checked against MAME in simulation: over 34 million moves of the game's main processor through a race, identical but for where five interrupts land; the picture pixel for pixel in 198 scenes from all four rallies, by day and by night; and the sound chip's voices value for value over the race and 24,000 frames of attract.
- To build it yourself: `tools/bootstrap.sh`, then `sh pocket/build.sh` (Quartus Prime Lite 21.1 in Docker, about ten minutes; Go is needed too, and the repository must sit under your home folder). The finished SD card layout can be found in `pocket/dist/`.

## Credits and licence

- **jlrh** – the World Rally MiSTer core this is built on.
- **Jorge Cwik (ijor)** – fx68k, the 68000 processor.
- **Jose Tejada (jotego)** – jt6295, the sound chip; jt8051, the DS5002FP; and JTFRAME's memory blocks.
- **alphanu1** – the SDRAM controller, from the Kaneko16 MiSTer core.
- **agg23** – the Pocket utilities used for loading and audio.
- **Analogue** – the openFPGA core framework.
- **The MAME team** – whose work on World Rally was referenced.
- **Gaelco** – for giving MAME the DS5002FP's code and the facts about the encryption.
- Pocket port by **Frazilpop**.

GPL-3.0-only. [`THIRD-PARTY.md`](THIRD-PARTY.md) lists every dependency and its
licence.

World Rally is © 1993 Gaelco, developed by Zigurat. This project contains no
game data.
