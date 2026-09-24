# Dual-endpoint backpressure gate (2026-09-24)

This is a measurement-only, same-stimulus comparison of the original
`main@49fdf403` RTL and the v4 credit extraction. No RTL file is changed.

Run from the repository root:

```bash
bash performance_dual_backpressure_2026-09-24/run_dual_backpressure.sh
```

The TB cross-connects two `spw_top` instances at 100 MHz / 25 Mbps. Each
sends 96 distinct ordered DATA items. Endpoint A's host RX is held not-ready
for approximately 6,000 clocks, then ready for three of every four clocks;
endpoint B's host RX is always ready. Both use 32-entry RX FIFOs. Assertions
check both directions for count, order, unexpected link/credit errors, actual
RX FIFO full, B's network TX wait, and completion of A→B before A's host RX
stall is released.

| Metric | Original | v4 |
|---|---:|---:|
| Host TX / network TX / host RX, each endpoint | 96 / 96 / 96 | 96 / 96 / 96 |
| A host RX initial stall cycles | 5,999 | 5,999 |
| A RX FIFO full cycles during initial stall | 4,631 | 4,631 |
| B network TX wait cycles | 8,468 | 8,468 |
| A→B completion / stall-release cycle | 5,910 / 8,029 | 5,910 / 8,029 |
| Result | PASS | PASS |

All printed `DUAL` metrics are required to match exactly by the runner.
Generated build files and logs are under `build/`.

Icarus 12 compiles this two-top TB but its `vvp` aborts at simulation
startup with an internal `vvp_fun_anyedge_sa` assertion for both versions;
that is a simulator failure, not a DUT verdict. This gate therefore uses
Verilator 5.038 `--binary --timing`. No VCD is produced in this gate.

Scope limit: one clock/rate, finite DATA-only burst, one asymmetric RX stall
schedule. It strengthens flow-control/backpressure evidence but is neither
formal equivalence nor synthesis timing/area evidence.
