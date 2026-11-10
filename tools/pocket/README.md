# Pocket tools

These are the scripts that make the game files for the Analogue Pocket, and
the ones that check the core against MAME. The ROMs you supply are only
read; everything made from them is written into `build/`. Run anything that
opens the zips with `python3 -I` so Python can't pick up stray files from the
folder you're in.

## Making the `.rom` files

```sh
python3 -I tools/pocket/build_rom.py wrally ~/Downloads build/pocket     # one game
python3 -I tools/pocket/build_rom.py all    ~/Downloads build/pocket     # all games
python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads --romdir build/pocket   # verify against MAME
```

You can also give a list of ROM ids separated by commas, e.g. `wrally,wrallyc`.

The core supports the following ROM ids: `wrally`, `wrallya`, `wrallyb`,
`wrallyc`, `wrallyd`, `wrallye`, `wrallyac`, `wrallyat` and `wrallyata`.

Each image is exactly 0x500000 bytes (5 MB), laid out the way the core reads
it from SDRAM, with zeros in the gaps:

| part | at | size | what |
|---|---|---|---|
| maincpu | 0x000000 | 1 MB | the 68000 program, as MAME's region |
| ds5002 | 0x100000 | 32 KB | the DS5002FP's SRAM image, as MAME's `gaelco_ds5002fp:sram` |
| oki | 0x200000 | 1 MB | the M6295's samples, as MAME's region |
| gfx | 0x300000 | 2 MB | MAME's graphics region rewritten as 64-bit lines, one a 16-pixel tile row |

The graphics are rearranged so that one SDRAM read is a whole tile row, for
the tilemaps and the sprites alike; the top of `build_rom.py` gives the exact
layout. The mask ROM sets (`wrallyb`, `wrallyat`, `wrallyata`) load their
graphics and samples from other chips, but the bytes are the same, so every
set's gfx and oki parts are identical.

The script finds each chip by its CRC32 and size, and will look through every
zip in the folder (the game's own zip and its parent's first), so merged, split
and non-merged sets all work. A `<rom id>/` folder of loose files works too.
Each chip's SHA1 is checked against MAME's before anything is written.

`verify_rom.py` runs MAME with `tools/mame_wrally_regions.lua`, which saves
MAME's own copy of each region to `build/mame/regions/<rom id>/`, then compares
them with the image byte for byte (`--no-mame` reuses regions already saved).
The graphics are turned back from fetch lines into MAME's layout first, and
1,024 tiles are also decoded both ways and compared pixel for pixel.

For simulation, `--regions` writes one file per MAME region instead:

```sh
python3 -I tools/pocket/build_rom.py wrally ~/Downloads build/roms --regions
# build/roms/wrally_maincpu.bin, _ds5002.bin, _oki.bin, _gfx.bin
```

## On the Analogue Pocket

Copy the image onto the SD card as

```
Assets/wrally/common/<rom id>.rom        e.g. Assets/wrally/common/wrally.rom
```

Each game's instance JSON points at that file. The Pocket loads it at bridge
address 0, and byte *n* of the file ends up at SDRAM byte *n*.

`tools/pocket/deploy.sh` copies the core, its JSONs and every set's image
found in `build/pocket/` onto the card and checks each copy; `--status` says whether
the card has the current build.

## Checking against MAME

Everything from here on is for working on the core itself. It needs MAME
(0.289 was used), Verilator, Go (for jt8051's microcode,
`tools/gen_jt8051.sh`, which the builds run for you) and the dependencies
from `tools/bootstrap.sh`.

Run the Lua scripts through `mame_oracle.sh`. It gives each run a fresh,
empty nvram and cfg folder: MAME keeps the DS5002FP's 32 KB SRAM as NVRAM,
saving it when it quits and loading it in place of the ROM image when it
starts, so otherwise every run would start from wherever the last one left
off. It also adds the flags autoboot needs (`-skip_gameinfo -autoboot_delay
0`). `ROMS=` changes where it looks for ROMs (`~/Downloads` by default) and
`MAME=` changes which MAME it runs; anything after `--` goes to MAME.

### Inputs

Every script plays the same inputs, from `tools/mame_wrally_inputs.lua`, with
every DIP switch at MAME's default (the word the core holds too). `INPUTS=`
picks the schedule:

- `none` (the default) – nothing pressed: power-on, then the attract;
- `race` – a coin at frame 600, Start at 700, the rally picked with button 1,
  the accelerator held from 1400, steering left and right from 1600;
- `session` – the race to frame 5000, then the test menu.

`RALLY=` picks the race's rally: `sanremo` (the default), `montecarlo`,
`acropolis` or `lakes`. Frame *N* is MAME's *N*th frame notification from
power-on, so frame 1 is the first picture it draws.

`tools/wrally_inputs_plan.py` writes the same schedule as a plan file for the
simulation, so the two run the same drive:

```sh
mkdir -p build/sim
python3 -I tools/wrally_inputs_plan.py race 3000 lakes > build/sim/race.txt
```

### The simulation

```sh
sim/wrally/build.sh                    # build/obj_wrally/tb_wrally
build/obj_wrally/tb_wrally build/pocket/wrally.rom 3000 build/sim/race 600,1800 \
    --inputs build/sim/race.txt --trace build/sim/race/bus.txt --trace-count 1000000
```

