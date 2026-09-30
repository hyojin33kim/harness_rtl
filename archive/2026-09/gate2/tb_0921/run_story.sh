#!/usr/bin/env bash
set -euo pipefail

STORY_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${1:-$STORY_DIR/../rtl_reviewed_v2}"

iverilog -g2012 -Wall -s tb_spw_story -o "$STORY_DIR/tb_spw_story.vvp" \
  "$RTL_DIR/spw_phy.sv" "$RTL_DIR/spw_enc.sv" \
  "$RTL_DIR/spw_datalink.sv" "$RTL_DIR/spw_network.sv" "$RTL_DIR/spw_top.sv" \
  "$STORY_DIR/tb_spw_story.sv"

VCD_FILE="$STORY_DIR/spw_story.vcd"
rm -f "$VCD_FILE"
(cd "$STORY_DIR" && vvp ./tb_spw_story.vvp)

if [[ ! -s "$VCD_FILE" ]]; then
  echo "ERROR: simulation completed without a non-empty VCD: $VCD_FILE" >&2
  exit 1
fi

for OBS_SIGNAL in obs_tx_char_kind obs_rx_char_kind obs_ser_bit_role \
                  obs_link_init_active obs_flow_blocked obs_recovery_active; do
  if ! grep -q "$OBS_SIGNAL" "$VCD_FILE"; then
    echo "ERROR: VCD is missing observability signal: $OBS_SIGNAL" >&2
    exit 1
  fi
done

echo "Generated: $VCD_FILE"
echo "Open overview: gtkwave $VCD_FILE $STORY_DIR/overview.gtkw"
