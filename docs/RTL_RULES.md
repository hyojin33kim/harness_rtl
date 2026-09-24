# SpaceWire RTL Rule Registry

- Status: Working baseline
- Rule baseline: `main@49ad5c2` (before this registry was added)
- Scope: `spw_network`, `spw_datalink`, `spw_enc`, `spw_phy`, `spw_top`, TB, observer, GTKWave presets, regression
- Normative protocol reference: ECSS-E-ST-50-12C Rev.1

This file is the single entry point for rules that affect RTL structure,
interfaces, verification, and debug artifacts. It distinguishes rules already
implemented from assumptions and proposals so that a new work session does not
silently turn a proposal into an implementation constraint.

## 1. Rule status and precedence

| Mark | Meaning |
|---|---|
| `MUST` | Implemented contract. A change requires RTL/TB/document updates in the same branch. |
| `SHOULD` | Current coding or review convention. Deviations require an explanatory comment. |
| `ASSUMPTION` | Required by the current candidate but not yet closed by independent evidence. |
| `PROPOSED` | Direction accepted or requested, but exact grammar/mapping is not frozen. |
| `TBD` | Evidence or a design decision is still missing. |

When sources disagree, use this order and record the conflict instead of
silently choosing one interpretation:

1. Applicable ECSS requirement and approved requirement interpretation
2. Approved architecture/decision record
3. This rule registry and boundary contracts
4. RTL implementation
5. Tests and waveforms as evidence, not as requirements

## 2. Architecture and ownership

| ID | Rule | Status |
|---|---|---|
| `ARCH-01` | Network owns host item validation, host/Encoding format conversion, and TX/RX FIFO storage. | MUST |
| `ARCH-02` | Data Link owns Link FSM, credit, protocol sequencing, N-Char scheduling, and transaction semantic kind. | MUST |
| `ARCH-03` | Encoder owns character serialization/deserialization and inter-character parity, but does not know FCT/Null/Broadcast protocol meaning. | MUST |
| `ARCH-04` | PHY owns D/S pad boundary, input synchronization, and disconnect transition timing. | MUST |
| `ARCH-05` | Format conversion is performed by the boundary owner; Host item, N-Char, Encoder character, and D/S bit representations are not interchangeable. | MUST |
| `ARCH-06` | A refactor must not rewrite unrelated protocol algorithms in the same change. | MUST |

## 3. Interface channel classes

| ID | Rule | Status |
|---|---|---|
| `IF-01` | A stallable transfer uses `data/valid/ready`; acceptance is `valid && ready`. | MUST |
| `IF-02` | `valid` must not be combinationally dependent on `ready`. | MUST |
| `IF-03` | While `valid && !ready`, `valid` and every associated payload/metadata field remain stable. | MUST |
| `IF-04` | A physically unstalled RX event uses event-valid plus event-data, not artificial `ready`. | MUST |
| `IF-05` | An accepted operation completes with exactly one `commit` or `abort`; ACCEPT is not COMMIT. | MUST |
| `IF-06` | `ready` means “sink can take ownership now”; it is not a synonym for FIFO pop or operation completion. | MUST |

Current boundary definitions:

| Boundary | Channel | Ownership/completion point |
|---|---|---|
| Network → Data Link | `net_tx_data/valid/ready` | Network FIFO → Data Link request at `valid && ready` |
| Data Link → Encoder | `enc_tx_char/valid/ready` | Data Link request → Encoder at `valid && ready` |
| Encoder → Data Link TX | `enc_tx_commit/abort` | Final D/S bit, or recovery termination |
| Encoder → Data Link RX | `enc_rx_char/valid`, parity/error events | Unstalled physical event |
| Data Link → Network | `net_rx_data/valid/ready` | Holding register → Network FIFO at `valid && ready` |

## 4. Transaction and protocol-event semantics

| ID | Rule | Status |
|---|---|---|
| `EVT-01` | Lifecycle is `SELECT → REQUEST → ACCEPT → COMMIT or ABORT`. | MUST |
| `EVT-02` | State/resource accounting is attached to the matching semantic event, never to ambiguous `send` or `valid` levels. | MUST |
| `EVT-03` | Data Link retains `r_tx_inflight_kind` after Encoder acceptance and combines it with Encoder commit/abort. | MUST |
| `EVT-04` | One accepted character cannot commit twice; a commit without an outstanding accepted character is illegal. | MUST |
| `EVT-05` | One-cycle events use an `_evt` suffix when the signal name would otherwise look like a level. | SHOULD |

## 5. Credit, buffering, and ordering

