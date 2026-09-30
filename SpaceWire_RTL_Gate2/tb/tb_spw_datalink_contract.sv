`timescale 1ns/1ps

module tb_spw_datalink_contract;
    initial begin
        $dumpfile("build/tb_spw_datalink_contract.vcd");
        $dumpvars(0, tb_spw_datalink_contract);
    end

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [8:0] tx_char_data;
    logic tx_char_valid, tx_char_ready;
    logic [2:0] link_state;
    logic tx_enable, rx_enable, rx_parity_enable;
    logic link_recovery_evt;
    logic tx_nchar_accept_evt;

    spw_datalink #(
        .RX_FIFO_DEPTH(128), .MAX_CREDIT(56), .CNT_6US(2), .CNT_12US(32)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(1'b1), .i_link_start(1'b1), .i_auto_start(1'b0),
        .i_port_reset(1'b0),
        .i_rx_char_commit_evt(1'b0), .i_rx_char_data(9'd0),
        .i_rx_parity_err_evt(1'b0), .i_disconnect_err_evt(1'b0),
        .o_tx_enable(tx_enable), .o_rx_enable(rx_enable),
        .o_rx_parity_enable(rx_parity_enable),
        .o_tx_char_valid(tx_char_valid), .o_tx_char_data(tx_char_data),
        .i_tx_char_ready(tx_char_ready), .i_tx_char_commit_evt(1'b0),
        .o_link_recovery_evt(link_recovery_evt),
        .i_tx_nchar_data(9'h055), .i_tx_nchar_valid(1'b0),
        .o_tx_nchar_accept_evt(tx_nchar_accept_evt),
        .o_rx_nchar_data(), .o_rx_nchar_commit_evt(), .o_rx_nchar_is_ctrl(),
        .i_rx_fifo_free_count(8'd128),
        .i_tx_timecode_req_evt(1'b0), .i_tx_timecode_data(8'd0),
        .o_rx_timecode_commit_evt(), .o_rx_timecode_data(),
        .o_link_state(link_state), .o_disconnect_err_evt(),
        .o_parity_err_evt(), .o_esc_err_evt(), .o_credit_err_evt()
    );

    logic [8:0] held_data;
    initial begin
        tx_char_ready = 1'b0;
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
        if (tx_nchar_accept_evt) $fatal(1, "Null ESC must not pop N-Char");

        repeat (2) @(posedge clk);
        if (!tx_char_valid || tx_char_data !== 9'h100)
            $fatal(1, "accepted ESC must be followed by held FCT");

        $display("PASS tb_spw_datalink_contract");
        $finish;
    end

    initial begin
        #5000 $fatal(1, "timeout");
    end
endmodule
