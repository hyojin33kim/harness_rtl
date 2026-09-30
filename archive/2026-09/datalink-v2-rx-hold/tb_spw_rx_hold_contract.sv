`timescale 1ns/1ps

// Direct contract test for the extracted Network RX holding boundary.
module tb_spw_rx_hold_contract;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic flush_evt = 0;
    logic error_now = 0;
    logic nchar_evt = 0;
    logic [8:0] rx_char = 0;
    logic is_ctrl = 0;
    logic net_ready = 0;
    logic valid;
    logic [8:0] data;
    logic ctrl;

    spw_datalink_rx_hold dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_flush_evt(flush_evt), .i_error_now(error_now),
        .i_nchar_evt(nchar_evt), .i_char(rx_char), .i_is_ctrl(is_ctrl),
        .i_net_ready(net_ready), .o_valid(valid),
        .o_data(data), .o_is_ctrl(ctrl)
    );

    initial begin
        $dumpfile("tb_spw_rx_hold_contract.vcd");
        $dumpvars(0, tb_spw_rx_hold_contract);
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        // Capture an unstalled physical event; hold through Network stall.
        @(negedge clk);
        rx_char = 9'h055;
        nchar_evt = 1'b1;
        @(posedge clk); #1;
        if (!valid || data !== 9'h055 || ctrl)
            $fatal(1, "initial capture failed");
        @(negedge clk); nchar_evt = 1'b0; rx_char = 9'h066;
        repeat (2) begin
            @(posedge clk); #1;
            if (!valid || data !== 9'h055 || ctrl)
                $fatal(1, "held payload changed during stall");
        end

        // Full pop plus new event replaces the old item on one edge.
        @(negedge clk);
        net_ready = 1'b1;
        nchar_evt = 1'b1;
        rx_char = 9'h102;
        is_ctrl = 1'b1;
        if (!valid || data !== 9'h055)
            $fatal(1, "old item not presented at accept edge");
        @(posedge clk); #1;
        if (!valid || data !== 9'h102 || !ctrl)
            $fatal(1, "same-cycle replacement failed");

        // A same-cycle error suppresses a new physical event.
        @(negedge clk);
        net_ready = 1'b0;
        nchar_evt = 1'b1;
        error_now = 1'b1;
        rx_char = 9'h077;
        @(posedge clk); #1;
        if (!valid || data !== 9'h102 || !ctrl)
            $fatal(1, "error did not suppress capture");

        // Flush has priority over an otherwise valid replacement event.
        @(negedge clk);
        net_ready = 1'b1;
        error_now = 1'b0;
        flush_evt = 1'b1;
        @(posedge clk); #1;
        if (valid || data !== 9'd0 || ctrl)
            $fatal(1, "flush priority failed");

        @(negedge clk);
        flush_evt = 1'b0;
        nchar_evt = 1'b0;
        @(posedge clk); #1;
        if (valid)
            $fatal(1, "flushed item reappeared");

        $display("PASS tb_spw_rx_hold_contract");
        $finish;
    end

    initial #10000 $fatal(1, "RX hold contract timeout");
endmodule
