`timescale 1ns/1ps

module tb_spw_enc_lifecycle;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic recovery = 0;
    logic [8:0] tx_char = '0;
    logic tx_valid = 0;
    logic tx_ready, tx_commit, tx_abort;
    logic ds_data, ds_strobe;

    integer accept_count = 0;
    integer commit_count = 0;
    integer abort_count = 0;
    integer outstanding = 0;
    logic accept_sample;

    spw_enc #(.CLK_FREQ_HZ(100_000_000), .TX_RATE_MBPS(100)) dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_link_recovery_evt(recovery),
        .i_tx_enable(1'b1), .i_rx_enable(1'b0), .i_rx_parity_enable(1'b0),
        .i_enc_tx_char(tx_char), .i_enc_tx_valid(tx_valid),
        .o_enc_tx_ready(tx_ready), .o_enc_tx_commit(tx_commit),
        .o_enc_tx_abort(tx_abort),
        .o_enc_rx_char(), .o_enc_rx_valid(), .o_enc_parity_error(),
        .o_tx_ds_data(ds_data), .o_tx_ds_strobe(ds_strobe),
        .i_rx_ds_data(1'b0), .i_rx_ds_strobe(1'b0)
    );

    // Sample ACCEPT before DUT nonblocking updates, then evaluate completion.
    always begin
        @(posedge clk);
        accept_sample = tx_valid && tx_ready;
        #1;
        if (rst_n) begin
            if (accept_sample) begin
                if (outstanding != 0) $fatal(1, "P2: second accept while active");
                outstanding = 1;
                accept_count = accept_count + 1;
            end
            if (tx_commit) begin
                if (outstanding != 1) $fatal(1, "P3: commit without accepted request");
                outstanding = 0;
                commit_count = commit_count + 1;
            end
            if (tx_abort) begin
                if (outstanding != 1) $fatal(1, "abort without accepted request");
                if (tx_commit) $fatal(1, "commit and abort asserted together");
                outstanding = 0;
                abort_count = abort_count + 1;
            end
        end
    end

    task automatic accept(input logic [8:0] value);
        begin
            @(negedge clk);
            tx_char = value;
            tx_valid = 1'b1;
            do @(posedge clk); while (!tx_ready);
            @(negedge clk);
            tx_valid = 1'b0;
        end
    endtask

    task automatic wait_for_commit(input integer expected);
        begin
            while (commit_count < expected) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_spw_enc_lifecycle.vcd");
        $dumpvars(0, tb_spw_enc_lifecycle);

        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        accept(9'h100); // control: four serialized bits
        wait_for_commit(1);
        accept(9'h05a); // data: ten serialized bits
        wait_for_commit(2);

        accept(9'h0a5); // abort this accepted data character mid-serialization
        repeat (3) @(posedge clk);
        @(negedge clk); recovery = 1'b1;
        @(posedge clk); #1;
        if (!tx_abort) $fatal(1, "P2: active character did not abort on recovery");
        @(negedge clk); recovery = 1'b0;

        repeat (15) @(posedge clk);
        if (accept_count != 3 || commit_count != 2 || abort_count != 1)
            $fatal(1, "P2/P4 lifecycle counts A=%0d C=%0d X=%0d",
                   accept_count, commit_count, abort_count);
        if (outstanding != 0) $fatal(1, "accepted request has no completion");

        $display("PASS tb_spw_enc_lifecycle");
        $finish;
    end

    initial #10000 $fatal(1, "timeout");
endmodule
