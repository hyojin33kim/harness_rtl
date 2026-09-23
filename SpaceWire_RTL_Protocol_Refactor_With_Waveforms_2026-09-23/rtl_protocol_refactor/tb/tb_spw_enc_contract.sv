`timescale 1ns/1ps

module tb_spw_enc_contract;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [8:0] tx_data;
    logic tx_valid, tx_ready, tx_commit, tx_abort;
    logic ds_data, ds_strobe;
    logic [8:0] rx_data;
    logic rx_commit, parity_err;
    integer commit_count = 0;
    integer rx_count = 0;

    initial begin
        $dumpfile("tb_spw_enc_contract.vcd");
        $dumpvars(0, tb_spw_enc_contract);
    end

    spw_enc #(.CLK_FREQ_HZ(100_000_000), .TX_RATE_MBPS(25)) dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_link_recovery_evt(1'b0),
        .i_tx_enable(1'b1), .i_rx_enable(1'b1), .i_rx_parity_enable(1'b1),
        .i_enc_tx_char(tx_data), .i_enc_tx_valid(tx_valid),
        .o_enc_tx_ready(tx_ready), .o_enc_tx_commit(tx_commit),
        .o_enc_tx_abort(tx_abort),
        .o_enc_rx_char(rx_data), .o_enc_rx_valid(rx_commit),
        .o_enc_parity_error(parity_err),
        .o_tx_ds_data(ds_data), .o_tx_ds_strobe(ds_strobe),
        .i_rx_ds_data(ds_data), .i_rx_ds_strobe(ds_strobe)
    );

    task automatic send_char(input logic [8:0] value);
        begin
            @(negedge clk);
            tx_data = value;
            tx_valid = 1'b1;
            do @(posedge clk); while (!tx_ready);
            @(negedge clk);
            tx_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (tx_commit) commit_count <= commit_count + 1;
        if (tx_abort) $fatal(1, "unexpected TX abort");
        if (parity_err) $fatal(1, "loopback parity error");
        if (rx_commit) begin
            case (rx_count)
                0: if (rx_data !== 9'h103) $fatal(1, "first RX char is not ESC");
                1: if (rx_data !== 9'h100) $fatal(1, "second RX char is not FCT");
                2: if (rx_data !== 9'h103) $fatal(1, "third RX char is not ESC");
                default: ;
            endcase
            rx_count <= rx_count + 1;
        end
    end

    initial begin
        tx_data = 0;
        tx_valid = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        send_char(9'h103); // ESC
        send_char(9'h100); // FCT: first Null
        send_char(9'h103); // next ESC validates prior FCT
        send_char(9'h100);

        wait (commit_count >= 3);
        repeat (20) @(posedge clk);
        if (commit_count < 4) $fatal(1, "missing TX commit events");
        if (rx_count < 3) $fatal(1, "RX did not delay and validate characters");
        $display("PASS tb_spw_enc_contract");
        $finish;
    end

    initial begin
        #10000 $fatal(1, "timeout");
    end
endmodule
