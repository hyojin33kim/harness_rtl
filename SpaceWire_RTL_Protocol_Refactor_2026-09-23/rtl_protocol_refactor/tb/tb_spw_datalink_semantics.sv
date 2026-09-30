`timescale 1ns/1ps

module tb_spw_datalink_semantics;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [8:0] enc_rx_char = '0;
    logic enc_rx_valid = 0;
    logic enc_tx_ready = 0;
    logic enc_tx_commit = 0;
    logic [8:0] enc_tx_char;
    logic enc_tx_valid;
    logic [8:0] net_tx_data = 9'h055;
    logic net_tx_valid = 0;
    logic net_tx_ready;
    logic [7:0] rx_fifo_free_count = 0;
    logic [2:0] link_state;

    spw_datalink #(
        .RX_FIFO_DEPTH(128), .MAX_CREDIT(56), .CNT_6US(2), .CNT_12US(64)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(1'b1), .i_link_start(1'b0), .i_auto_start(1'b0),
        .i_port_reset(1'b0),
        .i_enc_rx_char(enc_rx_char), .i_enc_rx_valid(enc_rx_valid),
        .i_enc_parity_error(1'b0), .i_disconnect_err_evt(1'b0),
        .o_tx_enable(), .o_rx_enable(), .o_rx_parity_enable(),
        .o_enc_tx_char(enc_tx_char), .o_enc_tx_valid(enc_tx_valid),
        .i_enc_tx_ready(enc_tx_ready), .i_enc_tx_commit(enc_tx_commit),
        .i_enc_tx_abort(1'b0), .o_link_recovery_evt(),
        .i_net_tx_data(net_tx_data), .i_net_tx_valid(net_tx_valid),
        .o_net_tx_ready(net_tx_ready),
        .o_net_rx_data(), .o_net_rx_valid(), .i_net_rx_ready(1'b1),
        .o_net_rx_is_ctrl(), .i_rx_fifo_free_count(rx_fifo_free_count),
        .i_tx_timecode_req_evt(1'b0), .i_tx_timecode_data('0),
        .o_rx_timecode_commit_evt(), .o_rx_timecode_data(),
        .o_link_state(link_state), .o_disconnect_err_evt(),
        .o_parity_err_evt(), .o_esc_err_evt(), .o_credit_err_evt()
    );

    task automatic reset_dut;
        begin
            enc_rx_valid = 0;
            enc_tx_ready = 0;
            enc_tx_commit = 0;
            net_tx_valid = 0;
            rx_fifo_free_count = 0;
            rst_n = 0;
            repeat (2) @(posedge clk);
            @(negedge clk); rst_n = 1;
            @(posedge clk);
        end
    endtask

    task enter_run(input logic [5:0] tx_credit,
                   input logic [5:0] rx_credit);
        begin
            force dut.r_state = 3'd5;
            force dut.r_tx_credit = tx_credit;
            force dut.r_rx_credit = rx_credit;
            @(negedge clk);
            release dut.r_state;
            release dut.r_tx_credit;
            release dut.r_rx_credit;
        end
    endtask

    task automatic accept_request;
        begin
            wait (enc_tx_valid);
            @(negedge clk); enc_tx_ready = 1;
            @(posedge clk); #1;
            @(negedge clk); enc_tx_ready = 0;
        end
    endtask

    task automatic commit_request;
        begin
            @(negedge clk); enc_tx_commit = 1;
            #1;
            if (dut.r_tx_inflight_kind == dut.TXK_NONE)
                $fatal(1, "P3: test attempted commit without inflight kind");
            @(posedge clk); #1;
            @(negedge clk); enc_tx_commit = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_spw_datalink_semantics.vcd");
        $dumpvars(0, tb_spw_datalink_semantics);

        // P5/P6: N-Char ownership/accept does not spend credit; COMMIT does.
        reset_dut();
        enter_run(6'd3, 6'd0);
        net_tx_valid = 1;
        wait (net_tx_ready);
        @(posedge clk); #1; // NET_TX_ACCEPT creates registered request
        @(negedge clk); net_tx_valid = 0;
        accept_request();
        if (dut.r_tx_credit !== 6'd3)
            $fatal(1, "P6: N-Char ACCEPT changed credit");
        commit_request();
        if (dut.r_tx_credit !== 6'd2)
            $fatal(1, "P5: N-Char COMMIT did not decrement credit");

        // P7: independent FCT changes RX credit only on its wire COMMIT.
        reset_dut();
        enter_run(6'd0, 6'd0);
        rx_fifo_free_count = 8'd128;
        wait (enc_tx_valid && enc_tx_char == 9'h100);
        accept_request();
        if (dut.r_rx_credit !== 6'd0)
            $fatal(1, "P7: FCT ACCEPT changed RX credit");
        commit_request();
        if (dut.r_rx_credit !== 6'd8)
            $fatal(1, "P7: independent FCT COMMIT did not add eight credits");

        // P8/P12: Null FCT is semantically distinct and cannot be interleaved.
        reset_dut();
        enter_run(6'd0, 6'd0);
        rx_fifo_free_count = 0;
        wait (enc_tx_valid && enc_tx_char == 9'h103);
        accept_request();
        commit_request();
        wait (enc_tx_valid);
        if (enc_tx_char !== 9'h100 || dut.r_tx_req_kind != dut.TXK_NULL_FCT)
            $fatal(1, "P12: non-Null character interleaved after NULL_ESC_COMMIT");
        accept_request();
        commit_request();
        if (dut.r_rx_credit !== 6'd0)
            $fatal(1, "P8: Null FCT incorrectly added RX credit");

        // Connecting: FCT request/accept plus peer FCT is insufficient.
        // The local independent FCT must actually COMMIT before RUN.
        reset_dut();
        force dut.r_state = 3'd4;
        force dut.r_tx_credit = 6'd0;
        force dut.r_rx_credit = 6'd0;
        force dut.r_req_initial_fct = 3'd1;
        force dut.r_got_fct = 1'b0;
        force dut.r_sent_fct = 1'b0;
        force dut.r_timer_cnt = '0;
        @(negedge clk);
        release dut.r_state;
        release dut.r_tx_credit;
        release dut.r_rx_credit;
        release dut.r_req_initial_fct;
        release dut.r_got_fct;
        release dut.r_sent_fct;
        release dut.r_timer_cnt;

        wait (enc_tx_valid && enc_tx_char == 9'h100);
        accept_request();
        enc_rx_char = 9'h100;
        @(negedge clk); enc_rx_valid = 1;
        @(posedge clk); #1;
        if (link_state !== 3'd4)
            $fatal(1, "Connecting entered RUN before local FCT COMMIT");
        @(negedge clk); enc_rx_valid = 0;
        commit_request();
        if (!dut.r_sent_fct || link_state !== 3'd4)
            $fatal(1, "Connecting local FCT completion bookkeeping failed");
        @(posedge clk); #1;
        if (link_state !== 3'd5)
            $fatal(1, "Connecting did not enter RUN after gotFCT + SentFCT");

        $display("PASS tb_spw_datalink_semantics");
        $finish;
    end

    initial #20000 $fatal(1, "timeout");
endmodule
