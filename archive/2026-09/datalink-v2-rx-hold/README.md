# spw_datalink RX holding submodule candidate v2

## Change

Based on `main@49fdf403` and the review split v1, this candidate extracts the
one-entry Network RX holding register into `spw_datalink_rx_hold.sv` (74 lines).
The parent `spw_datalink.sv` remains the public RTL module (167 lines plus five
concern-based includes). The original RTL and v1 remain unchanged.

The child owns `valid/data/is_ctrl` registers, `valid && ready` acceptance,
blocked overwrite detection, and the P11 stability check. The parent owns
protocol decoding, immediate-error priority, Link FSM, credit, and TX. It
passes the decoded event, error gate, and original ErrorReset-entry flush to
the child. See [BOUNDARY_MAP.md](BOUNDARY_MAP.md) for exact signal and reset
mapping. No new register or cycle stage was introduced.

Compile with both `spw_datalink_rx_hold.sv` and `spw_datalink.sv`, plus
`-I archive/2026-09/datalink-v2-rx-hold` for the include files.

## Comparison with the original

| Check | Original | v2 |
|---|---:|---:|
| Directed RTL tests | 8/8 PASS | 8/8 PASS |
| RX holding focused contract | not present | PASS; non-empty VCD |
| Story / GTKWave presets | PASS / 4/4 | PASS / 4/4 |
| 64-item ordered RX | 64/64 | 64/64 |
| Network accept span | 2,632 cycles | 2,632 cycles |
| Network accept gaps | 56 × 40, 7 × 56 cycles | same |
| Measured payload rate | 19.15 Mbps | 19.15 Mbps |
| Verilator 5.038 `-Wall` warnings | 24 | 24, same categories |

Reproduce from repository root:

```bash
bash archive/2026-09/datalink-v2-rx-hold/run_candidate_regression.sh
```

The candidate runner reuses the original four other RTL modules and original
TB/story/GTKWave assets. It writes generated files under the candidate's
ignored `build/`. The focused `tb_spw_rx_hold_contract.sv` checks held data,
same-cycle pop/replacement, error suppression, and flush priority.

## Limitations and next gate

The current tests establish directed cycle behavior, not independent protocol
equivalence or FPGA timing/area. The parent still owns most of Data Link's
shared state. Existing Verilator width/unused/reset warnings remain open.
The next possible extraction is RX ESC/decode; it would move
`r_rx_pending_esc` and therefore require observer/GTKWave probe migration and
a separately checked event-cycle contract. Do not combine that change with
credit or reset restructuring.
