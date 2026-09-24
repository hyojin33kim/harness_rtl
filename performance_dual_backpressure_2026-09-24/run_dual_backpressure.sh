#!/usr/bin/env bash
set -euo pipefail
GATE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$GATE_DIR/.." && pwd)"
RTL_DIR="$REPO_DIR/SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor"
V4_DIR="$REPO_DIR/SpaceWire_RTL_Datalink_Credit_2026-09-24_v4"
BUILD_DIR="$GATE_DIR/build"
mkdir -p "$BUILD_DIR"

common=(
  "$RTL_DIR/spw_phy.sv"
  "$RTL_DIR/spw_enc.sv"
)
tail_sources=(
  "$RTL_DIR/spw_network.sv"
  "$RTL_DIR/spw_top.sv"
  "$GATE_DIR/tb_spw_dual_backpressure.sv"
)
run_one() {
  local variant="$1"
  shift
  local obj_dir="$BUILD_DIR/obj_$variant"
  CCACHE_DISABLE=1 verilator --binary --timing -Wno-fatal \
    --top-module tb_spw_dual_backpressure --Mdir "$obj_dir" \
    "$@" >"$BUILD_DIR/$variant.compile.log" 2>&1
  "$obj_dir/Vtb_spw_dual_backpressure" >"$BUILD_DIR/$variant.run.log"
  grep '^DUAL\|^PASS' "$BUILD_DIR/$variant.run.log"
}
run_one baseline "${common[@]}" "$RTL_DIR/spw_datalink.sv" "${tail_sources[@]}"
run_one v4 -I"$V4_DIR" "${common[@]}" \
  "$V4_DIR/spw_datalink_rx_hold.sv" \
  "$V4_DIR/spw_datalink_rx_decode.sv" \
  "$V4_DIR/spw_datalink_credit.sv" \
  "$V4_DIR/spw_datalink.sv" "${tail_sources[@]}"
diff -u <(grep '^DUAL' "$BUILD_DIR/baseline.run.log") \
        <(grep '^DUAL' "$BUILD_DIR/v4.run.log")
echo "PASS dual-endpoint baseline/v4 metrics identical"
