#!/usr/bin/env bash
# Build sim/wrally/sdr_stress.cpp (the shell's SDRAM path under a worst-case
# load) for one URGENT mask. Run from the repository root.
#   [RDL=n] sim/wrally/build_stress.sh [urgent, 6 bits, default core_top.v's]
#   build/obj_stress_<urgent>_<rdl>/sdr_stress <frames> [seed]
# RDL is kaneko_sdram's rd_lat_sel, default 2 (CL+2, the card's).
set -euo pipefail
U="${1:-$(sed -n "s/.*\.URGENT *(6'b\([01_]*\)).*/\1/p" pocket/src/fpga/core/core_top.v | tr -d _)}"
OBJ="build/obj_stress_${U}_${RDL:-2}"
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 -Wno-fatal -Wno-lint -Wno-style \
  --top-module sdr_timing --prefix Vsdr_timing --Mdir "$OBJ" -o sdr_stress \
  -GURGENT=6\'b"$U" -GRD_LAT_SEL=${RDL:-2} -CFLAGS -O2 -CFLAGS "-DURGENT_STR=\\\"$U\\\"" \
  sim/wrally/sdr_timing.sv rtl/mem/kaneko_sdram_x2.sv rtl/mem/kaneko_sdram.sv sim/mem/sdram_model.sv \
  sim/wrally/sdr_stress.cpp > "$OBJ/build.log" 2>&1 || { tail -20 "$OBJ/build.log"; exit 1; }
echo "$OBJ/sdr_stress"
