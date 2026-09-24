`timescale 1ns/1ps
// Same stimulus is compiled against the original baseline and the v4 candidate.
module tb_spw_dual_backpressure;
    localparam int ITEMS = 96;
    localparam int RX_DEPTH = 32;
    logic clk = 0, rst_n = 0, started = 0;
    always #5 clk = ~clk;
    logic [1:0][8:0] host_tx_item;
    logic [1:0] host_tx_valid, host_tx_ready;
    wire [1:0][8:0] host_rx_item;
    wire [1:0] host_rx_valid;
    logic [1:0] host_rx_ready;
    wire [1:0][2:0] link_state;
    wire [1:0] tx_d, tx_s;
    wire [1:0] err_disconnect, err_parity, err_esc;
    wire [1:0] err_credit, err_host_tx, err_phy;
    int tx_sent [0:1], rx_recv [0:1], net_accept [0:1];
    int net_wait [0:1], full_cycles = 0, stall_cycles = 0;
    int cycle_count = 0, start_cycle = -1, stall_end_cycle = -1;
    int last_rx_cycle [0:1];
    int max_rx_gap [0:1];
    logic full_seen = 0;

    for (genvar g = 0; g < 2; g++) begin: ep
        spw_top #(
            .CLK_FREQ_HZ(100_000_000), .TX_RATE_MBPS(25),
            .TX_FIFO_DEPTH(128), .RX_FIFO_DEPTH(RX_DEPTH)
        ) dut (
            .i_clk(clk), .i_rst_n(rst_n),
            .i_link_enable(1'b1), .i_link_start(1'b1),
            .i_auto_start(1'b0), .i_port_reset(1'b0),
            .i_rx_ds_data_pad(tx_d[1-g]), .i_rx_ds_strobe_pad(tx_s[1-g]),
            .o_tx_ds_data_pad(tx_d[g]), .o_tx_ds_strobe_pad(tx_s[g]),
            .i_host_tx_item(host_tx_item[g]), .i_host_tx_valid(host_tx_valid[g]),
            .o_host_tx_ready(host_tx_ready[g]),
            .o_host_rx_item(host_rx_item[g]), .o_host_rx_valid(host_rx_valid[g]),
            .i_host_rx_ready(host_rx_ready[g]),
            .i_host_tx_timecode_req(1'b0), .i_host_tx_timecode_data(8'd0),
            .o_host_rx_timecode_commit_evt(), .o_host_rx_timecode_data(),
            .o_link_state(link_state[g]),
            .o_disconnect_err_evt(err_disconnect[g]),
            .o_parity_err_evt(err_parity[g]), .o_esc_err_evt(err_esc[g]),
            .o_credit_err_evt(err_credit[g]),
            .o_host_tx_item_err_evt(err_host_tx[g]),
            .o_phy_disconnect_err_evt(err_phy[g])
        );
    end

    always @(negedge clk) begin
        for (int side = 0; side < 2; side++) begin
            host_tx_valid[side] = started && tx_sent[side] < ITEMS;
            host_tx_item[side] = 9'((side == 0 ? 0 : 128) + tx_sent[side]);
        end
        // A's receive host stalls long enough to fill its RX FIFO.
        // B's receive host remains ready, proving opposite direction can progress.
        host_rx_ready[0] = started && cycle_count >= start_cycle + 6000
                         && ((cycle_count % 4) != 0);
        host_rx_ready[1] = 1'b1;
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (rst_n) begin
            for (int side = 0; side < 2; side++) begin
                if (err_disconnect[side] || err_parity[side] || err_esc[side] ||
                    err_credit[side] || err_host_tx[side] || err_phy[side])
                    $fatal(1, "endpoint %0d link error cycle %0d state %0d",
                           side, cycle_count, link_state[side]);
                if (host_tx_valid[side] && host_tx_ready[side])
                    tx_sent[side] = tx_sent[side] + 1;
                if (host_rx_valid[side] && host_rx_ready[side]) begin
                    if (rx_recv[side] >= ITEMS ||
                        host_rx_item[side] !== 9'((side == 0 ? 128 : 0) + rx_recv[side]))
                        $fatal(1, "endpoint %0d RX order/data at %0d got %03h",
                               side, rx_recv[side], host_rx_item[side]);
                    if (last_rx_cycle[side] > 0 &&
                        cycle_count - last_rx_cycle[side] > max_rx_gap[side])
                        max_rx_gap[side] = cycle_count - last_rx_cycle[side];
                    last_rx_cycle[side] = cycle_count;
                    rx_recv[side] = rx_recv[side] + 1;
                end
            end
            if (ep[0].dut.w_net_tx_valid && ep[0].dut.w_net_tx_ready)
                net_accept[0] = net_accept[0] + 1;
            if (ep[1].dut.w_net_tx_valid && ep[1].dut.w_net_tx_ready)
                net_accept[1] = net_accept[1] + 1;
            if (ep[0].dut.w_net_tx_valid && !ep[0].dut.w_net_tx_ready)
                net_wait[0] = net_wait[0] + 1;
            if (ep[1].dut.w_net_tx_valid && !ep[1].dut.w_net_tx_ready)
                net_wait[1] = net_wait[1] + 1;
            if (started && cycle_count < start_cycle + 6000) begin
                stall_cycles = stall_cycles + 1;
                if (ep[0].dut.u_spw_network.r_rx_count == RX_DEPTH) begin
                    full_seen = 1;
                    full_cycles = full_cycles + 1;
                end
                if (rx_recv[1] == ITEMS && stall_end_cycle < 0)
                    stall_end_cycle = cycle_count;
            end
        end
    end

    initial begin
        for (int side = 0; side < 2; side++) begin
            tx_sent[side] = 0;
            rx_recv[side] = 0;
            net_accept[side] = 0;
            net_wait[side] = 0;
            last_rx_cycle[side] = -1;
            max_rx_gap[side] = 0;
            host_tx_item[side] = '0;
            host_tx_valid[side] = 0;
            host_rx_ready[side] = 0;
        end
        repeat (5) @(negedge clk);
        rst_n = 1;
        wait (link_state[0] == 3'd5 && link_state[1] == 3'd5);
        repeat (10) @(negedge clk);
        started = 1;
        start_cycle = cycle_count;
        wait (rx_recv[0] == ITEMS && rx_recv[1] == ITEMS);
        repeat (3) @(negedge clk);
        if (tx_sent[0] != ITEMS || tx_sent[1] != ITEMS ||
            net_accept[0] != ITEMS || net_accept[1] != ITEMS ||
            rx_recv[0] != ITEMS || rx_recv[1] != ITEMS)
            $fatal(1, "count mismatch");
        if (!full_seen || net_wait[1] == 0 || stall_end_cycle < 0 ||
            stall_end_cycle >= start_cycle + 6000)
            $fatal(1, "backpressure or independent progress not exercised");
        $display("DUAL tx=%0d,%0d net=%0d,%0d rx=%0d,%0d",
                 tx_sent[0], tx_sent[1], net_accept[0], net_accept[1],
                 rx_recv[0], rx_recv[1]);
        $display("DUAL stall_cycles=%0d full_cycles=%0d B_tx_wait=%0d A_tx_wait=%0d",
                 stall_cycles, full_cycles, net_wait[1], net_wait[0]);
        $display("DUAL opposite_complete_cycle=%0d stall_release_cycle=%0d max_rx_gap=%0d,%0d",
                 stall_end_cycle, start_cycle + 6000, max_rx_gap[0], max_rx_gap[1]);
        $display("PASS tb_spw_dual_backpressure");
        $finish;
    end
    initial #2_000_000 $fatal(1, "dual timeout A=%0d B=%0d state=%0d,%0d",
                              rx_recv[0], rx_recv[1], link_state[0], link_state[1]);
endmodule
