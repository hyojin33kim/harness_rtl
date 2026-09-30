# spw_datalink RX decoder submodule candidate v3

## Change

This candidate builds on v2 and extracts RX ESC/character classification to
`spw_datalink_rx_decode.sv`. The decoder owns the single `pending ESC` state
and emits same-cycle Null, FCT, N-Char, Timecode, ESC-error, and
protocol-violation events. The parent remains the Link FSM/error-priority
owner and still uses the v2 RX holding submodule. No pipeline or reset change
was intended. The original RTL and v1/v2 candidates are unchanged.

See `BOUNDARY_MAP.md` for signal and reset ownership. The candidate story TB
connects the observer to the decoder's pending-ESC output through the parent
`w_rx_pending_esc` debug wire. The candidate `error_recovery.gtkw` uses the
observer input signal; other three original presets are reused unchanged.

## Verification against `main@49fdf403`

| Evidence | Result |
|---|---|
| Existing directed RTL tests | 8/8 PASS |
| RX hold and RX decoder contract tests | 2/2 PASS; non-empty VCDs |
| Integrated story | PASS |
| GTKWave signal checks | 4/4 PASS |
| Story cycle metrics | Same as baseline |
| 64-item ordered loopback | 64/64 received; same 2,632-cycle accept span |
| Network accept gaps | 56 × 40 cycles, 7 × 56 cycles; 19.15 Mbps payload |
| Verilator 5.038 `-Wall` | 24 warnings, same categories/counts as baseline |

Run from repository root:

```bash
bash SpaceWire_RTL_Datalink_RxDecode_2026-09-24_v3/run_candidate_regression.sh
```

The runner uses the original PHY, Encoder, Network, top-level, eight directed
TBs, observer, and three unchanged GTKWave presets. Generated VCD/VVP/log
files are under the candidate's ignored `build/`.

## Limitations

The `w_rx_pending_esc` parent wire connects candidate story debug and a
simulation-only boundary invariant: an N-Char event must not be emitted while
the second ESC character is pending. No target synthesis/P&R has been run; matching
cycle behavior does not establish Fmax, area, CDC closure, or independent ECSS
equivalence. The next extraction, if justified, is credit/FCT management as a
separate gate with explicit commit-event ownership.
