`timescale 1ns/1ps

module tb_spw_net_rx_handshake;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic enc_rx_valid = 0;
    logic [8:0] enc_rx_char = '0;
    logic host_rx_ready = 0;
    logic [8:0] host_rx_item;
    logic host_rx_valid;

    logic [8:0] net_rx_data;
    logic net_rx_valid, net_rx_ready, net_rx_is_ctrl;
    logic [1:0] rx_free_count;

    spw_datalink #(
        .RX_FIFO_DEPTH(2), .MAX_CREDIT(56), .CNT_6US(2), .CNT_12US(8)
    ) u_dl (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(1'b1), .i_link_start(1'b0), .i_auto_start(1'b0),
        .i_port_reset(1'b0),
        .i_enc_rx_char(enc_rx_char), .i_enc_rx_valid(enc_rx_valid),
        .i_enc_parity_error(1'b0), .i_disconnect_err_evt(1'b0),
        .o_tx_enable(), .o_rx_enable(), .o_rx_parity_enable(),
        .o_enc_tx_char(), .o_enc_tx_valid(), .i_enc_tx_ready(1'b0),
        .i_enc_tx_commit(1'b0), .i_enc_tx_abort(1'b0),
        .o_link_recovery_evt(),
        .i_net_tx_data('0), .i_net_tx_valid(1'b0), .o_net_tx_ready(),
        .o_net_rx_data(net_rx_data), .o_net_rx_valid(net_rx_valid),
        .i_net_rx_ready(net_rx_ready), .o_net_rx_is_ctrl(net_rx_is_ctrl),
        .i_rx_fifo_free_count(rx_free_count),
        .i_tx_timecode_req_evt(1'b0), .i_tx_timecode_data('0),
        .o_rx_timecode_commit_evt(), .o_rx_timecode_data(),
        .o_link_state(), .o_disconnect_err_evt(), .o_parity_err_evt(),
        .o_esc_err_evt(), .o_credit_err_evt()
    );

    spw_network #(.TX_FIFO_DEPTH(2), .RX_FIFO_DEPTH(2)) u_net (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_host_tx_item('0), .i_host_tx_valid(1'b0), .o_host_tx_ready(),
        .o_host_rx_item(host_rx_item), .o_host_rx_valid(host_rx_valid),
        .i_host_rx_ready(host_rx_ready), .o_host_tx_item_err_evt(),
        .o_net_tx_data(), .o_net_tx_valid(), .i_net_tx_ready(1'b0),
        .i_net_rx_data(net_rx_data), .i_net_rx_valid(net_rx_valid),
        .o_net_rx_ready(net_rx_ready), .i_net_rx_is_ctrl(net_rx_is_ctrl),
        .o_rx_fifo_free_count(rx_free_count),
        .i_host_tx_timecode_req(1'b0), .i_host_tx_timecode_data('0),
        .o_tx_timecode_req_evt(), .o_tx_timecode_data(),
        .i_rx_timecode_commit_evt(1'b0), .i_rx_timecode_data('0),
        .o_host_rx_timecode_commit_evt(), .o_host_rx_timecode_data()
    );

    task automatic send_rx(input logic [8:0] value);
        begin
            @(negedge clk);
            enc_rx_char = value;
            enc_rx_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            enc_rx_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("tb_spw_net_rx_handshake.vcd");
        $dumpvars(0, tb_spw_net_rx_handshake);

        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        force u_dl.r_state = 3'd5;
        force u_dl.r_rx_credit = 6'd8;
        @(negedge clk);
        release u_dl.r_state;
        release u_dl.r_rx_credit;

        send_rx(9'h011);
        send_rx(9'h102); // Encoding EOP -> host 9'h100
        send_rx(9'h022); // held because the two-entry Network FIFO is full

        #1;
        if (!net_rx_valid || net_rx_ready || net_rx_data !== 9'h022)
            $fatal(1, "P11: expected stalled third character in holding register");

        repeat (3) begin
            @(posedge clk); #1;
            if (!net_rx_valid || net_rx_data !== 9'h022 || net_rx_is_ctrl !== 1'b0)
                $fatal(1, "P11: Network RX payload changed while stalled");
        end

        if (!host_rx_valid || host_rx_item !== 9'h011)
            $fatal(1, "wrong first host RX item");
        @(negedge clk); host_rx_ready = 1'b1;
        @(posedge clk); #1; // full FIFO pop and held-character accept together
        if (u_net.r_rx_count !== 2 || net_rx_valid)
            $fatal(1, "full+pop did not atomically accept held character");
        @(negedge clk); host_rx_ready = 1'b0;

        if (!host_rx_valid || host_rx_item !== 9'h100)
            $fatal(1, "wrong second host RX item");
        @(negedge clk); host_rx_ready = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); host_rx_ready = 1'b0;
        if (!host_rx_valid || host_rx_item !== 9'h022)
            $fatal(1, "held character was not preserved in order");

        $display("PASS tb_spw_net_rx_handshake");
        $finish;
    end

    initial #10000 $fatal(1, "timeout");
endmodule
