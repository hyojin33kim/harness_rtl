# v4 boundary map — credit/FCT controller

Baseline: `main@49fdf403` and v3 RX decoder candidate. This gate only
extracts credit accounting and FCT eligibility. The parent still owns Link FSM,
TX scheduling/serialization, independent-vs-Null FCT commit classification,
RX decode, error priority, and external DataLink ports.

| Parent source or consumer | Child contract | Ownership |
|---|---|---|
| `r_state`, `w_entering_connecting` | `i_link_state`, `i_entering_connecting` | Parent decides state and transition timing |
| `w_got_fct`, `w_got_nchar` | `i_got_fct`, `i_got_nchar` | RX decoder emits same-cycle character events |
| `w_tx_nchar_commit_evt`, `w_tx_fct_commit_evt` | matching child inputs | Parent owns wire-completion events; Null FCT-half is excluded |
| `w_next_state == ST_ERROR_RESET` | `i_credit_sync_rst` | Parent owns recovery decision; child clears both credit registers at the original edge |
| `i_rx_fifo_free_count`, `w_net_rx_hold_valid` | matching child inputs | Raw free count and one-entry RX reserve remain external facts |
| Parent `w_tx_credit`, `w_rx_credit`, `w_req_initial_fct` | child registered outputs | Child exclusively owns the three registers |
| Parent `w_credit_err`, `w_fct_send_ok` | child combinational outputs | Error priority and TX request selection remain in parent |

Reset: both credit registers use active-low asynchronous reset and synchronous
ErrorReset clear. Initial-FCT countdown uses only asynchronous reset, then
Connecting-entry load and independent-FCT commit decrement, exactly as v3.
There is no new pipeline register or latency. The child compares state using
the unchanged 0–5 encoding.

Debug migration: three candidate-only directed TB copies force
`u_credit.r_tx_credit/r_rx_credit/r_req_initial_fct`. The candidate story
observer reads parent read-only credit outputs; two candidate-only GTKWave
presets follow the child register hierarchy. The original TBs and presets
are unchanged.

Verification gate: eight original directed scenarios, three focused child
contracts, integrated story, four GTKWave signal checks, 64-item loopback,
cycle metrics, and Verilator `-Wall`. This is cycle-regression evidence,
not independent formal equivalence or target PPA.
