#!/usr/bin/env bash
set -euo pipefail

STORY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$STORY_DIR"

RTL_DIR="${1:-$STORY_DIR/rtl_reviewed_v2}"
BUILD_DIR="$STORY_DIR/build"
TB_FILE="$STORY_DIR/tb/tb_spw_story.sv"
VVP_FILE="$BUILD_DIR/tb_spw_story.vvp"

mkdir -p "$BUILD_DIR"

iverilog -g2012 -Wall -s tb_spw_story -o "$VVP_FILE" \
  "$RTL_DIR/spw_phy.sv" "$RTL_DIR/spw_enc.sv" \
  "$RTL_DIR/spw_datalink.sv" "$RTL_DIR/spw_network.sv" "$RTL_DIR/spw_top.sv" \
  "$TB_FILE"

(cd "$BUILD_DIR" && vvp "$VVP_FILE")

echo "Generated: $BUILD_DIR/spw_story.vcd"
echo "Open one preset: (cd $BUILD_DIR && gtkwave link_initialize.gtkw)"
