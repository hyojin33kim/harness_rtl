`timescale 1ns/1ps

// Golden model scenario_24 uses TC_PERIOD_CYCLES=2. Periodic variants cover
// 700/1,000 ns requests at 10/25 Mbps on a 100 MHz system clock.
module tb_spw_decision17_tc_starvation #(
    parameter int TX_RATE_MBPS = 25,
    parameter int TC_PERIOD_CYCLES = 2,
    parameter bit EXPECT_YIELD = 1'b1
);
    localparam int N_BYTES = 300;
    localparam int TRAFFIC_BOUND = 140000;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic a_tx_d, a_tx_s, b_tx_d, b_tx_s;
    logic a_tc_req = 0;
    logic [7:0] a_tc_data = 0;
    logic [8:0] a_rx_item;
    logic a_rx_valid;
    logic b_rx_tc_evt;
    logic [8:0] b_tx_item = 0;
    logic b_tx_valid = 0, b_tx_ready;
    logic [2:0] a_state, b_state;
    logic a_credit_err, b_credit_err, a_esc_err, b_esc_err;

    spw_top #(.TX_RATE_MBPS(TX_RATE_MBPS)) node_a (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(1'b1), .i_link_start(1'b1),
        .i_auto_start(1'b0), .i_port_reset(1'b0),
        .i_rx_ds_data_pad(b_tx_d), .i_rx_ds_strobe_pad(b_tx_s),
        .o_tx_ds_data_pad(a_tx_d), .o_tx_ds_strobe_pad(a_tx_s),
        .i_host_tx_item(9'd0), .i_host_tx_valid(1'b0), .o_host_tx_ready(),
        .o_host_rx_item(a_rx_item), .o_host_rx_valid(a_rx_valid),
        .i_host_rx_ready(1'b1),
        .i_host_tx_timecode_req(a_tc_req), .i_host_tx_timecode_data(a_tc_data),
        .o_host_rx_timecode_commit_evt(), .o_host_rx_timecode_data(),
        .o_link_state(a_state), .o_disconnect_err_evt(), .o_parity_err_evt(),
        .o_esc_err_evt(a_esc_err), .o_credit_err_evt(a_credit_err),
        .o_host_tx_item_err_evt(), .o_phy_disconnect_err_evt()
    );
    spw_top #(.TX_RATE_MBPS(TX_RATE_MBPS)) node_b (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(1'b1), .i_link_start(1'b0),
        .i_auto_start(1'b1), .i_port_reset(1'b0),
        .i_rx_ds_data_pad(a_tx_d), .i_rx_ds_strobe_pad(a_tx_s),
        .o_tx_ds_data_pad(b_tx_d), .o_tx_ds_strobe_pad(b_tx_s),
        .i_host_tx_item(b_tx_item), .i_host_tx_valid(b_tx_valid),
        .o_host_tx_ready(b_tx_ready),
        .o_host_rx_item(), .o_host_rx_valid(), .i_host_rx_ready(1'b1),
        .i_host_tx_timecode_req(1'b0), .i_host_tx_timecode_data(8'd0),
        .o_host_rx_timecode_commit_evt(b_rx_tc_evt), .o_host_rx_timecode_data(),
        .o_link_state(b_state), .o_disconnect_err_evt(), .o_parity_err_evt(),
        .o_esc_err_evt(b_esc_err), .o_credit_err_evt(b_credit_err),
        .o_host_tx_item_err_evt(), .o_phy_disconnect_err_evt()
    );

    int rx_count = 0, tc_count = 0, fct_count = 0, yield_count = 0;
    int max_tc_count = 0;
    int tx_index = 0;
    bit eop_seen = 0;
    bit bad_data = 0;
    bit error_seen = 0;
    always @(posedge clk) begin
        if (rst_n && b_rx_tc_evt) tc_count++;
        if (rst_n && node_a.u_spw_datalink.w_tx_fct_commit_evt) fct_count++;
        if (rst_n && node_a.u_spw_datalink.w_tx_select_evt &&
            node_a.u_spw_datalink.w_tc_starve_yield) yield_count++;
        if (rst_n && node_a.u_spw_datalink.r_tc_starve_cnt > max_tc_count)
            max_tc_count = node_a.u_spw_datalink.r_tc_starve_cnt;
        if (rst_n && node_a.u_spw_datalink.r_tc_starve_cnt > 4'd8)
            $fatal(1, "DECISION-17 consecutive Timecode count exceeded 8");
        if (rst_n && (a_credit_err || b_credit_err || a_esc_err || b_esc_err))
            error_seen = 1;
        if (rst_n && a_rx_valid) begin
            if (a_rx_item == 9'h100) eop_seen = 1;
            else if (a_rx_item !== {1'b0, 8'((rx_count * 3 + 11) & 255)})
                bad_data = 1;
            else rx_count++;
        end
    end

    // One-clock request pulse every TC_PERIOD_CYCLES clocks. The default
    // rising edge every two clocks matches scenario_24's toggle.
    int tc_cycle = 0;
    always @(negedge clk) begin
        if (rst_n) begin
            a_tc_req = ((tc_cycle % TC_PERIOD_CYCLES) == 0);
            if (a_tc_req) a_tc_data = {2'b00, a_tc_data[5:0] + 6'd1};
            tc_cycle++;
        end
    end

    initial begin : test
        int n;
        if (TC_PERIOD_CYCLES < 2)
            $fatal(1, "TC_PERIOD_CYCLES must be at least 2");
        repeat (5) @(negedge clk);
        rst_n = 1;
        for (n = 0; n < 20000 && (a_state != 3'd5 || b_state != 3'd5); n++)
            @(negedge clk);
        if (a_state != 3'd5 || b_state != 3'd5)
            $fatal(1, "DECISION-17 link RUN timeout: A=%0d B=%0d", a_state, b_state);

        for (n = 0; n < TRAFFIC_BOUND && !eop_seen; n++) begin
            @(negedge clk);
            b_tx_valid = (tx_index <= N_BYTES);
            b_tx_item = (tx_index == N_BYTES) ? 9'h100
                       : {1'b0, 8'((tx_index * 3 + 11) & 255)};
            @(posedge clk);
            if (b_tx_valid && b_tx_ready) tx_index++;
        end
        @(negedge clk);
        b_tx_valid = 0;
        $display("DECISION17 rate=%0d period=%0d cycles=%0d tx=%0d rx=%0d eop=%0b tc=%0d fct=%0d yield=%0d maxcnt=%0d bad=%0b errors=%0b",
                 TX_RATE_MBPS, TC_PERIOD_CYCLES, n, tx_index, rx_count,
                 eop_seen, tc_count, fct_count, yield_count, max_tc_count,
                 bad_data, error_seen);
        if (!eop_seen || rx_count != N_BYTES || bad_data || tx_index != N_BYTES+1)
            $fatal(1, "DECISION-17 packet stalled or corrupted");
        if (tc_count < 50 || fct_count <= 2)
            $fatal(1, "DECISION-17 Timecode or FCT progress missing");
        if (EXPECT_YIELD && (yield_count == 0 || max_tc_count != 8))
            $fatal(1, "DECISION-17 expected throttle did not occur");
        if (!EXPECT_YIELD && (yield_count != 0 || max_tc_count >= 8))
            $fatal(1, "DECISION-17 unexpected throttle occurred");
        if (error_seen)
            $fatal(1, "DECISION-17 credit/ESC error");
        $display("PASS tb_spw_decision17_tc_starvation");
        $finish;
    end
endmodule
