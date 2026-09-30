#!/usr/bin/env bash
set -euo pipefail

CANDIDATE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$CANDIDATE_DIR/../../.." && pwd)"
BASE_DIR="$REPO_DIR/rtl/baseline"
RTL_DIR="$BASE_DIR/rtl_protocol_refactor"
STORY_DIR="$BASE_DIR/story_waveforms"
BUILD_DIR="$CANDIDATE_DIR/build"
mkdir -p "$BUILD_DIR"

SOURCES=(
  "$RTL_DIR/spw_phy.sv"
  "$RTL_DIR/spw_enc.sv"
  "$CANDIDATE_DIR/spw_datalink.sv"
  "$RTL_DIR/spw_network.sv"
  "$RTL_DIR/spw_top.sv"
)

iverilog -g2012 -I "$CANDIDATE_DIR" -s spw_top \
  -o "$BUILD_DIR/spw_top.vvp" "${SOURCES[@]}" 2>"$BUILD_DIR/top_compile.log"

for TB in \
  tb_spw_enc_contract tb_spw_datalink_contract tb_spw_datalink_p0 \
  tb_spw_enc_bit_timing tb_spw_network_tx_handshake \
  tb_spw_enc_lifecycle tb_spw_net_rx_handshake tb_spw_datalink_semantics
do
  iverilog -g2012 -I "$CANDIDATE_DIR" -s "$TB" \
    -o "$BUILD_DIR/$TB.vvp" "${SOURCES[@]}" \
    "$RTL_DIR/tb/$TB.sv" 2>"$BUILD_DIR/$TB.compile.log"
  (cd "$BUILD_DIR" && vvp "./$TB.vvp")
  test -s "$BUILD_DIR/$TB.vcd"
done

iverilog -g2012 -I "$CANDIDATE_DIR" -s tb_spw_story \
  -o "$BUILD_DIR/tb_spw_story.vvp" "${SOURCES[@]}" \
  "$STORY_DIR/spw_wave_observer.sv" "$STORY_DIR/tb_spw_story.sv" \
  2>"$BUILD_DIR/tb_spw_story.compile.log"
(cd "$BUILD_DIR" && vvp ./tb_spw_story.vvp)
test -s "$BUILD_DIR/spw_story.vcd"
python3 "$STORY_DIR/check_gtkw_signals.py" "$BUILD_DIR/spw_story.vcd" \
  "$STORY_DIR/overview.gtkw" "$STORY_DIR/link_initialize.gtkw" \
  "$STORY_DIR/flow_control.gtkw" "$STORY_DIR/error_recovery.gtkw"

iverilog -g2012 -I "$CANDIDATE_DIR" -s tb_spw_perf_burst \
  -o "$BUILD_DIR/tb_spw_perf_burst.vvp" "${SOURCES[@]}" \
  "$REPO_DIR/verification/performance/burst/tb_spw_perf_burst.sv" \
  2>"$BUILD_DIR/tb_spw_perf_burst.compile.log"
(cd "$BUILD_DIR" && vvp ./tb_spw_perf_burst.vvp)

echo "PASS candidate regression: 8 directed + story + 4 presets + 64-item burst"
