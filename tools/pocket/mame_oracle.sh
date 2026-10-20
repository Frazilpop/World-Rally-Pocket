#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run one of the tools/mame_wrally_*.lua oracle scripts on a World Rally set,
# reproducibly.
#
#   tools/pocket/mame_oracle.sh <script.lua> <set> [VAR=value ...] [-- mame args]
#
#   tools/pocket/mame_oracle.sh tools/mame_wrally_bus_trace.lua wrally \
#       BUS_TRACE_OUT=build/mame/wrally_bus.txt BUS_TRACE_COUNT=200000
#   tools/pocket/mame_oracle.sh tools/mame_wrally_dump.lua wrally \
#       DUMP_DIR=build/mame/dump/wrally DUMP_FRAME=600,1800 INPUTS=race
#
# What it fixes, every run:
#   * a FRESH, EMPTY nvram directory — MAME keeps the DS5002FP's 32 KB SRAM
#     as NVRAM: it saves it at exit and loads it at start in place of the ROM
#     image, so without this each run starts from the SRAM the last one left
#     behind and two "identical" runs diverge. NVRAM_IN=<dir> seeds it from
#     a directory instead (a run's NVRAM_OUT), NVRAM_OUT=<dir> keeps what
#     MAME saved at exit;
#   * a fresh cfg directory, so no saved DIP or input setting leaks in (every
#     DIP stays at MAME's default, mame_wrally_inputs.lua);
#   * -skip_gameinfo -autoboot_delay 0: without them the script either never
#     loads (warning screen) or installs late;
#   * -snapview native, so screen:snapshot() writes the 368 x 232 visible area;
#   * ROMS (default ~/Downloads) as -rompath; MAME (default mame);
#   * WR_TOOLS, where the scripts find mame_wrally_inputs.lua.
# Relative paths in VAR=value are made absolute (the scripts run with MAME's
# own working directory).

set -eu
[ $# -ge 2 ] || { sed -n '3,11p' "$0"; exit 2; }
script=$1; set_name=$2; shift 2

repo=$(cd "$(dirname "$0")/../.." && pwd)
case $script in /*) ;; *) script=$PWD/$script ;; esac
export WR_TOOLS="$repo/tools"

while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case $1 in
    *=/*|*=) export "$1" ;;
    *_DIR=*|*_OUT=*|*_IN=*) k=${1%%=*}; v=${1#*=}; export "$k=$PWD/$v" ;;
    *=*) export "$1" ;;
    *) echo "mame_oracle.sh: expected VAR=value, got '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ "${1:-}" = "--" ] && shift

mkdir -p "$repo/build/mame/run"
run=$(mktemp -d "$repo/build/mame/run/$set_name.XXXXXX")
trap 'rm -r "$run"' EXIT
mkdir -p "$run/cfg" "$run/nvram" "$run/snap"
[ -n "${NVRAM_IN:-}" ] && cp -R "$NVRAM_IN/." "$run/nvram/"

start=$(date +%s)
"${MAME:-mame}" -rompath "${ROMS:-$HOME/Downloads}" "$set_name" \
  -autoboot_script "$script" -skip_gameinfo -autoboot_delay 0 \
  -video none -sound none -nothrottle -seconds_to_run 3600 -snapview native \
  -cfg_directory "$run/cfg" -nvram_directory "$run/nvram" \
  -snapshot_directory "$run/snap" "$@"
if [ -n "${NVRAM_OUT:-}" ]; then
  mkdir -p "$NVRAM_OUT" && cp -R "$run/nvram/." "$NVRAM_OUT/"
fi
echo "mame_oracle.sh: $set_name finished in $(( $(date +%s) - start )) s"
