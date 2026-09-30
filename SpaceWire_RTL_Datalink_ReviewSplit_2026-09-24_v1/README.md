# spw_datalink review split v1

## Purpose and source

This is a **source-organization candidate**, based on
`main@49fdf4032ac5d773189035bb7f10bad149995f21`. The original
`SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor/spw_datalink.sv`
is unchanged. The new `spw_datalink.sv` is the compile entry point; compile
with `-I SpaceWire_RTL_Datalink_ReviewSplit_2026-09-24_v1`.

| File | Lines | Responsibility |
|---|---:|---|
| `spw_datalink.sv` | 172 | Ports, state/shared-signal declarations, include order |
| `spw_datalink_link_fsm.svh` | 234 | Link FSM, timer, link state outputs |
| `spw_datalink_rx.svh` | 132 | RX ESC decode and Network RX holding register |
| `spw_datalink_credit.svh` | 132 | TX/RX credit and FCT gate |
| `spw_datalink_tx.svh` | 215 | Timecode, TX scheduler and commit semantics |
| `spw_datalink_error_checks.svh` | 118 | Recovery/error outputs and simulation checks |

Concatenating the entry file before the five `include` directives, the five
include files in order, and the closing `endmodule` reproduces the original
998 source lines exactly. There is no intended RTL behavior or timing change.
The module and internal signal names remain stable for current testbench and
GTKWave references.

## Baseline comparison

| Evidence | Original | This candidate |
|---|---:|---:|
| Directed tests | 8/8 PASS | 8/8 PASS |
| Story and GTKWave presets | PASS, 4/4 | PASS, 4/4 |
| 64-item burst data | 64/64 ordered | 64/64 ordered |
| Network accept span | 2,632 cycles | 2,632 cycles |
| Network accept gaps | 56 × 40, 7 × 56 cycles | 56 × 40, 7 × 56 cycles |
| Payload throughput | 19.15 Mbps | 19.15 Mbps |
| Verilator 5.038 `-Wall` warnings | 24 | 24 |

Run from repository root:

```bash
bash SpaceWire_RTL_Datalink_ReviewSplit_2026-09-24_v1/run_candidate_regression.sh
```

The script uses the original four other RTL files, original TB/story assets,
and `performance_baseline_2026-09-24/tb_spw_perf_burst.sv`. Generated VCDs,
VVP files, and compile logs are written under this candidate's ignored `build/`.

## Decision boundary

This improves review file size while retaining one SystemVerilog module and a
shared signal namespace. It does not reduce logic complexity, change Fmax, or
close the existing width/reset lint warnings. An actual submodule extraction
would require explicit interface and state ownership, migration of direct
testbench/GTKWave probes, and a new equivalence/performance gate. It should be
treated as a separate version and change, not inferred from this split.
