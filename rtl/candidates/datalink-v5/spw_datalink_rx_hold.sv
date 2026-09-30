// One-entry, physically unstalled Encoder RX event to Network transaction.
// The Data Link parent owns protocol decode/error priority. This block owns
// only capture, held-valid delivery, and blocked-overwrite detection.
module spw_datalink_rx_hold (
    // Clock / hardware reset
    input  logic       i_clk,
    input  logic       i_rst_n,

    // RX data I/F
    input  logic [8:0] i_char,
    output logic [8:0] o_data,
    output logic       o_valid,
    input  logic       i_net_ready,

    // RX control I/F
    input  logic       i_nchar_evt,
    input  logic       i_is_ctrl,
    input  logic       i_error_now,
    input  logic       i_flush_evt,
    output logic       o_is_ctrl
);
    logic w_source_evt;
    logic w_accept_evt;
    logic w_overflow_evt;

    assign w_source_evt   = i_nchar_evt && !i_error_now;
    assign w_accept_evt   = o_valid && i_net_ready;
    assign w_overflow_evt = w_source_evt && o_valid && !i_net_ready;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_valid   <= 1'b0;
            o_data    <= 9'd0;
            o_is_ctrl <= 1'b0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (i_flush_evt) begin
                o_valid   <= 1'b0;
                o_data    <= 9'd0;
                o_is_ctrl <= 1'b0;
            end else if (w_source_evt) begin
                if (!o_valid || i_net_ready) begin
                    o_valid   <= 1'b1;
                    o_data    <= i_char;
                    o_is_ctrl <= i_is_ctrl;
                end
            end else if (w_accept_evt) begin
                o_valid <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    logic       a_net_rx_stalled;
    logic [8:0] a_net_rx_data;
    logic       a_net_rx_ctrl;

    always @(posedge i_clk) begin
        if (i_rst_n && w_overflow_evt)
            $error("NET_RX overflow: physical N-Char arrived while holding register stalled");
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            a_net_rx_stalled <= 1'b0;
            a_net_rx_data    <= 9'd0;
            a_net_rx_ctrl    <= 1'b0;
        end else begin
            if (a_net_rx_stalled) begin
                if (!o_valid || o_data !== a_net_rx_data
                        || o_is_ctrl !== a_net_rx_ctrl)
                    $error("P11: Network RX transaction changed while stalled");
            end
            a_net_rx_stalled <= o_valid && !i_net_ready;
            if (o_valid && !i_net_ready) begin
                a_net_rx_data <= o_data;
                a_net_rx_ctrl <= o_is_ctrl;
            end
        end
    end
`endif
endmodule
