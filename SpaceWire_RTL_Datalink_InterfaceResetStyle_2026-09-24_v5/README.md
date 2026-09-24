# spw_datalink interface/reset-style candidate v5

v5 is a style-only copy of v4. It preserves v4 and the original RTL.
The layout follows `docs/RTL_RULES.md` `CODE-05` and `CODE-06`.

## Requested changes

1. Port declarations are visually grouped in this order: clock/hardware
   reset; TX data I/F; TX control I/F; RX data I/F; RX control I/F; then
   link-wide control/status. Blank lines separate groups. RX-only children
   omit empty TX groups. No port name, direction, width, or connection changed;
   all 78 declarations across the four modules match v4 exactly.
2. F/Fs show the asynchronous hardware reset as the outer
   `if (!i_rst_n)` branch. Synchronous reset/flush and normal state updates
   are nested under its clocked `else` branch. No register has a second
   driver, and no reset source, value, edge, or priority changed. The
   register-by-register inventory is in `RESET_MATRIX.md`.

This does **not** implement the broader reset-architecture proposal in
`docs/RTL_RULES.md`; that would need a separate approved functional gate.

## Evidence

- `bash SpaceWire_RTL_Datalink_InterfaceResetStyle_2026-09-24_v5/run_candidate_regression.sh`:
  8 directed tests, 3 child contracts, story, 4 GTKWave checks, and 64-item
  burst all PASS. Burst network-accept span remains 2,632 cycles.
- `bash SpaceWire_RTL_Datalink_InterfaceResetStyle_2026-09-24_v5/run_dual_comparison.sh`:
  96 ordered items each direction under RX backpressure; all printed
  metrics identical to v4.
- Verilator 5.038 `-Wall`: 23 warnings, same categories/counts as v4.
- Original `spw_datalink.sv` SHA-256 remains
  `448949104d9b981e0ba86a41ab8b213fa637104af298b2f534efc2642af8fc42`.

v5 remains a candidate, not the default or a proven PPA
improvement. No synthesis/timing or formal equivalence was run.
