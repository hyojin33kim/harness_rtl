    // RX character semantics now own ESC context and same-cycle event decode.
    logic w_is_ctrl;
    spw_datalink_rx_decode u_rx_decode (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_flush_evt(w_entering_error_reset),
        .i_link_state(r_state),
        .i_char(i_enc_rx_char), .i_valid(i_enc_rx_valid),
        .o_is_ctrl(w_is_ctrl), .o_pending_esc(w_rx_pending_esc),
        .o_got_null(w_got_null), .o_got_fct(w_got_fct),
        .o_got_nchar(w_got_nchar), .o_got_timecode(w_got_timecode),
        .o_esc_error(w_esc_error),
        .o_protocol_violation(w_protocol_violation),
        .o_timecode_data(o_rx_timecode_data)
    );
    assign o_rx_timecode_commit_evt = w_got_timecode;

    // One-entry physical-event buffer owns held delivery and P11 checks.
    spw_datalink_rx_hold u_rx_hold (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_flush_evt(w_entering_error_reset),
        .i_error_now(w_immediate_error),
        .i_nchar_evt(w_got_nchar),
        .i_char(i_enc_rx_char), .i_is_ctrl(w_is_ctrl),
        .i_net_ready(i_net_rx_ready),
        .o_valid(w_net_rx_hold_valid),
        .o_data(o_net_rx_data), .o_is_ctrl(o_net_rx_is_ctrl)
    );
    assign o_net_rx_valid = w_net_rx_hold_valid;
