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
rm -f "$BUILD_DIR/tb_spw_enc_contract.vcd"
(cd "$BUILD_DIR" && vvp ./tb_enc.vvp)
test -s "$BUILD_DIR/tb_spw_enc_contract.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_enc_contract.vcd" >&2
  exit 1
}

iverilog -g2012 -Wall -s tb_spw_datalink_contract -o "$BUILD_DIR/tb_dl.vvp" \
  "$ROOT_DIR/spw_datalink.sv" "$ROOT_DIR/tb/tb_spw_datalink_contract.sv"
rm -f "$BUILD_DIR/tb_spw_datalink_contract.vcd"
(cd "$BUILD_DIR" && vvp ./tb_dl.vvp)
test -s "$BUILD_DIR/tb_spw_datalink_contract.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_datalink_contract.vcd" >&2
  exit 1
}

iverilog -g2012 -Wall -s tb_spw_datalink_p0 -o "$BUILD_DIR/tb_dl_p0.vvp" \
  "$ROOT_DIR/spw_datalink.sv" "$ROOT_DIR/tb/tb_spw_datalink_p0.sv"
rm -f "$BUILD_DIR/tb_spw_datalink_p0.vcd"
(cd "$BUILD_DIR" && vvp ./tb_dl_p0.vvp)
test -s "$BUILD_DIR/tb_spw_datalink_p0.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_datalink_p0.vcd" >&2
  exit 1
}

iverilog -g2012 -Wall -s tb_spw_enc_bit_timing -o "$BUILD_DIR/tb_enc_timing.vvp" \
  "$ROOT_DIR/spw_enc.sv" "$ROOT_DIR/tb/tb_spw_enc_bit_timing.sv"
rm -f "$BUILD_DIR/tb_spw_enc_bit_timing.vcd"
(cd "$BUILD_DIR" && vvp ./tb_enc_timing.vvp)
test -s "$BUILD_DIR/tb_spw_enc_bit_timing.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_enc_bit_timing.vcd" >&2
  exit 1
}

iverilog -g2012 -Wall -s tb_spw_network_tx_handshake -o "$BUILD_DIR/tb_net_tx.vvp" \
  "$ROOT_DIR/spw_network.sv" "$ROOT_DIR/tb/tb_spw_network_tx_handshake.sv"
rm -f "$BUILD_DIR/tb_spw_network_tx_handshake.vcd"
(cd "$BUILD_DIR" && vvp ./tb_net_tx.vvp)
test -s "$BUILD_DIR/tb_spw_network_tx_handshake.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_network_tx_handshake.vcd" >&2
  exit 1
}

iverilog -g2012 -Wall -s tb_spw_enc_lifecycle -o "$BUILD_DIR/tb_enc_lifecycle.vvp" \
  "$ROOT_DIR/spw_enc.sv" "$ROOT_DIR/tb/tb_spw_enc_lifecycle.sv"
rm -f "$BUILD_DIR/tb_spw_enc_lifecycle.vcd"
(cd "$BUILD_DIR" && vvp ./tb_enc_lifecycle.vvp)
test -s "$BUILD_DIR/tb_spw_enc_lifecycle.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_enc_lifecycle.vcd" >&2
  exit 1
}

iverilog -g2012 -Wall -s tb_spw_net_rx_handshake -o "$BUILD_DIR/tb_net_rx.vvp" \
  "$ROOT_DIR/spw_datalink.sv" "$ROOT_DIR/spw_network.sv" \
  "$ROOT_DIR/tb/tb_spw_net_rx_handshake.sv"
rm -f "$BUILD_DIR/tb_spw_net_rx_handshake.vcd"
(cd "$BUILD_DIR" && vvp ./tb_net_rx.vvp)
test -s "$BUILD_DIR/tb_spw_net_rx_handshake.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_net_rx_handshake.vcd" >&2
  exit 1
}

iverilog -g2012 -Wall -s tb_spw_datalink_semantics -o "$BUILD_DIR/tb_dl_semantics.vvp" \
  "$ROOT_DIR/spw_datalink.sv" "$ROOT_DIR/tb/tb_spw_datalink_semantics.sv"
rm -f "$BUILD_DIR/tb_spw_datalink_semantics.vcd"
(cd "$BUILD_DIR" && vvp ./tb_dl_semantics.vvp)
test -s "$BUILD_DIR/tb_spw_datalink_semantics.vcd" || {
  echo "ERROR: missing/empty VCD: $BUILD_DIR/tb_spw_datalink_semantics.vcd" >&2
  exit 1
}

# Keep human waveform views synchronized with this RTL candidate. The story
# runner compiles against ROOT_DIR, regenerates spw_story.vcd, and validates
# every signal path in all four GTKWave presets.
STORY_DIR="$ROOT_DIR/../story_waveforms"
"$STORY_DIR/run_story.sh" "$ROOT_DIR"

echo "VCD: $BUILD_DIR/tb_spw_enc_contract.vcd"
echo "VCD: $BUILD_DIR/tb_spw_datalink_contract.vcd"
echo "VCD: $BUILD_DIR/tb_spw_datalink_p0.vcd"
echo "VCD: $BUILD_DIR/tb_spw_enc_bit_timing.vcd"
echo "VCD: $BUILD_DIR/tb_spw_network_tx_handshake.vcd"
echo "VCD: $BUILD_DIR/tb_spw_enc_lifecycle.vcd"
echo "VCD: $BUILD_DIR/tb_spw_net_rx_handshake.vcd"
echo "VCD: $BUILD_DIR/tb_spw_datalink_semantics.vcd"
echo "VCD: $STORY_DIR/spw_story.vcd"