| ID | Rule | Status |
|---|---|---|
| `FLOW-01` | Received independent FCT increments TX credit by 8; committed N-Char decrements it by 1. | MUST |
| `FLOW-02` | Same-cycle FCT receive and N-Char commit is one atomic `+7` next-value update. | MUST |
| `FLOW-03` | Only a committed independent FCT grants RX credit. The FCT half of Null does not. | MUST |
| `FLOW-04` | Credit must not underflow or exceed `MAX_CREDIT=56`. | MUST |
| `FLOW-05` | Network TX FIFO pops if and only if its boundary transfer is accepted. | MUST |
| `FLOW-06` | Data Link RX holding data/control remains stable while Network is not ready. | MUST |
| `FLOW-07` | Silent drop is not a normal flow-control mechanism. A second physical event over a blocked one-entry holding register is an invariant failure. | MUST |
| `FLOW-08` | Correct credit and FIFO sizing are assumed to make `FLOW-07` unreachable in normal operation. | ASSUMPTION |

## 6. Atomic sequences, error precedence, and recovery

| ID | Rule | Status |
|---|---|---|
| `SEQ-01` | Null and Broadcast/Timecode ESC sequences are atomic; no unrelated request may interleave between ESC and its required second character. | MUST |
| `SEQ-02` | The second character is scheduled only after ESC commit, not ESC request or acceptance. | MUST |
| `ERR-01` | A same-cycle link/parity/protocol error wins over RX commit. | MUST |
| `ERR-02` | Recovery of an accepted incomplete TX character produces abort and no credit/protocol completion effect. | MUST |
| `ERR-03` | Entering ErrorReset fans one recovery event to Encoder and PHY so serializer/framing and disconnect session history restart together. | MUST |
| `ERR-04` | Repeated NULL (`ESC,FCT`) is legal and is not itself a parity error. | MUST |

## 7. Data and wire representation

| ID | Rule | Status |
|---|---|---|
| `FMT-01` | Host 9-bit EOP/EEP items and Encoding control-character codes use different encodings; conversion ownership must be explicit. | MUST |
| `FMT-02` | Encoder data/control payload bits are transmitted LSB first. | MUST |
| `FMT-03` | Inter-character parity is checked with the previous payload and the following character P/C fields; a standalone `9'h103` value cannot determine parity validity. | MUST |
| `FMT-04` | Control codes are FCT=`00`, EEP=`01`, EOP=`10`, ESC=`11`. | MUST |

## 8. Current naming and coding style

| ID | Rule | Status |
|---|---|---|
| `NAM-01` | Module input/output ports use `i_`/`o_`. | SHOULD |
| `NAM-02` | Sequential state normally uses `r_`; combinational/internal nets normally use `w_`. | SHOULD |
| `NAM-03` | `_valid/_ready` are levels; `_evt` is a one-cycle event; `_active/_busy/_pending` are states. | MUST |
| `NAM-04` | TX/RX direction is relative to the SpaceWire wire, not the local module port direction. | MUST |
| `NAM-05` | Top-level inter-module nets use channel/owner-oriented `w_net_*`, `w_enc_*`, and `w_phy_*`. | SHOULD |
| `CODE-01` | Sequential state is assigned with nonblocking assignments in `always_ff`; combinational logic uses `always_comb` or continuous assignment. | SHOULD |
| `CODE-02` | Simultaneous increments/decrements of one state variable are resolved in one next-value expression or one case statement. | MUST |
| `CODE-03` | Timer/count widths derive from parameters; ceiling arithmetic and minimum width prevent early timeout and zero-width vectors. | MUST |
| `CODE-04` | Invalid parameter ratios fail during simulation rather than silently rounding protocol timing. | MUST |
| `CODE-05` | In new or refactored module port lists, group declarations in this order: clock/reset, TX data I/F, TX control I/F, RX data I/F, RX control I/F, then link-wide control/status. Separate groups with a blank line; omit empty TX/RX groups. TX/RX follow `NAM-04`. Reordering must not change port names, directions, widths, or connections. | MUST for new/refactored RTL |
| `CODE-06` | If one FF has both asynchronous hardware reset and synchronous reset/flush, keep one driver: put the async reset in the outer `if (!i_rst_n)` branch of `always_ff @(posedge i_clk or negedge i_rst_n)`, and put synchronous control inside its clocked `else` branch, ahead of normal updates. Do not split one register across FF blocks or change reset priority as part of formatting. | MUST for new/refactored RTL |

Known deviations: some stored outputs still use names such as `or_*`; the Link
FSM uses localparams rather than a typed enum; an `n_*` next-state convention is
not consistently present. Therefore strict `r_/w_/n_` conformance is not yet a
baseline claim.

## 9. Reset, clock, and CDC rules in the current candidate

