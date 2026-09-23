`timescale 1ns/1ps

module tb_spw_story;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 100 MHz

    logic link_enable = 0, link_start = 0, auto_start = 0, port_reset = 0;
    logic [8:0] host_tx_item = 0;
    logic host_tx_valid = 0, host_tx_ready;
    logic [8:0] host_rx_item;
    logic host_rx_valid, host_rx_ready = 1;
    logic host_tc_req = 0;
    logic [7:0] host_tc_data = 0;
    logic host_rx_tc_evt;
    logic [7:0] host_rx_tc_data;
    logic [2:0] link_state;
    logic err_disconnect, err_parity, err_esc, err_credit;
    logic err_host_tx, err_phy_disconnect;
    logic tx_d, tx_s;
    logic rx_d, rx_s;
    logic [2:0] story_phase; // 0=reset, 1=initialize, 2=flow, 3=error, 4=reconnect

    assign rx_d = tx_d;
    assign rx_s = tx_s;

    spw_top #(
        .CLK_FREQ_HZ(100_000_000),
        .TX_RATE_MBPS(25),
        .DISCONNECT_TIMEOUT_NS(850),
        .TX_FIFO_DEPTH(16),
        .RX_FIFO_DEPTH(16),
        .MAX_CREDIT(56)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(link_enable), .i_link_start(link_start),
        .i_auto_start(auto_start), .i_port_reset(port_reset),
        .i_rx_ds_data_pad(rx_d), .i_rx_ds_strobe_pad(rx_s),
        .o_tx_ds_data_pad(tx_d), .o_tx_ds_strobe_pad(tx_s),
        .i_host_tx_item(host_tx_item), .i_host_tx_valid(host_tx_valid),
        .o_host_tx_ready(host_tx_ready),
        .o_host_rx_item(host_rx_item), .o_host_rx_valid(host_rx_valid),
        .i_host_rx_ready(host_rx_ready),
        .i_host_tx_timecode_req(host_tc_req),
        .i_host_tx_timecode_data(host_tc_data),
        .o_host_rx_timecode_commit_evt(host_rx_tc_evt),
        .o_host_rx_timecode_data(host_rx_tc_data),
        .o_link_state(link_state),
        .o_disconnect_err_evt(err_disconnect), .o_parity_err_evt(err_parity),
        .o_esc_err_evt(err_esc), .o_credit_err_evt(err_credit),
        .o_host_tx_item_err_evt(err_host_tx),
        .o_phy_disconnect_err_evt(err_phy_disconnect)
    );

    spw_wave_observer u_obs (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_link_state(link_state),
        .i_err_disconnect_evt(err_disconnect),
        .i_err_parity_evt(err_parity),
        .i_err_esc_evt(err_esc),
        .i_err_credit_evt(err_credit),
        .i_err_host_tx_evt(err_host_tx),
        .i_err_phy_disconnect_evt(err_phy_disconnect),
        .i_net_tx_valid(dut.w_net_tx_valid),
        .i_net_tx_ready(dut.w_net_tx_ready),
        .i_net_rx_valid(dut.w_net_rx_valid),
        .i_net_rx_ready(dut.w_net_rx_ready),
        .i_enc_tx_char(dut.w_enc_tx_char),
        .i_enc_tx_valid(dut.w_enc_tx_valid),
        .i_enc_tx_ready(dut.w_enc_tx_ready),
        .i_enc_tx_commit_evt(dut.w_enc_tx_commit),
        .i_enc_tx_abort_evt(dut.w_enc_tx_abort),
        .i_enc_rx_char(dut.w_enc_rx_char),
        .i_enc_rx_valid(dut.w_enc_rx_valid),
        .i_link_recovery_evt(dut.w_link_recovery),
        .i_tx_credit(dut.u_spw_datalink.r_tx_credit),
        .i_rx_credit(dut.u_spw_datalink.r_rx_credit),
        .i_tx_fifo_level(dut.u_spw_network.r_tx_count),
        .i_rx_fifo_level(dut.u_spw_network.r_rx_count),
        .i_tx_inflight_kind(dut.u_spw_datalink.r_tx_inflight_kind),
        .i_rx_pending_esc(dut.u_spw_datalink.r_rx_pending_esc),
        .i_ser_bit_evt(dut.u_spw_enc.w_tx_pop),
        .i_ser_bit_value(dut.u_spw_enc.w_tx_next_bit),
        .i_ser_accept_evt(dut.u_spw_enc.w_tx_accept_evt),
        .i_ser_bits_left(dut.u_spw_enc.r_tx_bits_left)
    );

    task automatic wait_state(input logic [2:0] expected, input integer max_cycles);
        integer n;
        begin
            for (n = 0; n < max_cycles && link_state != expected; n = n + 1)
                @(posedge clk);
            if (link_state != expected)
                $fatal(1, "state timeout: expected=%0d actual=%0d", expected, link_state);
        end
    endtask

    task automatic host_send(input logic [8:0] item);
        begin
            @(negedge clk);
            host_tx_item = item;
            host_tx_valid = 1'b1;
            do @(posedge clk); while (!host_tx_ready);
            @(negedge clk);
            host_tx_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("spw_story.vcd");
        $dumpvars(0, tb_spw_story);
        story_phase = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Story 1: Link initialization
        story_phase = 1;
        link_enable = 1;
        link_start = 1;
        wait_state(3'd5, 10000); // RUN
        repeat (20) @(posedge clk);

        // Story 2: Flow control and N-Char transfer
        story_phase = 2;
        host_send(9'h041);
        host_send(9'h042);
        host_send(9'h043);
        host_send(9'h100); // Host EOP
        repeat (300) @(posedge clk);

        // Story 3: deterministic parity-error recovery trigger.
        // Force is TB-only; it isolates Link recovery behavior from bit corruption details.
        story_phase = 3;
        @(negedge clk);
        force dut.u_spw_enc.or_parity_err = 1'b1;
        @(posedge clk);
        @(negedge clk);
        release dut.u_spw_enc.or_parity_err;
        wait_state(3'd0, 50); // ERROR_RESET

        // Reconnect narrative
        story_phase = 4;
        wait_state(3'd5, 10000);
        repeat (30) @(posedge clk);
        $display("PASS tb_spw_story");
        $finish;
    end

    initial #500_000 $fatal(1, "story timeout");
endmodule
