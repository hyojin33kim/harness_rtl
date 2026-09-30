`timescale 1ns/1ps

module tb_spw_network_tx_handshake;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [8:0] host_tx_item = '0;
    logic host_tx_valid = 0;
    logic host_tx_ready;
    logic net_tx_ready = 0;
    logic [8:0] net_tx_data;
    logic net_tx_valid;
    logic [2:0] rx_free_count;

    spw_network #(.TX_FIFO_DEPTH(4), .RX_FIFO_DEPTH(4)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_host_tx_item(host_tx_item), .i_host_tx_valid(host_tx_valid),
        .o_host_tx_ready(host_tx_ready),
        .o_host_rx_item(), .o_host_rx_valid(), .i_host_rx_ready(1'b0),
        .o_host_tx_item_err_evt(),
        .o_net_tx_data(net_tx_data), .o_net_tx_valid(net_tx_valid),
        .i_net_tx_ready(net_tx_ready),
        .i_net_rx_data('0), .i_net_rx_valid(1'b0), .o_net_rx_ready(),
        .i_net_rx_is_ctrl(1'b0), .o_rx_fifo_free_count(rx_free_count),
        .i_host_tx_timecode_req(1'b0), .i_host_tx_timecode_data('0),
        .o_tx_timecode_req_evt(), .o_tx_timecode_data(),
        .i_rx_timecode_commit_evt(1'b0), .i_rx_timecode_data('0),
        .o_host_rx_timecode_commit_evt(), .o_host_rx_timecode_data()
    );

    task automatic push(input logic [8:0] item);
        begin
            @(negedge clk);
            host_tx_item  = item;
            host_tx_valid = 1'b1;
            @(posedge clk);
            #1;
            if (!host_tx_ready) $fatal(1, "host push was not accepted");
            @(negedge clk);
            host_tx_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("tb_spw_network_tx_handshake.vcd");
        $dumpvars(0, tb_spw_network_tx_handshake);

        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        push(9'h055);
        push(9'h066);

        if (!net_tx_valid || net_tx_data !== 9'h055)
            $fatal(1, "wrong FIFO head before stall");

        repeat (3) begin
            @(posedge clk); #1;
            if (!net_tx_valid || net_tx_data !== 9'h055)
                $fatal(1, "P1: data/valid changed while ready=0");
            if (dut.r_tx_count !== 2)
                $fatal(1, "P10: FIFO popped without valid&&ready");
        end

        @(negedge clk); net_tx_ready = 1'b1;
        @(posedge clk); #1;
        if (dut.r_tx_count !== 1 || !net_tx_valid || net_tx_data !== 9'h066)
            $fatal(1, "P10: FIFO did not pop exactly once on valid&&ready");
        @(negedge clk); net_tx_ready = 1'b0;

        repeat (2) begin
            @(posedge clk); #1;
            if (dut.r_tx_count !== 1 || net_tx_data !== 9'h066)
                $fatal(1, "second item changed without another accept");
        end

        $display("PASS tb_spw_network_tx_handshake");
        $finish;
    end
endmodule