| ID | Rule | Status |
|---|---|---|
| `RST-01` | `i_rst_n` is the current global active-low asynchronous hardware reset. | MUST |
| `RST-02` | `i_port_reset` synchronously resets Data Link protocol state only; Network FIFO contents are preserved. | MUST |
| `RST-03` | `i_link_recovery_evt` is a one-cycle protocol/session recovery event, not a replacement for hardware reset. | MUST |
| `CDC-01` | External RX D/S inputs pass through marked two-flop synchronizers before system-clock logic uses them. | MUST for current candidate |
| `CDC-02` | The two-flop system-clock sampling architecture is not accepted as high-speed SpaceWire closure evidence. | ASSUMPTION / risk |
| `CLK-01` | Current regression defaults are 100 MHz system clock and 10 Mbps link rate; Encoder requires an integer clocks-per-bit ratio. | MUST for current tests |

The requested reset hierarchy cleanup—separating hardware asynchronous reset
from locally derived synchronous protocol resets—is `PROPOSED`. A register-by-
register reset-domain matrix must be approved before RTL modification.
This is distinct from `CODE-06`, which only makes the existing async/sync
branches visually explicit; it does not reclassify a register, add/remove a
reset, or change the reset domain. The v5 Data Link candidate records its
unchanged reset ownership in `SpaceWire_RTL_Datalink_InterfaceResetStyle_2026-09-24_v5/RESET_MATRIX.md`.

## 10. Verification and evidence gates

| ID | Rule | Status |
|---|---|---|
| `VER-01` | Before a functional refactor, preserve baseline behavior with a passing regression. | MUST |
| `VER-02` | Each semantic step must pass the complete enabled regression before the next step. | MUST |
| `VER-03` | Boundary invariants P1–P12 and directed scenarios are retained or explicitly replaced with stronger evidence. | MUST |
| `VER-04` | Regression success requires zero exit status and every required VCD to exist and be non-empty. | MUST |
| `VER-05` | Every signal referenced by a committed GTKWave preset must exist in the generated story VCD. | MUST |
| `VER-06` | A directed test or two identical RTL endpoints is integration evidence, not an independent protocol oracle. | MUST |
| `VER-07` | Local simulation PASS must not be described as ECSS compliance, CDC/timing closure, synthesis closure, or FPGA proof. | MUST |
| `VER-08` | Current reproducible simulator baseline is Icarus Verilog 12.x. | MUST for CI reproducibility |

## 11. Waveform and debug artifacts

| ID | Rule | Status |
|---|---|---|
| `DBG-01` | `spw_wave_observer.sv` is TB-only and must not drive the DUT. | MUST |
| `DBG-02` | Observer signals provide a stable semantic debug boundary; GTKWave presets should prefer them over fragile deep hierarchy paths. | SHOULD |
| `DBG-03` | User-edited GTKWave presets committed on remote `main` are authoritative; generated older presets must not overwrite them. | MUST |
| `DBG-04` | `build/`, VCD, VVP, and logs are reproducible artifacts and remain untracked. | MUST |

Requested but not yet implemented waveform rules:

- independent TX/RX payloads (`TX: F8,72`, `RX: 4E,1F`) using a dual-endpoint story;
- observer display in logical wire order `P,C,D0...D7` without changing the serializer;
- virtual TX/RX clocks derived from `Data XOR Strobe`;
- packed-ASCII Link-state display;
- hexadecimal buses and decimal numeric Link-state radix.

These are `PROPOSED` until the migrated presets and regression pass together.

## 12. Git and change-control rules

| ID | Rule | Status |
|---|---|---|
| `CFG-01` | Remote `main` is the engineering baseline; work starts from an up-to-date clone, not from the scratch export. | MUST |
| `CFG-02` | RTL, TB, observer, GTKWave presets, scripts, and rule changes that form one contract change are committed together. | MUST |
| `CFG-03` | Naming-only and reset-functional changes are separate commits/gates. | MUST |
| `CFG-04` | A rule-changing commit updates this registry and the affected tests before or with RTL. | MUST |

## 13. Accepted intent but unresolved implementation grammar

The following directions have been requested, but must not be applied by bulk
rename or reset edits until their mapping tables are reviewed:

1. Source-owner-visible port naming, for example Data Link-generated ready as
   `o_dll_tx_nchar_ready` at Data Link and `i_dll_tx_nchar_ready` at Network.
2. Layer-specific object vocabulary: Network `item`, Data Link `nchar`, Encoder
   `char`, PHY `ds/bit`, while preserving one name for one physical boundary.
3. Strict internal naming: FF=`r_`, combinational=`w_`, next-value=`n_`.
4. Reset classification: hardware async reset, locally derived synchronous
   protocol reset, recovery event, and deliberate no-reset datapath state.

The next implementation session must first produce an old→new port map and a
register reset-domain matrix. Compile/regression must remain green after the
naming-only gate before reset behavior is changed.
