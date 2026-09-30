`timescale 1ns/1ps

// Gate-2 P0 timing check: every D/S bit launch, including a character
// boundary, must remain one configured bit period apart.
module tb_spw_enc_bit_timing;
    localparam int BIT_PERIOD_CYCLES = 4; // 100 MHz / 25 Mbps

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic tx_valid = 0;
    logic tx_ready, tx_commit;
    logic ds_data, ds_strobe;
    logic [8:0] rx_data;
    logic rx_commit, parity_err;
    integer cycle_count = 0;
    integer last_pop_cycle = -1;
    integer pop_count = 0;
    integer commit_count = 0;

    initial begin
        $dumpfile("tb_spw_enc_bit_timing.vcd");
        $dumpvars(0, tb_spw_enc_bit_timing);
    end

    spw_enc #(.CLK_FREQ_HZ(100_000_000), .TX_RATE_MBPS(25)) dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_link_recovery_evt(1'b0),
        .i_tx_enable(1'b1), .i_rx_enable(1'b0),
        .i_rx_parity_enable(1'b0),
        .i_enc_tx_char(9'h100), .i_enc_tx_valid(tx_valid),
        .o_enc_tx_ready(tx_ready), .o_enc_tx_commit(tx_commit),
        .o_enc_tx_abort(),
        .o_enc_rx_char(rx_data), .o_enc_rx_valid(rx_commit),
        .o_enc_parity_error(parity_err),
        .o_tx_ds_data(ds_data), .o_tx_ds_strobe(ds_strobe),
        .i_rx_ds_data(1'b0), .i_rx_ds_strobe(1'b0)
    );

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (rst_n && dut.w_tx_pop) begin
            if (last_pop_cycle >= 0 &&
                    (cycle_count - last_pop_cycle) != BIT_PERIOD_CYCLES)
                $fatal(1,
                    "P0-BIT-GAP: interval=%0d expected=%0d pop=%0d",
                    cycle_count - last_pop_cycle, BIT_PERIOD_CYCLES, pop_count);
            last_pop_cycle = cycle_count;
            pop_count = pop_count + 1;
        end
        if (tx_commit)
            commit_count = commit_count + 1;
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        tx_valid = 1; // continuous FCT stream exercises character boundaries
        wait (commit_count >= 3);
        @(negedge clk);
        tx_valid = 0;
        if (pop_count < 12)
            $fatal(1, "P0-BIT-GAP: insufficient bit launches: %0d", pop_count);
        $display("PASS tb_spw_enc_bit_timing");
        $finish;
    end

    initial #10000 $fatal(1, "timeout");
endmodule
