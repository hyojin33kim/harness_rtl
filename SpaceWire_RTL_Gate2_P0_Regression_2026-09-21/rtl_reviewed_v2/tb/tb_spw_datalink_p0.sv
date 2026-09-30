`timescale 1ns/1ps

// Gate-2 P0 protocol-contract checks.
// The tests isolate RUN-state corner cases by setting only the precondition
// registers (state/credit). Event decode, priority, next-state, and credit
// arithmetic remain the DUT implementation under test.
module tb_spw_datalink_p0;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic link_enable = 1;
    logic link_start = 0;
    logic auto_start = 0;
    logic port_reset = 0;
    logic rx_char_commit_evt = 0;
    logic [8:0] rx_char_data = 0;
    logic rx_parity_err_evt = 0;
    logic disconnect_err_evt = 0;
    logic tx_char_ready = 0;
    logic tx_char_commit_evt = 0;
    logic [8:0] tx_nchar_data = 9'h055;
    logic tx_nchar_valid = 0;
    logic [7:0] rx_fifo_free_count = 0;
    logic tx_timecode_req_evt = 0;
    logic [7:0] tx_timecode_data = 0;

    logic tx_enable, rx_enable, rx_parity_enable;
    logic tx_char_valid;
    logic [8:0] tx_char_data;
    logic link_recovery_evt;
    logic tx_nchar_accept_evt;
    logic [8:0] rx_nchar_data;
    logic rx_nchar_commit_evt, rx_nchar_is_ctrl;
    logic rx_timecode_commit_evt;
    logic [7:0] rx_timecode_data;
    logic [2:0] link_state;
    logic disconnect_out, parity_out, esc_out, credit_out;

    initial begin
        $dumpfile("tb_spw_datalink_p0.vcd");
        $dumpvars(0, tb_spw_datalink_p0);
    end

    spw_datalink #(
        .RX_FIFO_DEPTH(128), .MAX_CREDIT(56), .CNT_6US(2), .CNT_12US(8)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(link_enable), .i_link_start(link_start),
        .i_auto_start(auto_start), .i_port_reset(port_reset),
        .i_rx_char_commit_evt(rx_char_commit_evt),
        .i_rx_char_data(rx_char_data),
        .i_rx_parity_err_evt(rx_parity_err_evt),
        .i_disconnect_err_evt(disconnect_err_evt),
        .o_tx_enable(tx_enable), .o_rx_enable(rx_enable),
        .o_rx_parity_enable(rx_parity_enable),
        .o_tx_char_valid(tx_char_valid), .o_tx_char_data(tx_char_data),
        .i_tx_char_ready(tx_char_ready),
        .i_tx_char_commit_evt(tx_char_commit_evt),
        .o_link_recovery_evt(link_recovery_evt),
        .i_tx_nchar_data(tx_nchar_data),
        .i_tx_nchar_valid(tx_nchar_valid),
        .o_tx_nchar_accept_evt(tx_nchar_accept_evt),
        .o_rx_nchar_data(rx_nchar_data),
        .o_rx_nchar_commit_evt(rx_nchar_commit_evt),
        .o_rx_nchar_is_ctrl(rx_nchar_is_ctrl),
        .i_rx_fifo_free_count(rx_fifo_free_count),
        .i_tx_timecode_req_evt(tx_timecode_req_evt),
        .i_tx_timecode_data(tx_timecode_data),
        .o_rx_timecode_commit_evt(rx_timecode_commit_evt),
        .o_rx_timecode_data(rx_timecode_data),
        .o_link_state(link_state),
        .o_disconnect_err_evt(disconnect_out),
        .o_parity_err_evt(parity_out),
        .o_esc_err_evt(esc_out),
        .o_credit_err_evt(credit_out)
    );

    // Static task: Icarus does not allow automatic task arguments on the RHS
    // of a procedural force statement.
    task enter_isolated_run(input logic [5:0] tx_credit,
                            input logic [5:0] rx_credit);
        begin
            force dut.r_state = 3'd5;
            force dut.r_tx_credit = tx_credit;
            force dut.r_rx_credit = rx_credit;
            @(negedge clk);
            release dut.r_tx_credit;
            release dut.r_rx_credit;
        end
    endtask

    task leave_isolated_run;
        begin
            release dut.r_state;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // P0-1: simultaneous independent FCT receive (+8) and N-Char
        // acceptance (-1) shall produce one atomic +7 update.
        enter_isolated_run(6'd10, 6'd0);
        rx_fifo_free_count = 0; // suppress local FCT scheduling
        tx_nchar_valid = 1;
        tx_char_ready = 0;
        wait (tx_char_valid && tx_char_data == tx_nchar_data);
        @(negedge clk);
        tx_char_ready = 1;
        rx_char_data = 9'h100; // independent FCT
        rx_char_commit_evt = 1;
        #1;
        if (!dut.tx_credit_inc_evt || !dut.tx_credit_dec_evt)
            $fatal(1, "P0-CREDIT-ATOMIC: simultaneous events not formed");
        @(posedge clk);
        #1;
        if (dut.r_tx_credit !== 6'd17)
            $fatal(1, "P0-CREDIT-ATOMIC: expected 17, got %0d", dut.r_tx_credit);
        @(negedge clk);
        tx_char_ready = 0;
        tx_nchar_valid = 0;
        rx_char_commit_evt = 0;
        leave_isolated_run();

        // P0-2: a parity error in the same cycle as a decoded N-Char shall
        // suppress Network commit and select ErrorReset immediately.
        enter_isolated_run(6'd0, 6'd8);
        @(negedge clk);
        rx_char_data = 9'h041;
        rx_char_commit_evt = 1;
        rx_parity_err_evt = 1;
        #1;
        if (rx_nchar_commit_evt)
            $fatal(1, "P0-ERROR-COMMIT: corrupt N-Char committed");
        if (dut.w_next_state !== 3'd0)
            $fatal(1, "P0-ERROR-COMMIT: ErrorReset not selected");
        @(negedge clk);
        rx_char_commit_evt = 0;
        rx_parity_err_evt = 0;
        leave_isolated_run();

        // P0-3: FCT reserve includes already granted RX credit.
        // With 48 outstanding credits, 55 free slots is insufficient;
        // exactly 56 free slots is sufficient.
        enter_isolated_run(6'd0, 6'd48);
        rx_fifo_free_count = 8'd55;
        #1;
        if (dut.w_fct_send_ok)
            $fatal(1, "P0-FCT-RESERVE: FCT allowed with only 55 free slots");
        rx_fifo_free_count = 8'd56;
        #1;
        if (!dut.w_fct_send_ok)
            $fatal(1, "P0-FCT-RESERVE: FCT blocked with 56 free slots");
        leave_isolated_run();

        $display("PASS tb_spw_datalink_p0");
        $finish;
    end

    initial #20000 $fatal(1, "timeout");
endmodule
