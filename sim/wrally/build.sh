#!/usr/bin/env bash
# Build the whole-board harness. Run from the repository root.
#   sim/wrally/build.sh [extra verilator args]
# PIX=jlrh builds the Pocket's frame (8 MHz, 513 x 260, 59.98 Hz, IRQ 6 every
# 200,070 ticks); the default stretches the frame to MAME's 60 Hz and puts
# IRQ 6 every 200,000 ticks, the first at IRQ_FIRST, so a bus trace keeps its
# IRQs in step. IRQ_FIRST 200,003: MAME's vblank is at 200,000 clocks, and
# fx68k samples IPL a few clocks from where MAME's m68000 does; swept from
# 199,988 to 200,012 over the power-on ROM test's 39 IRQs, only 200,003 and
# 200,004 put every one on MAME's instruction. MCU_LAG: wrally_board. jt8051's microcode headers are made
# here with jtframe's ucode tool (Go) into build/gen/jt8051.
# SDR=real times the ROM lines with the shell's SDRAM controller
# (sim/wrally/sdr_timing.sv, built first as its own model) instead of the
# harness's fixed latency.
set -euo pipefail
JR=third_party/jtcores/modules/jtframe/hdl/ram
J8=third_party/jtcores/modules/jt8051
J6=third_party/jt6295/hdl
OBJ="${OBJ:-build/obj_wrally}"
mkdir -p "$OBJ" build/tmp build/gen
if [ ! -f build/gen/jt8051/jt8051.vh ] || [ $J8/ucode/8051.yaml -nt build/gen/jt8051/jt8051.vh ]; then
  tools/gen_jt8051.sh build/gen/jt8051
fi
cmp -s build/gen/jt8051/jt8051.uc build/gen/jt8051.uc || cp build/gen/jt8051/jt8051.uc build/gen/
export TMPDIR="$PWD/build/tmp"
# $readmem files, read relative to where tb_wrally runs (--gen-dir)
cmp -s third_party/fx68k/hdl/microrom.mem build/gen/microrom.mem || cp third_party/fx68k/hdl/microrom.mem build/gen/
cmp -s third_party/fx68k/hdl/nanorom.mem build/gen/nanorom.mem || cp third_party/fx68k/hdl/nanorom.mem build/gen/
SDRG=()
if [ "${SDR:-}" = real ]; then
  SO="${OBJ}_sdr"
  verilator --cc -O3 --x-assign fast --x-initial 0 -Wno-fatal -Wno-lint -Wno-style \
    --top-module sdr_timing --prefix Vsdr_timing --Mdir "$SO" \
    sim/wrally/sdr_timing.sv rtl/mem/kaneko_sdram_x2.sv rtl/mem/kaneko_sdram.sv sim/mem/sdram_model.sv
  make -s -C "$SO" -f Vsdr_timing.mk Vsdr_timing__ALL.a OPT_FAST=-O2
  SDRG=(-CFLAGS -DSDR_REAL -CFLAGS "-I$PWD/$SO" "$PWD/$SO/Vsdr_timing__ALL.a")
fi
if [ "${PIX:-mame}" = jlrh ]; then PIXG=(-GPIX_NUM=1 -GPIX_DEN=6 -GMCU_LAG=${MCU_LAG:-0})
else PIXG=(-GPIX_NUM=6669 -GPIX_DEN=40000 -GIRQ_NUM=1 -GIRQ_DEN=200000 -GIRQ_FIRST=${IRQ_FIRST:-200003}
       -GMCU_LAG=${MCU_LAG:-0}); fi
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  --top-module wrally_board --Mdir "$OBJ" -o tb_wrally \
  +incdir+build/gen/jt8051 \
  "${PIXG[@]}" ${SDRG[@]+"${SDRG[@]}"} -CFLAGS -O2 "$@" \
  rtl/top/wrally_board.sv rtl/mem/wrally_romport.sv \
  rtl/cpu/wrally_main.v rtl/cpu/wrally_addr_decode.v rtl/cpu/wrally_cpu_clk.sv \
  rtl/cpu/wrally_vram_decrypt.v rtl/cpu/wrally_iolatch.v \
  rtl/io/wrally_inputs.v rtl/mcu/wrally_mcu.v \
  $J8/hdl/jt8051.v $J8/hdl/jt8051_ctrl.v $J8/hdl/jt8051_regs.v $J8/hdl/jt8051_alu.v \
  $J8/hdl/jt8051_periph.v $J8/hdl/jt8051_serial.v \
  rtl/sound/wrally_oki.v $J6/jt6295.v $J6/jt6295_acc.v $J6/jt6295_adpcm.v $J6/jt6295_ctrl.v \
  $J6/jt6295_rom.v $J6/jt6295_serial.v $J6/jt6295_sh_rst.v $J6/jt6295_timing.v $J6/jt12_interpol.v $J6/jt12_comb.v \
  rtl/mem/wrally_vmem.v \
  rtl/video/wrally_video_top.v rtl/video/wrally_video_timing.v rtl/video/wrally_video.v \
  rtl/video/wrally_tilemap.v rtl/video/wrally_tile_attr.v rtl/video/wrally_sprite_layer.v \
  rtl/video/wrally_sprite_engine.v rtl/video/wrally_palette.v \
  $JR/jtframe_dual_ram16.v $JR/jtframe_dual_ram.v $JR/jtframe_ram_rst.v $JR/jtframe_ram.v \
  third_party/fx68k/hdl/verilator/*.sv \
  sim/wrally/tb_wrally.cpp
