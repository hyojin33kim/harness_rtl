#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
mkdir -p "$BUILD_DIR"

iverilog -g2012 -Wall -s spw_top -o "$BUILD_DIR/top_compile.vvp" \
  "$ROOT_DIR/spw_phy.sv" "$ROOT_DIR/spw_enc.sv" \
  "$ROOT_DIR/spw_datalink.sv" "$ROOT_DIR/spw_network.sv" "$ROOT_DIR/spw_top.sv"

iverilog -g2012 -Wall -s tb_spw_enc_contract -o "$BUILD_DIR/tb_enc.vvp" \
  "$ROOT_DIR/spw_enc.sv" "$ROOT_DIR/tb/tb_spw_enc_contract.sv"
vvp "$BUILD_DIR/tb_enc.vvp"

iverilog -g2012 -Wall -s tb_spw_datalink_contract -o "$BUILD_DIR/tb_dl.vvp" \
  "$ROOT_DIR/spw_datalink.sv" "$ROOT_DIR/tb/tb_spw_datalink_contract.sv"
vvp "$BUILD_DIR/tb_dl.vvp"
