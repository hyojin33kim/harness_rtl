# SpaceWire Protocol Interface Refactor Report

Date: 2026-09-23  
Baseline: `work/rtl_reviewed_v2`  
Candidate: `work/rtl_protocol_refactor`  
Simulator: Icarus Verilog 12.0

## Result

The seven requested RTL refactor steps and the waveform-observer migration are
complete. `spw_top` compiles, all eight directed tests plus the integrated story
test pass, and all nine VCD files are generated and non-empty.

This result proves the local interface/event contracts covered below. It is not
SpaceWire compliance certification and does not close FPGA CDC, timing, or
physical-link recovery.

## Final interface and event definitions

| Boundary | Interface | Meaning |
|---|---|---|
| Network → DataLink | `net_tx_data`, `net_tx_valid`, `net_tx_ready` | Stallable transaction; Network FIFO ownership moves on `NET_TX_ACCEPT` |
| DataLink → Encoder | `enc_tx_char`, `enc_tx_valid`, `enc_tx_ready` | Registered character request; DataLink ownership moves on `ENC_TX_ACCEPT` |
| Encoder → DataLink | `enc_tx_commit`, `enc_tx_abort` | Exactly one normal or recovery completion for an accepted character |
| Encoder → DataLink RX | `enc_rx_char`, `enc_rx_valid`, `enc_parity_error` | Unstalled event channel; physical RX is not backpressured |
| DataLink → Network | `net_rx_data`, `net_rx_valid`, `net_rx_ready` | Stallable transaction backed by a one-entry DataLink holding register |
| Control | `tx_enable`, `rx_enable`, `link_recovery` | Control plane, separate from character ownership/completion |

Definitions:

- `NET_TX_ACCEPT = net_tx_valid && net_tx_ready`
- `ENC_TX_ACCEPT = enc_tx_valid && enc_tx_ready`
- `ENC_TX_COMMIT`: accepted character's final serialized bit reaches the D/S
  output boundary.
- `ENC_TX_ABORT`: an accepted but incomplete character is terminated by link
  recovery or TX disable.
- `NET_RX_ACCEPT = net_rx_valid && net_rx_ready`

## Ownership

| Object | Before event | Event | After event |
|---|---|---|---|
| Host TX N-Char | Network TX FIFO | `NET_TX_ACCEPT` | DataLink request register |
| Encoded character request | DataLink `r_tx_req_*` | `ENC_TX_ACCEPT` | Encoder serializer plus DataLink `r_tx_inflight_kind` metadata |
| Serialized character | Encoder active TX | `ENC_TX_COMMIT` | Protocol completion accounted by DataLink |
| Aborted character | Encoder active TX | `ENC_TX_ABORT` | No protocol completion or credit effect |
| Received N-Char | DataLink RX holding register | `NET_RX_ACCEPT` | Network RX FIFO |

## Step record

### Step 1 — Network TX valid/ready

1. Changed: `spw_network.sv`, `spw_datalink.sv`, `spw_top.sv`, related TBs.
2. Interface: removed TX pop/accept pulse; added `net_tx_data/valid/ready`.
3. Before/after: FIFO pop at a downstream send indication → FIFO pop only at
   `valid && ready`, when DataLink captures its own stable copy.
4. Test: `tb_spw_network_tx_handshake`.
5. Regression at step: 5/5 PASS, 5/5 VCD.
6. Remaining at step: Encoder completion and RX boundary were not yet changed.

### Step 2 — Registered Encoder request

1. Changed: `spw_datalink.sv`, `spw_top.sv`, related TBs.
2. Interface: `enc_tx_char/valid/ready`; request state is
   `r_tx_req_valid/char/kind`.
3. Before/after: scheduler/send terminology mixed selection and acceptance →
   scheduler creates a held request independently of `ready`.
4. Test: existing DataLink backpressure test retained and adapted.
5. Regression at step: all then-enabled tests PASS with VCD.
6. Remaining at step: commit/abort lifecycle.

### Step 3 — Encoder commit/abort

