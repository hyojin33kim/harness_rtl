# SpaceWire RTL Gate 2 Review

Date: 2026-09-20  
Baseline: `project_sources/02-06-spw_*.sv`  
Normative reference: ECSS-E-ST-50-12C Rev.1

## Decision

**Gate 2 = HOLD (simulation evidence pending).**

The reviewed RTL closes the identified source-level P0 defects, but this runtime
does not contain Icarus Verilog, Verilator, or another SystemVerilog simulator.
The supplied regression and GitHub Actions workflow have therefore not yet
produced an executable PASS result. Do not replace the approved baseline until
the workflow passes and FPGA-specific CDC/timing review is complete.

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
- `.github/workflows/spw-rtl.yml`: installs Icarus Verilog and runs the regression.

Checks completed locally:

- Shell syntax check for `run_regression.sh`: PASS.
- Balanced SystemVerilog `begin/end` and parentheses: PASS.
- Manual named-port/wiring review across all five modules: PASS.
- Simulator compile and directed tests: **NOT RUN (simulator unavailable)**.

## Required closure before baseline replacement

1. Run the GitHub Actions job and retain its PASS log.
2. Add/execute directed tests for simultaneous credit increment/decrement,
   parity corruption, disconnect threshold, ErrorReset recovery, and FIFO wrap.
3. Run lint with the target synthesis tool and review every width/CDC warning.
4. On target FPGA, prove the D/S input capture architecture at the intended link
   rate. A two-flop system-clock sampler is not sufficient when the SpaceWire bit
   rate approaches or exceeds the sampling-clock capability.
5. Only after items 1-4 pass, approve replacement of the original Library RTL.

## File status

These files are a separate review candidate. The original RTL remains unchanged.
