# spw_datalink credit/FCT submodule candidate v4

The new `spw_datalink_credit.sv` owns TX/RX credit registers, initial-FCT
countdown, immediate credit error, and FCT-send eligibility. The parent keeps
the Link FSM, commit-event classification, TX scheduler, and external interface.
See `BOUNDARY_MAP.md` for reset and signal responsibility.

Run:
```bash
bash SpaceWire_RTL_Datalink_Credit_2026-09-24_v4/run_candidate_regression.sh
```

Evidence against `main@49fdf403`:

| Check | v4 result |
|---|---|
| Existing directed scenarios | 8/8 PASS (three candidate-only hierarchy updates) |
| RX hold/decode and credit contracts | 3/3 PASS |
| Story and GTKWave presets | PASS; 4/4 signal checks |
| Reset release to first RUN | 2,015 cycles, same as baseline |
| 64-item ordered loopback | 64/64; network accept span 2,632 cycles |
| Accept gaps and payload rate | 56 × 40, 7 × 56 cycles; 19.15 Mbps, same as baseline |
| Verilator 5.038 `-Wall` | 23 warnings; no new category (baseline 24) |
| Dual-endpoint RX-backpressure gate | 96 ordered DATA each direction; original/v4 metrics identical (see `../performance_dual_backpressure_2026-09-24/README.md`) |

The original `spw_datalink.sv` SHA-256 remains
`448949104d9b981e0ba86a41ab8b213fa637104af298b2f534efc2642af8fc42`.
v1/v2/v3 and original TB/GTKWave files are untouched. v4 is a candidate,
not the default RTL.

Limitations: no independent ECSS/formal equivalence, synthesis, target
timing, or area result. The dual-endpoint gate covers one DATA-only asymmetric
stall schedule, not broad flow-control stress. Keep this as a candidate until
those gates are selected.
