`timescale 1ns/1ps

module tb_spw_datalink_contract;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [8:0] tx_char_data;
    logic tx_char_valid, tx_char_ready, tx_char_commit;
    logic [2:0] link_state;
    logic tx_enable, rx_enable, rx_parity_enable;
    logic link_recovery_evt;
    logic net_tx_ready;

    initial begin
        $dumpfile("tb_spw_datalink_contract.vcd");
        $dumpvars(0, tb_spw_datalink_contract);
    end

    spw_datalink #(
        .RX_FIFO_DEPTH(128), .MAX_CREDIT(56), .CNT_6US(2), .CNT_12US(32)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(1'b1), .i_link_start(1'b1), .i_auto_start(1'b0),
        .i_port_reset(1'b0),
        .i_enc_rx_char(9'd0), .i_enc_rx_valid(1'b0),
        .i_enc_parity_error(1'b0), .i_disconnect_err_evt(1'b0),
        .o_tx_enable(tx_enable), .o_rx_enable(rx_enable),
        .o_rx_parity_enable(rx_parity_enable),
        .o_enc_tx_char(tx_char_data), .o_enc_tx_valid(tx_char_valid),
        .i_enc_tx_ready(tx_char_ready), .i_enc_tx_commit(tx_char_commit),
        .i_enc_tx_abort(1'b0),
        .o_link_recovery_evt(link_recovery_evt),
        .i_net_tx_data(9'h055), .i_net_tx_valid(1'b0),
        .o_net_tx_ready(net_tx_ready),
        .o_net_rx_data(), .o_net_rx_valid(), .i_net_rx_ready(1'b1),
        .o_net_rx_is_ctrl(),
        .i_rx_fifo_free_count(8'd128),
        .i_tx_timecode_req_evt(1'b0), .i_tx_timecode_data(8'd0),
        .o_rx_timecode_commit_evt(), .o_rx_timecode_data(),
        .o_link_state(link_state), .o_disconnect_err_evt(),
        .o_parity_err_evt(), .o_esc_err_evt(), .o_credit_err_evt()
    );

    logic [8:0] held_data;
    initial begin
        tx_char_ready = 1'b0;
        tx_char_commit = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        wait (link_state == 3'd3); // STARTED
        wait (tx_char_valid);
        held_data = tx_char_data;
        if (held_data !== 9'h103) $fatal(1, "STARTED must offer ESC");

        repeat (5) begin
            @(posedge clk);
            if (!tx_char_valid || tx_char_data !== held_data)
                $fatal(1, "valid/data changed before ready");
        end

        @(negedge clk);
        tx_char_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        tx_char_ready = 1'b0;
        if (net_tx_ready) $fatal(1, "Null ESC must not accept an N-Char");

        repeat (3) begin
            @(posedge clk); #1;
            if (tx_char_valid)
                $fatal(1, "P12: second Null character requested before ESC commit");
        end

        @(negedge clk); tx_char_commit = 1'b1;
        #1;
        if (!dut.w_tx_null_esc_commit_evt)
            $fatal(1, "missing NULL_ESC_COMMIT semantic event");
        @(posedge clk); #1;
        @(negedge clk); tx_char_commit = 1'b0;

        wait (tx_char_valid);
        if (tx_char_data !== 9'h100)
            $fatal(1, "ESC commit must schedule held Null FCT");
        if (dut.r_sent_null) $fatal(1, "SentNull asserted before Null FCT commit");

        @(negedge clk); tx_char_ready = 1'b1;
        @(posedge clk);
        @(negedge clk); tx_char_ready = 1'b0;
        @(negedge clk); tx_char_commit = 1'b1;
        #1;
        if (!dut.w_tx_null_fct_commit_evt)
            $fatal(1, "missing NULL_FCT_COMMIT semantic event");
        @(posedge clk); #1;
        if (!dut.r_sent_null)
            $fatal(1, "Null sequence did not complete on FCT commit");
        @(negedge clk); tx_char_commit = 1'b0;

        $display("PASS tb_spw_datalink_contract");
        $finish;
    end

    initial begin
        #5000 $fatal(1, "timeout");
    end
endmodule
