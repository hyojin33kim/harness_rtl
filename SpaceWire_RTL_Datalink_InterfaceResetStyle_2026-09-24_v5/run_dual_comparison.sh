#!/usr/bin/env bash
set -euo pipefail
CANDIDATE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$CANDIDATE_DIR/.." && pwd)"
RTL_DIR="$REPO_DIR/SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor"
TB="$REPO_DIR/performance_dual_backpressure_2026-09-24/tb_spw_dual_backpressure.sv"
BUILD_DIR="$CANDIDATE_DIR/build"
mkdir -p "$BUILD_DIR"
for variant in v4 v5; do
  if [[ "$variant" == v4 ]]; then
    RTL_CANDIDATE="$REPO_DIR/SpaceWire_RTL_Datalink_Credit_2026-09-24_v4"
  else
    RTL_CANDIDATE="$CANDIDATE_DIR"
  fi
  obj_dir="$BUILD_DIR/obj_dual_$variant"
  CCACHE_DISABLE=1 verilator --binary --timing -Wno-fatal \
    --top-module tb_spw_dual_backpressure --Mdir "$obj_dir" \
    -I"$RTL_CANDIDATE" \
    "$RTL_DIR/spw_phy.sv" "$RTL_DIR/spw_enc.sv" \
    "$RTL_CANDIDATE/spw_datalink_rx_hold.sv" \
    "$RTL_CANDIDATE/spw_datalink_rx_decode.sv" \
    "$RTL_CANDIDATE/spw_datalink_credit.sv" \
    "$RTL_CANDIDATE/spw_datalink.sv" \
    "$RTL_DIR/spw_network.sv" "$RTL_DIR/spw_top.sv" "$TB" \
    >"$BUILD_DIR/dual_$variant.compile.log" 2>&1
  "$obj_dir/Vtb_spw_dual_backpressure" >"$BUILD_DIR/dual_$variant.run.log"
  grep '^DUAL\|^PASS' "$BUILD_DIR/dual_$variant.run.log"
done
diff -u <(grep '^DUAL' "$BUILD_DIR/dual_v4.run.log") \
        <(grep '^DUAL' "$BUILD_DIR/dual_v5.run.log")
echo "PASS v4/v5 dual-endpoint metrics identical"
