# v3 boundary map — RX ESC and character decode

Source: `main@49fdf403` and v2 RX holding candidate. This gate extracts only
RX character classification, ESC pending state, and timecode decode. It does
not change Link FSM, credit, TX, reset hierarchy, or external DataLink ports.

| Existing parent signal | New owner / port | Consumer |
|---|---|---|
| `i_enc_rx_char/valid` | RX decoder `i_char/i_valid` | Decode and ESC state |
| `r_state` | RX decoder `i_link_state` | State-dependent violation rules |
| `w_entering_error_reset` | RX decoder `i_flush_evt` | Clear pending ESC at original edge |
| `w_got_null/fct/nchar/timecode` | RX decoder outputs, same parent net names | Link FSM, credit, TX/RX holding, timecode |
| `w_esc_error`, `w_protocol_violation` | RX decoder outputs, same parent net names | Immediate-error decision |
| `w_is_ctrl` | RX decoder output, same parent net name | RX holding metadata |
| `r_rx_pending_esc` | RX decoder `o_pending_esc` → parent `w_rx_pending_esc` | Candidate story observer |
| `o_rx_timecode_commit_evt/data` | RX decoder outputs → unchanged parent ports | Network timecode path |

The only moved state register is `r_rx_pending_esc` (now decoder
`o_pending_esc`). Its hardware reset remains active-low asynchronous to zero;
`i_flush_evt` clears it synchronously, and valid RX characters set/clear it on
the same edge as v2. No register is added. `i_link_state` retains the current
0–5 state encoding; the decoder uses the same state comparisons as v2.

Debug migration: the candidate's copy of `tb_spw_story.sv` connects the
observer to the parent `w_rx_pending_esc` wire driven by `u_rx_decode`. The candidate's copy of
`error_recovery.gtkw` uses `tb_spw_story.u_obs.i_rx_pending_esc`, which is the
existing semantic observer input. All original user-edited GTKWave presets
remain untouched. The other three presets are reused directly.

Gate: eight existing directed tests, v2 RX hold contract, a new RX decoder
contract test, story, four GTKWave checks, and the 64-item burst. Compare
cycle metrics and lint categories with the original baseline.
