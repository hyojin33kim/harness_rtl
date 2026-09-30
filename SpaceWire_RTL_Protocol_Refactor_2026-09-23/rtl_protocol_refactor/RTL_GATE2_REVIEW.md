# SpaceWire RTL Gate 2 Review

> Historical baseline note: this document was copied from `rtl_reviewed_v2`.
> The current protocol-interface refactor result, eight-test regression status,
> P1–P12 mapping, and remaining risks are authoritative in
> `PROTOCOL_REFACTOR_REPORT.md`.

Date: 2026-09-20  
Baseline: `project_sources/02-06-spw_*.sv`  
Normative reference: ECSS-E-ST-50-12C Rev.1

## Decision

**Gate 2 = HOLD (P0 contract regression passed; physical/recovery closure pending).**

The reviewed RTL closes the identified source-level P0 defects, and its local
Icarus Verilog 12.0 contract regression now passes. Gate 2 remains on hold until
the physical fault/recovery cases, FIFO boundaries, and FPGA-specific CDC/timing
review are complete.

## Implemented changes

| Area | Result |
|---|---|
| Naming | Module boundaries use `i_`/`o_`; payloads use `_data`/`_item`; one-cycle events use `_evt`; level handshake uses `_valid`/`_ready`. |
| TX interface | One-entry source buffer holds `valid` and `data` stable until `valid && ready`. |
| Accept vs commit | Encoder exposes `o_tx_char_commit_evt`; `SentNull` and `SentFCT` use serialization completion, not acceptance. |
| Parity | Implements ECSS inter-character parity: current P/flag protects the previous payload. |
| RX delivery | A decoded character is held until the following P/flag validates it. |
| First Null | Bit-stream acquisition searches the exact first-Null sequence `0,1,1,1,0,1,0,0` before establishing character framing. |
| D/S reset | Strobe resets first; Data follows one configured bit period later. |
| Bit timing | Character boundaries retain a full configured bit period; invalid rate ratios fail in simulation. |
| Flow control | Simultaneous FCT receive and N-Char send is one `+7` update; FCT reserve includes already-granted RX credit. |
| Error/commit | Immediate Link errors suppress same-cycle Network RX commit. |
| Timer sizing | Link timers derive width from parameters; PHY timeout uses 64-bit ceiling arithmetic. |
| Host controls | Host EOP/EEP are canonicalized to Encoding control codes at the Network boundary. |
| CDC metadata | `ASYNC_REG` is attached to the actual two synchronizer stages. |

## Verification assets

- `run_regression.sh`: top-level compile plus directed tests.
- `tb/tb_spw_enc_contract.sv`: Null acquisition, inter-character parity loopback,
  delayed RX commit, and TX commit events.
- `tb/tb_spw_datalink_contract.sv`: held-valid/data behavior and atomic Null ESC/FCT.
- `tb/tb_spw_datalink_p0.sv`: simultaneous credit +8/-1, error-over-commit,
  and FCT reserve-boundary checks.
- `tb/tb_spw_enc_bit_timing.sv`: continuous bit-period check across character
  boundaries.
- `.github/workflows/spw-rtl.yml`: installs Icarus Verilog and runs the regression.

Checks completed in this Work runtime with Icarus Verilog 12.0:

- Shell syntax check for `run_regression.sh`: PASS.
- Balanced SystemVerilog `begin/end` and parentheses: PASS.
- Manual named-port/wiring review across all five modules: PASS.
- Five-module `spw_top` compile: PASS.
- `tb_spw_enc_contract`: PASS, non-empty VCD generated.
- `tb_spw_datalink_contract`: PASS, non-empty VCD generated.
- `tb_spw_datalink_p0`: PASS; credit +8/-1, error-over-commit, and FCT
  reserve-boundary checks passed; non-empty VCD generated.
- `tb_spw_enc_bit_timing`: PASS; character-boundary bit spacing passed;
  non-empty VCD generated.
- Full regression exit status: 0.

## Required closure before baseline replacement

1. Run the same regression in GitHub Actions and retain its PASS log.
2. Add physical parity corruption, disconnect threshold, ErrorReset recovery,
   and FIFO-wrap tests.
3. Run lint with the target synthesis tool and review every width/CDC warning.
4. On target FPGA, prove the D/S input capture architecture at the intended link
   rate. A two-flop system-clock sampler is not sufficient when the SpaceWire bit
   rate approaches or exceeds the sampling-clock capability.
5. Only after items 1-4 pass, approve replacement of the original Library RTL.

## File status

These files are a separate review candidate. The original RTL remains unchanged.
