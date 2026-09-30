# spw_datalink interface/reset-style candidate v5 + DECISION-17 experiment

This directory is still an isolated candidate. The original v5 was a
style-only copy of v4; the current candidate adds DECISION-17 Option B. v4
and the default RTL are unchanged. The original layout follows
`docs/RTL_RULES.md` `CODE-05` and `CODE-06`.

## DECISION-17 experiment

`spw_datalink_tx.svh` now counts Timecode requests selected while an FCT or
credited N-Char is ready. After eight such selections, it grants one slot to
the other traffic and clears the count. The count changes only when the
one-entry request buffer selects a new character, so a held Encoder request
or the second character of an ESC pair cannot be counted twice. Hardware
reset and ErrorReset clear it.

`tb_spw_decision17_tc_starvation.sv` reproduces golden model scenario_24's
two-node direction and maximum-rate Timecode request toggle. It also accepts
link-rate and request-period parameters for the periodic cases below. It
sends 300 DATA bytes plus EOP from B to A, checks the byte pattern,
Timecode/FCT progress, throttle count, and has a 140,000-cycle bound.

| RTL under this TB | Result |
|---|---|
| Original v5, reconstructed from `HEAD` | FAIL: RX stuck at 16/300 after 140,000 cycles; 2,499 Timecodes, 2 FCTs, no credit/ESC error |
| v5 with DECISION-17 | PASS: 300/300 plus EOP in 16,927 cycles; 291 Timecodes, 38 FCTs, 72 throttle grants, no credit/ESC error |

The source golden model's scenario_24 also passes: 501/501 items in 72,360
cycles versus its 50,280-cycle no-Timecode baseline (1.44x). Different RTL
and model cycle counts are not compared for equivalence.

### Rate-dependent follow-up (2026-09-25)

The same two-node, 300-byte setup uses one-cycle Timecode request pulses
every 70 or 100 clocks (700 or 1,000 ns at 100 MHz). The four periodic
configurations now run from the parameterized TB in `run_candidate_regression.sh`.
The original v5 was reconstructed from `HEAD` for the before comparison;
that negative control is recorded evidence, not a routine regression case.

| TX rate | Request period | Original v5 | This candidate | Max contested-TC count / yield grants |
|---|---|---|---|---|
| 10 Mbps | 700 ns | stalled at RX 16/300 | 300/300 + EOP, 42,307 cycles | 8 / 51 |
| 10 Mbps | 1,000 ns | stalled at RX 32/300 | 300/300 + EOP, 40,067 cycles | 8 / 48 |
| 25 Mbps | 700 ns | 300/300 + EOP | 300/300 + EOP, 12,095 cycles | 3 / 0 |
| 25 Mbps | 1,000 ns | 300/300 + EOP | 300/300 + EOP, 12,095 cycles | 1 / 0 |

A Timecode occupies 14 serial bits (4-bit ESC plus 10-bit data character):
1.4 us at 10 Mbps and 560 ns at 25 Mbps, before implementation overhead.
Thus the 700–1,000 ns request period is not merely a synthetic maximum-rate
case at 10 Mbps. These four cases do not establish an all-rate guarantee.
See `../docs/handover/HANDOVER_DECISION17_RATE_ENVELOPE_2026-09-25.md` for
the adoption and architecture decisions still open.

The five-case TB is part of `run_candidate_regression.sh`. After the change, the
existing directed, child-contract, story, GTKWave and 64-item burst tests pass;
the burst span remains 2,632 cycles. `run_dual_comparison.sh` still reports
identical v4/v5 metrics for its ordinary dual-endpoint traffic.

Risk: the throttle intentionally grants an FCT or N-Char ahead of a pending
Broadcast after eight contested selections. ECSS 5.5.6.a states an absolute
Broadcast priority, so this exceptional behavior needs a system-level
standard-compliance decision before adoption. The new TB covers one sustained
traffic pattern and bound; synthesis/timing and formal equivalence were not
run. The default RTL has not been replaced or merged.

## Original v5 style changes

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

## Original v5 evidence (before DECISION-17)

- `bash rtl/candidates/datalink-v5/run_candidate_regression.sh`:
  8 directed tests, 3 child contracts, story, 4 GTKWave checks, and 64-item
  burst all PASS. Burst network-accept span remains 2,632 cycles.
- `bash rtl/candidates/datalink-v5/run_dual_comparison.sh`:
  96 ordered items each direction under RX backpressure; all printed
  metrics identical to v4.
- Verilator 5.038 `-Wall`: 23 warnings, same categories/counts as v4.
- Original `spw_datalink.sv` SHA-256 remains
  `448949104d9b981e0ba86a41ab8b213fa637104af298b2f534efc2642af8fc42`.

The original v5 was a style candidate, not a proven PPA improvement.
