`timescale 1ns/1ps

// Same-cycle RX event and ESC-context contract for the extracted decoder.
module tb_spw_rx_decode_contract;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic flush_evt = 0;
    logic [2:0] link_state = 0;
    logic [8:0] rx_char = 0;
    logic valid = 0;
    logic is_ctrl, pending_esc;
    logic got_null, got_fct, got_nchar, got_timecode;
    logic esc_error, protocol_violation;
    logic [7:0] timecode_data;

    spw_datalink_rx_decode dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_flush_evt(flush_evt),
        .i_link_state(link_state), .i_char(rx_char), .i_valid(valid),
        .o_is_ctrl(is_ctrl), .o_pending_esc(pending_esc),
        .o_got_null(got_null), .o_got_fct(got_fct),
        .o_got_nchar(got_nchar), .o_got_timecode(got_timecode),
        .o_esc_error(esc_error), .o_protocol_violation(protocol_violation),
        .o_timecode_data(timecode_data)
    );

    task automatic send_char(input logic [8:0] item);
        begin
            @(negedge clk);
            rx_char = item;
            valid = 1'b1;
            #1;
        end
    endtask

    task automatic finish_char;
        begin
            @(posedge clk); #1;
            @(negedge clk);
            valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("tb_spw_rx_decode_contract.vcd");
        $dumpvars(0, tb_spw_rx_decode_contract);
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        link_state = 3'd3; // STARTED: standalone FCT violates protocol.
        send_char(9'h100);
        if (!protocol_violation || got_fct || pending_esc)
            $fatal(1, "STARTED FCT classification failed");
        finish_char();

        send_char(9'h103); // ESC
        if (got_null || got_nchar || esc_error || protocol_violation)
            $fatal(1, "ESC first half emitted an event");
        finish_char();
        if (!pending_esc) $fatal(1, "ESC pending not stored");

        send_char(9'h100); // ESC + FCT = Null
        if (!got_null || got_fct || esc_error || protocol_violation)
            $fatal(1, "Null completion classification failed");
        finish_char();
        if (pending_esc) $fatal(1, "Null did not clear pending ESC");

        link_state = 3'd5; // RUN
        send_char(9'h103);
        finish_char();
        send_char(9'h055); // ESC + data = Timecode
        if (!got_timecode || got_nchar || esc_error || timecode_data !== 8'h55)
            $fatal(1, "Timecode completion classification failed");
        finish_char();

        send_char(9'h103);
        finish_char();
        send_char(9'h102); // ESC + EOP is invalid.
        if (!esc_error || got_nchar || protocol_violation)
            $fatal(1, "invalid ESC sequence not rejected");
        finish_char();

        link_state = 3'd4; // CONNECTING
        send_char(9'h100);
        if (!got_fct || protocol_violation)
            $fatal(1, "CONNECTING FCT classification failed");
        finish_char();
        send_char(9'h022);
        if (!protocol_violation || got_nchar)
            $fatal(1, "CONNECTING N-Char classification failed");
        finish_char();

        link_state = 3'd5;
        send_char(9'h033);
        if (!got_nchar || protocol_violation)
            $fatal(1, "RUN data classification failed");
        finish_char();

        send_char(9'h103);
        finish_char();
        if (!pending_esc) $fatal(1, "pending ESC missing before flush");
        @(negedge clk); flush_evt = 1'b1;
        @(posedge clk); #1;
        if (pending_esc) $fatal(1, "flush did not clear pending ESC");
        @(negedge clk); flush_evt = 1'b0;

        $display("PASS tb_spw_rx_decode_contract");
        $finish;
    end

    initial #10000 $fatal(1, "RX decode contract timeout");
endmodule
