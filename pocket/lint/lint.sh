#!/bin/sh
# Verilator lint of the Pocket shell around the real board, controller and
# agg23 IP, with Intel primitives stubbed (altera_stubs.v). Run from anywhere.
# The board's own files are linted for errors only (lint.vlt); its behaviour
# is checked by its harness, sim/wrally. fx68k is its hdl/verilator/
# variant, as the harness has it (Verilator cannot take the synthesis one).
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fpga=$repo/pocket/src/fpga
tp=$repo/third_party/pocket-utils/ip
JR=$repo/third_party/jtcores/modules/jtframe/hdl/ram
J6=$repo/third_party/jt6295/hdl
J8=$repo/third_party/jtcores/modules/jt8051/hdl
r=$repo/rtl
verilator --lint-only -Wall --top-module core_top \
  -Wno-DECLFILENAME -Wno-MULTITOP -Wno-TIMESCALEMOD -Wno-EOFNEWLINE \
  +incdir+"$repo/build/gen/jt8051" \
  "$here/lint.vlt" \
  "$here/altera_stubs.v" \
  "$fpga/apf/common.v" \
  "$fpga/core/mf_pllbase.v" "$fpga/core/mf_pllbase/mf_pllbase_0002.v" \
  "$fpga/core/pin_ddio_clk.v" \
  "$fpga/core/core_bridge_cmd.v" \
  "$tp/data_loader.sv" "$tp/sync_fifo.sv" "$tp/sound_i2s.sv" \
  "$r/mem/kaneko_sdram.sv" "$r/mem/kaneko_sdram_x2.sv" \
  "$r/top/wrally_board.sv" "$r/mem/wrally_romport.sv" "$r/mem/wrally_vmem.v" \
  "$r/cpu/wrally_main.v" "$r/cpu/wrally_addr_decode.v" "$r/cpu/wrally_cpu_clk.sv" \
  "$r/cpu/wrally_vram_decrypt.v" "$r/cpu/wrally_iolatch.v" \
  "$r/io/wrally_inputs.v" "$r/mcu/wrally_mcu.v" \
  "$J8/jt8051.v" "$J8/jt8051_ctrl.v" "$J8/jt8051_regs.v" "$J8/jt8051_alu.v" \
  "$J8/jt8051_periph.v" "$J8/jt8051_serial.v" \
  "$r/sound/wrally_oki.v" "$J6/jt6295.v" "$J6/jt6295_acc.v" "$J6/jt6295_adpcm.v" "$J6/jt6295_ctrl.v" \
  "$J6/jt6295_rom.v" "$J6/jt6295_serial.v" "$J6/jt6295_sh_rst.v" "$J6/jt6295_timing.v" \
  "$J6/jt12_interpol.v" "$J6/jt12_comb.v" \
  "$r/video/wrally_video_top.v" "$r/video/wrally_video_timing.v" "$r/video/wrally_video.v" \
  "$r/video/wrally_tilemap.v" "$r/video/wrally_tile_attr.v" "$r/video/wrally_sprite_layer.v" \
  "$r/video/wrally_sprite_engine.v" "$r/video/wrally_palette.v" \
  "$JR/jtframe_dual_ram16.v" "$JR/jtframe_dual_ram.v" "$JR/jtframe_ram_rst.v" "$JR/jtframe_ram.v" \
  "$repo"/third_party/fx68k/hdl/verilator/*.sv \
  "$fpga/core/pocket_sync.sv" "$fpga/core/pocket_rom_loader.sv" \
  "$fpga/core/pocket_video.sv" "$fpga/core/pocket_diag.sv" \
  "$fpga/core/pocket_audio.sv" \
  "$fpga/core/core_top.v" "$@"
