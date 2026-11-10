# Third-party code and licences

This core is **GPL-3.0-only** as a whole, because fx68k is (see below). This
file lists each dependency and what its licence asks for.

## Fetched by `tools/bootstrap.sh`

These land in `third_party/`, pinned in `deps.lock`, and are never committed.

| Component | Licence | Used for |
|---|---|---|
| [jlrh/gaelco-fpga](https://github.com/jlrh/gaelco-fpga) | GPL-3.0 | The upstream of the board files in `rtl/` (see below); fetched for reference |
| [jtfpga/fx68k](https://github.com/jtfpga/fx68k) | GPL-3.0-only | The 68000 main CPU |
| [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3.0-or-later | The OKI M6295 sound chip |
| [jotego/jtcores](https://github.com/jotego/jtcores) (sparse) | GPL-3.0-or-later | jt8051, the DS5002FP; JTFRAME's RAM blocks; JTFRAME's `ucode` tool, which expands jt8051's microcode at build time |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | MIT | Pocket shell IP: data loader, I2S audio, sync FIFO |
| [mamedev/mame](https://github.com/mamedev/mame) (sparse: World Rally's files and the devices they use) | BSD-3-Clause (World Rally's files) | The reference |

### fx68k – GPL-3.0-only
`deps.lock` pins `jtfpga/fx68k`, which is ijor's code repackaged for jtframe –
`hdl/fx68k.sv` is identical apart from line endings. Synthesis takes `hdl/`;
the simulation takes `hdl/verilator/`, with the nanocode struct flattened,
which Verilator needs. The bootstrap symlinks `microrom.mem` and
`nanorom.mem` into the repo root, where fx68k loads them from.

### jt6295 – GPL-3.0-or-later
Two local patches in `tools/patches/`, applied by the bootstrap in turn
(`pocket/build.sh` refuses to start without them):

- `jt6295-end-byte.patch` – a phrase plays both nibbles of its last byte, as
  MAME's okim6295 does; it used to end one sample short.
- `jt6295-start-on-end-byte.patch` – a voice starts only once the whole of
  its end address has been read from the phrase header, so a slow ROM can't
  cut a phrase short.

The or-later clause is in each `hdl/` file header, and the header counts,
not `LICENSE` – re-read it after every `bootstrap.sh --update`.

### jtcores – GPL-3.0-or-later
Only `modules/jt8051/`, JTFRAME's `hdl/ram/` and its Go source are checked
out. jt8051 runs as the DS5002FP, in a wrapper of this core's
(`rtl/mcu/wrally_mcu.v`). `tools/gen_jt8051.sh` builds JTFRAME's `ucode`
tool (it needs Go) and writes jt8051's microcode into `build/gen/`; nothing
it makes is committed.

### analogue-pocket-utils – MIT
© 2022 Adam Gastineau. Keep the notice.

### MAME – BSD-3-Clause (these files only)
`src/mame/gaelco/wrally.cpp` (© Manuel Abadia, Mike Coates, Nicola Salmoria,
Miguel Angel Horna), `gaelco_wrally_sprites.cpp` (the same, with Luca Elia
and David Haywood), `gaelco_ds5002fp.cpp` (David Haywood) and `gaelcrpt.cpp`
(Manuel Abadia) are the only public documentation of this board, and the
oracle every part of the core is checked against. The Lua scripts in
`tools/` run MAME itself. `tools/pocket/render_dump.py` and `oki_model.py`
are test tools that draw a picture the way MAME's renderer does and play
the sound the way its okim6295 does, written in Python to check the core
against; neither is built into the core.

MAME as a whole is GPL-2.0, and `src/devices/` and `src/emu/` are a mix, so
check each file's header before transcribing anything.

## In the tree

### jlrh/gaelco-fpga – GPL-3.0
The World Rally MiSTer core this is built on, imported from `cores/wrally/hdl/`
at `85fe58b`: the 68000 bus and its address decode, the VRAM decryption and
the LS259 latch (`rtl/cpu/`), the inputs (`rtl/io/`), the video, palette and
sprite memories (`rtl/mem/wrally_vmem.v`), the video timing, the two
tilemaps, the sprite layer and engine, the palette and the mixer
(`rtl/video/`) and the OKI glue (`rtl/sound/`). These files have no headers
of their own; upstream's `LICENSE` is GPL-3.0, kept as `LICENSE` here.
Changes made here are in the git history from the import (`aba581e`) on:
among them the 68000 run on board time, the DS5002FP as jt8051 in place of
the mc8051 netlist, a write queue in front of jt6295 in `wrally_oki.v`, and
the sprite engine rebuilt around jlrh's drawing (a scanner, the next
sprite's graphics fetched while one is drawn, the line buffer cleared behind
the display).

### alphanu1's SDRAM controller – GPL-3.0-or-later
`rtl/mem/kaneko_sdram.sv`, `kaneko_sdram_x2.sv`, `bw_monitor.sv` and
`sim/mem/sdram_model.sv`, unchanged from the Kaneko16 Pocket core (Great
1000 Miles Rally), whose upstream is alphanu1's Kaneko16 MiSTer core. The
controller follows meathax's System 32 controller (GPL-3.0) – keep that note
in the file.

### Analogue openFPGA core template – Analogue's APF Software License Agreement
`pocket/src/fpga/apf/`, `core_bridge_cmd.v` and the Quartus project files are
Analogue's, under the licence in their headers (with Analogue's Pocket EULA),
which yields to the MIT or GNU licence wherever the two disagree. The
Quartus megafunction output beside them (`mf_pllbase`, `pin_ddio_clk`,
`mf_datatable`, `mf_ddio_bidir_12`) is Intel's generated code, and
`build_id_gen.tcl` is Altera's reference design (Altera Reference Design
License), trimmed by Analogue.

## Written for this core

Everything else under `rtl/`, `sim/`, `tools/` and `pocket/` is
GPL-3.0-or-later, as the SPDX line says in each file that has one; the
combination is GPL-3.0-only.

`pocket/art/wrally-banner.png`, the platform image, is made from the game's
logo, © Gaelco.

## ROMs

No ROM images, or anything taken from them, are ever committed or distributed.
They're loaded at runtime, and tools that read them write only to `build/`.
