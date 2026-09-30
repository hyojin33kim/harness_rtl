# v2 boundary map — Network RX holding extraction

Source baseline: `main@49fdf403` and the review-only v1 split. Scope is only
the one-entry Network RX holding register and its local checks. No port rename,
reset change, added pipeline stage, or protocol algorithm change is intended.

| Existing DataLink expression | v2 owner / connection | Meaning |
|---|---|---|
| `w_got_nchar` | parent → `i_nchar_evt` | Decoded physical N-Char event |
| `w_immediate_error` | parent → `i_error_now` | Same-cycle error suppresses capture |
| `w_entering_error_reset` | parent → `i_flush_evt` | Synchronous holding-register clear |
| `i_enc_rx_char`, `w_is_ctrl` | parent → `i_char`, `i_is_ctrl` | Event payload and metadata |
| `i_net_rx_ready` | parent → `i_net_ready` | Network ownership acceptance |
| `r_net_rx_valid` | child `o_valid` → parent `w_net_rx_hold_valid` | Credit reserve calculation |
| `o_net_rx_data/valid/is_ctrl` | child → parent unchanged ports | Held Network transaction |
| `w_net_rx_source/accept/overflow_evt` | child-local combinational signals | Buffer lifecycle and invariant |
| `a_net_rx_stalled/data/ctrl` | child-local simulation check state | P11 stall stability |

Reset-domain matrix for the extracted state:

| Register | Hardware reset | Protocol flush | Other update |
|---|---|---|---|
| `o_valid` (was `r_net_rx_valid`) | `!i_rst_n` async → 0 | `i_flush_evt` → 0 | capture → 1; accepted without replacement → 0 |
| `o_data` (was `r_net_rx_data`) | `!i_rst_n` async → 0 | `i_flush_evt` → 0 | successful capture → event character |
| `o_is_ctrl` (was `r_net_rx_is_ctrl`) | `!i_rst_n` async → 0 | `i_flush_evt` → 0 | successful capture → event control flag |
| `a_net_rx_stalled/data/ctrl` | `!i_rst_n` async → 0 | no independent flush | original P11 sampled-state behavior retained |

`i_port_reset` is not connected directly to the child. The parent generates
`w_entering_error_reset` according to its existing FSM logic, preserving the
original flush timing and `RST-02` scope. `r_rx_pending_esc`, credit counters,
TX state, Link FSM, and timer remain in the parent. Existing directed TBs and
GTKWave presets do not address `r_net_rx_*` by deep hierarchy; the parent
retains the `w_net_rx_hold_valid` wire needed by the FCT reserve calculation.

Acceptance gate: all eight directed tests, story, four GTKWave preset checks,
and the 64-item burst must pass. RUN timing, event counts, and Network accept
gap distribution must match `performance_baseline_2026-09-24`.