1. Changed: `spw_enc.sv`, `spw_datalink.sv`, `spw_top.sv`, related TBs.
2. Interface: added `enc_tx_commit` and `enc_tx_abort` completion events.
3. Before/after: acceptance could be mistaken for completion → final D/S bit
   produces one commit; recovery of an active character produces one abort.
4. Test: `tb_spw_enc_lifecycle` covers Control, Data, and mid-character abort.
5. Regression at step: 6/6 PASS, 6/6 VCD.
6. Remaining at step: DataLink protocol registers still needed commit semantics.

### Step 4 — Commit-based protocol state

1. Changed: `spw_datalink.sv`, DataLink contract/P0/semantic TBs.
2. Interface: no new boundary; added internal semantic events for N-Char, FCT,
   Null ESC/FCT, and Broadcast ESC/Data commits.
3. Before/after: credit and ESC sequencing changed at Encoder accept → changed
   only at matching semantic commit. Simultaneous RX FCT + TX N-Char commit is
   one atomic `+7` update.
4. Tests: `tb_spw_datalink_p0`, `tb_spw_datalink_contract`,
   `tb_spw_datalink_semantics`.
5. Regression at step: all enabled tests PASS with VCD.
6. Remaining at step: Network RX backpressure.

### Step 5 — Network RX valid/ready

1. Changed: `spw_datalink.sv`, `spw_network.sv`, `spw_top.sv`, related TBs.
2. Interface: `net_rx_data/valid/ready/is_ctrl` plus one-entry holding register.
3. Before/after: full FIFO could silently drop a pulse → transaction remains
   stable until accepted; a second unstalled physical event while blocked is an
   explicit invariant error.
4. Test: `tb_spw_net_rx_handshake` verifies full FIFO, stall stability,
   full+pop acceptance, and ordering.
5. Regression at step: 7/7 PASS, 7/7 VCD.
6. Remaining at step: one-entry overflow remains an abnormal protocol/integration
   failure, not flow-control behavior.

### Step 6 — Top naming

1. Changed: `spw_top.sv`, Encoder/DataLink RX port names, related TBs.
2. Interface: top wires use `w_net_*`, `w_enc_*`, and `w_phy_*`; Encoder RX uses
   `enc_rx_char/valid` event terminology.
3. Before/after: generic `rx_char_*`/`tx_char_*` wires → source/destination and
   transaction meaning visible in each name.
4. Test: full suite and top compile.
5. Regression at step: 7/7 PASS, 7/7 VCD.
6. Remaining at step: external top-level legacy error port names retained to
   avoid unrelated API change.

### Step 7 — Assertions and scenario closure

1. Changed: `spw_datalink.sv`, `spw_enc.sv`, `spw_network.sv`,
   `tb_spw_datalink_semantics.sv`, `run_regression.sh`.
2. Interface: unchanged.
3. Before/after: directed checks only → local lifecycle/stability/credit/ESC
   assertions plus directed scenario evidence.
4. Test: added semantic credit and Connecting test; enabled local assertions.
5. Final regression: 8/8 PASS, 8/8 non-empty VCD, top compile PASS.
6. Remaining risks are listed below.

### Step 8 — Observer and GTKWave migration

1. Changed: `story_waveforms/spw_wave_observer.sv`, `tb_spw_story.sv`, four
   `.gtkw` presets, `check_gtkw_signals.py`, and both regression scripts.
2. Interface: TB-only semantic observer under `tb_spw_story.u_obs`; synthesizable
   RTL interface is unchanged.
3. Before/after: observer logic was embedded in the story TB and presets used
   removed legacy top signal names → one observer instance owns DUT hierarchy
   adaptation and presets use the refactored `w_net_*`/`w_enc_*` boundaries.
4. Test: `tb_spw_story` link initialize, flow control, parity-error recovery,
   and reconnect narrative.
5. Signal-view check: all signals in `overview.gtkw`, `link_initialize.gtkw`,
   `flow_control.gtkw`, and `error_recovery.gtkw` must exist in the new VCD.
6. Final integrated regression: 9/9 PASS, 9/9 non-empty VCD, top compile PASS.

