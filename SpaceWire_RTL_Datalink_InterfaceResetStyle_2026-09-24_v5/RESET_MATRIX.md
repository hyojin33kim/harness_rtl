# v5 reset-domain matrix (style-only)

This matrix records v4 behavior; it does not approve or implement a reset
architecture change. In every hardware state FF, `negedge i_rst_n` is the
asynchronous reset branch. All protocol reset/flush decisions remain inside
the `posedge i_clk` branch. The same register is never driven from two FF
blocks. Priority and reset values are identical to v4.

| Owner / register(s) | Async hardware reset | Clocked reset/clear or update priority |
|---|---|---|
| Link FSM `r_state` | ErrorReset | `w_next_state` captures port reset and error decisions |
| Link FSM `r_timer_cnt`, `r_timer_expired` | 0 | `w_timer_sync_rst` before counting/expiry |
| Link FSM `r_sent_null` | 0 | ErrorReset/Connecting clear before Null commit |
| Link FSM `r_got_fct`, `r_sent_fct` | 0 | State-transition/Connecting clear before FCT event |
| Link FSM `r_null_seen` | 0 | ErrorReset clear before gotNull |
| Credit `r_tx_credit`, `r_rx_credit` | 0 | `i_credit_sync_rst` before credit events |
| Credit `r_req_initial_fct` | 0 | Connecting-entry load before independent FCT decrement; no separate protocol reset |
| RX decode `o_pending_esc` | 0 | `i_flush_evt` before RX character update |
| RX hold `o_valid/o_data/o_is_ctrl` | 0 | `i_flush_evt` before capture/accept |
| TX `r_tc_pending/r_tc_value`, `r_bc_value` | 0 | ErrorReset-entry clear before request/accept |
| TX `r_tx_req_valid/char/kind` | 0/`TXK_NONE` | ErrorReset-entry or TX-disable clear before request events |
| TX `r_tx_inflight_kind`, `r_esc_pending/kind` | 0/`TXK_NONE` | ErrorReset-entry clear before accept/commit events |
| Simulation-only assertion history | 0 | Existing checks/history update; no functional RTL state |

The port order is: clock/reset; TX data; TX control; RX data; RX control;
link-wide control/status. RX-only child modules omit empty TX groups. Ports
retain their exact names, directions, widths and connection semantics.
