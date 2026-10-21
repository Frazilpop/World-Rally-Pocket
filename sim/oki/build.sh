#!/usr/bin/env bash
# Build the OKI replay harness. Run from the repository root.
#   sim/oki/build.sh [extra verilator args]
# OKI_CHAN=1 builds tb_oki's --chan (jt6295's channels, in build/obj_oki_chan;
# jt6295's own SIMULATION block then writes jt6295.raw where tb_oki runs).
set -euo pipefail
J6=third_party/jt6295/hdl
CH=()
if [ "${OKI_CHAN:-}" = 1 ]; then
  OBJ="${OBJ:-build/obj_oki_chan}"
  CH=(-DSIMULATION --public-flat-rw -CFLAGS -DOKI_CHAN)
fi
OBJ="${OBJ:-build/obj_oki}"
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style \
  --top-module wrally_oki --Mdir "$OBJ" -o tb_oki -CFLAGS -O2 ${CH[@]+"${CH[@]}"} "$@" \
  rtl/sound/wrally_oki.v $J6/jt6295.v $J6/jt6295_acc.v $J6/jt6295_adpcm.v $J6/jt6295_ctrl.v \
  $J6/jt6295_rom.v $J6/jt6295_serial.v $J6/jt6295_sh_rst.v $J6/jt6295_timing.v \
  $J6/jt12_interpol.v $J6/jt12_comb.v \
  sim/oki/tb_oki.cpp
