# SpaceWire protocol-interface refactor candidate

This directory is a separate candidate derived from `rtl_reviewed_v2` according
to `Spec2rtl_refactoring_prompt.txt`. The source upload and reviewed-v2 baseline
remain unchanged.

## Run

```bash
sudo apt-get install iverilog
./run_regression.sh
```

The script compiles `spw_top`, runs every directed test, generates one VCD per
test, and fails if any VCD is missing or empty.

## Contract implemented

- Network → DataLink TX: `net_tx_data/valid/ready`; FIFO ownership moves only
  on `valid && ready`.
- DataLink → Encoder TX: registered request plus `ready`, `commit`, and `abort`.
- DataLink owns `TXK_*` protocol metadata; Encoder remains character-semantic
  agnostic.
- N-Char and independent-FCT credit updates occur on wire `COMMIT`, not request
  selection or Encoder acceptance.
- Null and Broadcast ESC sequences schedule their second character only after
  ESC commit and cannot interleave another request.
- DataLink → Network RX: `net_rx_data/valid/ready` with a one-entry holding
  register; blocked physical overwrite is reported as an invariant violation.
- Encoder → DataLink RX remains an unstalled event channel.

## Verification

`run_regression.sh` runs eight tests and always emits eight checked VCDs. See
`PROTOCOL_REFACTOR_REPORT.md` for the interface map, step-by-step change record,
P1–P12 evidence, scenario coverage, and remaining risks.
