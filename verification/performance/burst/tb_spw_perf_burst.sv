`timescale 1ns/1ps

// Measurement-only, self-looped burst. Keep outside the baseline RTL tree.
module tb_spw_perf_burst;
    localparam int ITEMS = 64;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [8:0] host_tx_item = 0;
    logic host_tx_valid = 0;
    logic host_tx_ready;
    logic [8:0] host_rx_item;
    logic host_rx_valid;
    logic [2:0] link_state;
    logic tx_d, tx_s;
    logic err_disconnect, err_parity, err_esc, err_credit;
    logic err_host_tx, err_phy_disconnect;

    int host_tx_count = 0;
    int net_tx_count = 0;
    int host_rx_count = 0;
    int first_net_tx_cycle = -1;
    int last_net_tx_cycle = -1;
    int first_host_rx_cycle = -1;
    int last_host_rx_cycle = -1;
    int min_net_tx_gap = 1000000;
    int max_net_tx_gap = 0;
    int gap_40_count = 0;
    int gap_56_count = 0;
    int gap_other_count = 0;
    int net_tx_wait_cycles = 0;
    int cycle_count = 0;

    spw_top #(
        .CLK_FREQ_HZ(100_000_000), .TX_RATE_MBPS(25),
        .TX_FIFO_DEPTH(128), .RX_FIFO_DEPTH(128)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(1'b1), .i_link_start(1'b1),
        .i_auto_start(1'b0), .i_port_reset(1'b0),
        .i_rx_ds_data_pad(tx_d), .i_rx_ds_strobe_pad(tx_s),
        .o_tx_ds_data_pad(tx_d), .o_tx_ds_strobe_pad(tx_s),
        .i_host_tx_item(host_tx_item), .i_host_tx_valid(host_tx_valid),
        .o_host_tx_ready(host_tx_ready),
        .o_host_rx_item(host_rx_item), .o_host_rx_valid(host_rx_valid),
        .i_host_rx_ready(1'b1),
        .i_host_tx_timecode_req(1'b0), .i_host_tx_timecode_data(8'd0),
        .o_host_rx_timecode_commit_evt(), .o_host_rx_timecode_data(),
        .o_link_state(link_state),
        .o_disconnect_err_evt(err_disconnect), .o_parity_err_evt(err_parity),
        .o_esc_err_evt(err_esc), .o_credit_err_evt(err_credit),
        .o_host_tx_item_err_evt(err_host_tx),
        .o_phy_disconnect_err_evt(err_phy_disconnect)
    );

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (rst_n) begin
            if (err_disconnect || err_parity || err_esc || err_credit ||
                err_host_tx || err_phy_disconnect)
                $fatal(1, "unexpected link error at cycle %0d", cycle_count);
            if (host_tx_valid && host_tx_ready)
                host_tx_count = host_tx_count + 1;
            if (dut.w_net_tx_valid && !dut.w_net_tx_ready)
                net_tx_wait_cycles = net_tx_wait_cycles + 1;
            if (dut.w_net_tx_valid && dut.w_net_tx_ready) begin
                if (first_net_tx_cycle < 0)
                    first_net_tx_cycle = cycle_count;
                else begin
                    case (cycle_count - last_net_tx_cycle)
                        40: gap_40_count = gap_40_count + 1;
                        56: gap_56_count = gap_56_count + 1;
                        default: gap_other_count = gap_other_count + 1;
                    endcase
                    if (cycle_count - last_net_tx_cycle < min_net_tx_gap)
                        min_net_tx_gap = cycle_count - last_net_tx_cycle;
                    if (cycle_count - last_net_tx_cycle > max_net_tx_gap)
                        max_net_tx_gap = cycle_count - last_net_tx_cycle;
                end
                last_net_tx_cycle = cycle_count;
                net_tx_count = net_tx_count + 1;
            end
            if (host_rx_valid) begin
                if (host_rx_item !== 9'(host_rx_count))
                    $fatal(1, "RX mismatch at item %0d: got %03h", host_rx_count, host_rx_item);
                if (first_host_rx_cycle < 0)
                    first_host_rx_cycle = cycle_count;
                last_host_rx_cycle = cycle_count;
                host_rx_count = host_rx_count + 1;
            end
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        wait (link_state == 3'd5);
        repeat (10) @(negedge clk);

        for (int i = 0; i < ITEMS; i++) begin
            @(negedge clk);
            host_tx_item = 9'(i);
            host_tx_valid = 1'b1;
            do @(posedge clk); while (!host_tx_ready);
        end
        @(negedge clk);
        host_tx_valid = 1'b0;
        wait (host_rx_count == ITEMS);
        repeat (2) @(negedge clk);

        if (host_tx_count != ITEMS || net_tx_count != ITEMS || host_rx_count != ITEMS)
            $fatal(1, "count mismatch: host_tx=%0d net_tx=%0d host_rx=%0d",
                   host_tx_count, net_tx_count, host_rx_count);
        $display("PERF items=%0d host_tx=%0d net_tx=%0d host_rx=%0d", ITEMS,
                 host_tx_count, net_tx_count, host_rx_count);
        $display("PERF net_tx_first=%0d net_tx_last=%0d span_cycles=%0d min_gap=%0d max_gap=%0d",
                 first_net_tx_cycle, last_net_tx_cycle,
                 last_net_tx_cycle - first_net_tx_cycle, min_net_tx_gap, max_net_tx_gap);
        $display("PERF host_rx_first=%0d host_rx_last=%0d span_cycles=%0d",
                 first_host_rx_cycle, last_host_rx_cycle,
                 last_host_rx_cycle - first_host_rx_cycle);
        $display("PERF gaps_40=%0d gaps_56=%0d gaps_other=%0d net_tx_wait_cycles=%0d",
                 gap_40_count, gap_56_count, gap_other_count, net_tx_wait_cycles);
        $display("PASS tb_spw_perf_burst");
        $finish;
    end

    initial #2_000_000 $fatal(1, "burst timeout: net_tx=%0d host_rx=%0d state=%0d",
                              net_tx_count, host_rx_count, link_state);
endmodule
