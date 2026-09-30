#!/usr/bin/env bash
set -euo pipefail

STORY_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${1:-$STORY_DIR/../rtl_protocol_refactor}"

for TOOL in iverilog vvp python3; do
  command -v "$TOOL" >/dev/null 2>&1 || {
    echo "ERROR: required tool is not installed: $TOOL" >&2
    exit 1
  }
done

rm -f "$STORY_DIR/tb_spw_story.vvp"
iverilog -g2012 -Wall -s tb_spw_story -o "$STORY_DIR/tb_spw_story.vvp" \
  "$RTL_DIR/spw_phy.sv" "$RTL_DIR/spw_enc.sv" \
  "$RTL_DIR/spw_datalink.sv" "$RTL_DIR/spw_network.sv" "$RTL_DIR/spw_top.sv" \
  "$STORY_DIR/spw_wave_observer.sv" \
  "$STORY_DIR/tb_spw_story.sv"

VCD_FILE="$STORY_DIR/spw_story.vcd"
rm -f "$VCD_FILE"
(cd "$STORY_DIR" && vvp ./tb_spw_story.vvp)

if [[ ! -s "$VCD_FILE" ]]; then
  echo "ERROR: simulation completed without a non-empty VCD: $VCD_FILE" >&2
  exit 1
fi

python3 "$STORY_DIR/check_gtkw_signals.py" "$VCD_FILE" \
  "$STORY_DIR/overview.gtkw" \
  "$STORY_DIR/link_initialize.gtkw" \
  "$STORY_DIR/flow_control.gtkw" \
  "$STORY_DIR/error_recovery.gtkw"

echo "Generated: $VCD_FILE"
echo "Open overview: gtkwave $VCD_FILE $STORY_DIR/overview.gtkw"