## Requirement/event evidence

| Requirement/Event | Interface signal | RTL state/register | Test/assertion | Result |
|---|---|---|---|---|
| P1 stalled TX stable | `net_tx_*`, `enc_tx_*` | Network FIFO head, `r_tx_req_*` | Network TX TB; DataLink/Network local stability checks | PASS |
| P2 accept completes | `enc_tx_valid/ready`, `commit/abort` | Encoder `r_tx_active`, assertion outstanding bit | Encoder lifecycle TB | PASS |
| P3 no orphan commit | `enc_tx_commit` | DataLink `r_tx_inflight_kind`; Encoder outstanding bit | Local assertions; lifecycle TB | PASS |
| P4 max one commit | `enc_tx_commit/abort` | Encoder outstanding bit | Local assertion; lifecycle counts | PASS |
| P5 N-Char commit −1 | `enc_tx_commit` + `TXK_NCHAR` | `r_tx_credit` | DataLink semantics TB | PASS |
| P6 accept alone no −1 | `enc_tx_valid && ready` | `r_tx_credit` | P0 and semantics TBs | PASS |
| P7 independent FCT +8 | `enc_tx_commit` + `TXK_FCT` | `r_rx_credit` | DataLink semantics TB | PASS |
| P8 Null FCT no +8 | `enc_tx_commit` + `TXK_NULL_FCT` | `r_rx_credit` | DataLink semantics TB | PASS |
| P9 simultaneous net +7 | RX FCT event + N-Char commit | atomic TX-credit case | DataLink P0 TB | PASS |
| P10 FIFO pop iff accept | `net_tx_valid && ready` | `r_tx_rptr`, `r_tx_count` | Network TX TB | PASS |
| P11 stalled RX stable | `net_rx_valid && !ready` | `r_net_rx_*` | Network RX TB; local assertion | PASS |
| P12 no ESC interleave | semantic ESC/FCT or BC/Data commits | `r_esc_pending`, `r_esc_kind`, `r_tx_req_kind` | DataLink contract/semantics TBs; local assertion | PASS |
| Connecting uses SentFCT | peer FCT event + local `TX_FCT_COMMIT` | `r_got_fct`, `r_sent_fct`, `r_state` | DataLink semantics TB | PASS |

## Regression scenario coverage

| Scenario | Evidence | Result |
|---|---|---|
| Encoder backpressure | `tb_spw_datalink_contract` | PASS |
| TX accept vs commit | `tb_spw_datalink_semantics` | PASS |
| N-Char + RX FCT simultaneous | `tb_spw_datalink_p0` | PASS |
| Independent FCT vs Null FCT | `tb_spw_datalink_semantics` | PASS |
| ErrorReset mid-character | `tb_spw_enc_lifecycle` | PASS |
| Network TX FIFO handshake | `tb_spw_network_tx_handshake` | PASS |
| Network RX backpressure | `tb_spw_net_rx_handshake` | PASS |
| ESC/Null atomicity | DataLink contract and semantics TBs | PASS |
| Connecting commit gate | `tb_spw_datalink_semantics` | PASS |
| Link/flow/error/reconnect story | `tb_spw_story`; four GTKWave signal checks | PASS |

## Remaining risks / TBD

- Per the refactor scope, cross-character parity redesign, moving gotNull into
  Encoder, further controlled D/S reset work, and high-speed RX bit recovery
  architecture were not changed.
- The one-entry Network RX holding register detects but cannot absorb a second
  physical character during prolonged Network backpressure. Correct credit and
  FIFO sizing must make this unreachable in normal operation.
- No independent golden model or legacy TB exists; results are directed contract
  evidence, not independent protocol equivalence.
- Target synthesis/lint, CDC/RDC analysis, timing closure, FPGA hardware tests,
  fault injection, and ECSS compliance traceability remain open.
- Icarus reports non-fatal limitations for `unique` case handling and constant
  selects in `always_comb`; a production lint/simulator run is still required.
- This workspace is not a Git checkout, so no commit or remote CI run was made.
