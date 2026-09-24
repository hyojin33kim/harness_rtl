`timescale 1ns/1ps
module tb_spw_credit_contract;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, credit_rst = 0;
    logic [2:0] state = 3'd4;
    logic enter_cn = 0, got_fct = 0, got_nchar = 0;
    logic nchar_commit = 0, fct_commit = 0, hold_valid = 0;
    logic [7:0] free_count = 8'd128;
    wire [5:0] tx_credit, rx_credit;
    wire [2:0] initial_fct;
    wire credit_err, fct_send_ok;
    spw_datalink_credit dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_credit_sync_rst(credit_rst),
        .i_link_state(state), .i_entering_connecting(enter_cn),
        .i_got_fct(got_fct), .i_got_nchar(got_nchar),
        .i_tx_nchar_commit_evt(nchar_commit), .i_tx_fct_commit_evt(fct_commit),
        .i_rx_fifo_free_count(free_count), .i_rx_hold_valid(hold_valid),
        .o_tx_credit(tx_credit), .o_rx_credit(rx_credit),
        .o_req_initial_fct(initial_fct), .o_credit_err(credit_err),
        .o_fct_send_ok(fct_send_ok)
    );
    task automatic tick;
        @(posedge clk); #1;
    endtask
    initial begin
        $dumpfile("tb_spw_credit_contract.vcd");
        $dumpvars(0, tb_spw_credit_contract);
        tick();
        rst_n = 1;
        enter_cn = 1;
        tick();
        enter_cn = 0;
        if (initial_fct !== 3'd7 || tx_credit !== 0 || rx_credit !== 0)
            $fatal(1, "reset/initial FCT count");
        got_fct = 1;
        tick();
        got_fct = 0;
        if (tx_credit !== 6'd8) $fatal(1, "received FCT +8");
        state = 3'd5;
        got_fct = 1;
        nchar_commit = 1;
        tick();
        got_fct = 0;
        nchar_commit = 0;
        if (tx_credit !== 6'd15) $fatal(1, "atomic +8/-1 must be +7");
        fct_commit = 1;
        tick();
        fct_commit = 0;
        if (rx_credit !== 6'd8 || initial_fct !== 3'd6)
            $fatal(1, "independent FCT commit");
        got_nchar = 1;
        tick();
        got_nchar = 0;
        if (rx_credit !== 6'd7) $fatal(1, "N-Char consumes RX credit");
        free_count = 8'd15;
        hold_valid = 1;
        #1;
        if (fct_send_ok !== 1'b0) $fatal(1, "hold reserve must block FCT");
        hold_valid = 0;
        #1;
        if (fct_send_ok !== 1'b1) $fatal(1, "released reserve permits FCT");
        force dut.r_tx_credit = 6'd56;
        got_fct = 1;
        #1;
        if (credit_err !== 1'b1) $fatal(1, "TX overflow immediate error");
        got_fct = 0;
        release dut.r_tx_credit;
        credit_rst = 1;
        tick();
        credit_rst = 0;
        if (tx_credit !== 0 || rx_credit !== 0)
            $fatal(1, "credit synchronous reset");
        got_nchar = 1;
        #1;
        if (credit_err !== 1'b1) $fatal(1, "RX underflow immediate error");
        got_nchar = 0;
        $display("PASS tb_spw_credit_contract");
        $finish;
    end
endmodule