`tb_wrally` runs the whole board – the 68000, the DS5002FP, the video and
the OKI – from a `.rom` image, for the given number of frames, and writes the
frames asked for as `frame_NNNNN.ppm` (368 × 232) and a line a frame to
`stats.csv`. By default the SDRAM answers at a fixed latency (`--rom-lat`);
built with `SDR=real` the Pocket's own SDRAM controller times it instead.
`PIX=jlrh` builds the Pocket's frame timing rather than MAME's 60 Hz. The
top of `sim/wrally/tb_wrally.cpp` lists every option: the bus trace, the
sound, a log of the 68000's video writes, memory dumps and scene mode
(below).

### Tracing the bus from power-on

```sh
mkdir -p build/mame/wav
tools/pocket/mame_oracle.sh tools/mame_wrally_bus_trace.lua wrally \
    BUS_TRACE_OUT=build/mame/wrally_bus.txt BUS_TRACE_COUNT=1000000 INPUTS=race
python3 -I tools/diff_bus_trace.py build/sim/race/bus.txt build/mame/wrally_bus.txt wrally
```

The trace is one line per 68000 access (`addr R|W data mask`, plus `# frame N`
lines at each vblank), with the DS5002FP's accesses to the shared RAM beside
it in a `.mcu` file. The simulation writes the same pair. `diff_bus_trace.py`
compares every access in order, then the writes and data reads alone, then
picks up again wherever the two CPUs took the same interrupt an instruction
apart (fx68k and MAME's 68000 sample it at slightly different points), and
checks the DS5002FP's accesses in order and value.
`BUS_TRACE_DATA_ONLY=1` leaves out the program's fetches.

### Frames

```sh
tools/pocket/mame_oracle.sh tools/mame_wrally_screens.lua wrally \
    SCREENS_DIR=build/mame/screens/wrally FROM=200 TO=700 STEP=1 INPUTS=race
python3 -I tools/pocket/match_frames.py build/sim/race build/mame/screens/wrally --same
```

`mame_wrally_screens.lua` saves MAME's picture for every frame in the range
as a PNG; `match_frames.py` finds the MAME frame each simulated one matches
best and counts the pixels that differ (`--same`: against MAME's frame of
the same number). A frame is exact when the count is 0.

### Scenes

```sh
tools/pocket/mame_oracle.sh tools/mame_wrally_dump.lua wrally \
    DUMP_DIR=build/mame/dump/wrally DUMP_FRAME=600,2400 INPUTS=race
tools/pocket/match_scenes.sh build/pocket/wrally.rom build/mame/dump/wrally/f*
python3 -I tools/pocket/render_dump.py build/mame/dump/wrally/f02400 build/pocket/wrally.rom out.ppm
```

`mame_wrally_dump.lua` saves the video memories, the shared RAM and the
DS5002FP's state at chosen frames, with MAME's own picture; the top of the
script lists every file. `match_scenes.sh` writes each dump into the
simulated board's video memories and draws it, so the renderer is checked on
any game state MAME reaches, whether or not the simulation's own run gets
there; it also prints the sprite engine's busiest line. `render_dump.py`
draws a dump the way MAME's renderer does, in Python, and `--pixel X,Y` lists
what is drawn at one pixel. MAME's sprite mixer stops a pixel short of the
right and bottom edges, so a sprite there is the board's alone: `--board`
draws what the board should.

`mame_wrally_wlog.lua` logs when in each frame the game writes the video
memories, and the simulation's `--wlog` the same; writes inside the picture
are seen by the board as it draws but never by MAME, which draws the whole
frame at once.

### Sound

```sh
tools/pocket/mame_oracle.sh tools/mame_wrally_oki.lua wrally \
    OKI_OUT=build/mame/wav/race_oki.txt OKI_FRAMES=3000 INPUTS=race \
    -- -wavwrite build/mame/wav/race.wav
python3 -I tools/pocket/oki_model.py build/pocket/wrally.rom build/mame/wav/race_oki.txt 3000 \
    build/mame/wav/race_model.s16 --chan build/mame/wav/race_model.chan
OKI_CHAN=1 sim/oki/build.sh
build/obj_oki_chan/tb_oki build/pocket/wrally.rom build/mame/wav/race_oki.txt build/sim/oki.s16 \
    --chan build/sim/oki.chan
python3 -I tools/pocket/match_oki_channels.py build/sim/oki.chan build/mame/wav/race_model.chan
python3 -I tools/pocket/match_audio.py build/sim/oki.s16 build/mame/wav/race.wav --gain 16
```

`mame_wrally_oki.lua` logs every write the game makes to the OKI and its
bank, with the clock it fell on; MAME's `-wavwrite` records the sound beside
it. `oki_model.py` plays the log the way MAME's okim6295 does, in Python, and
`tb_oki` plays it through the core's OKI (jt6295 and the bank) alone, which
takes minutes where the whole board takes hours. `match_oki_channels.py`
compares the four voices value for value, phrase by phrase, and
`match_audio.py` compares the sound with MAME's WAV second by second, after
averaging over each OKI sample. `tb_wrally --audio` writes the whole board's
sound for the same comparison (already at MAME's level, so no `--gain`).
