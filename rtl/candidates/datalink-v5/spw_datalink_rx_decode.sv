// SpaceWire Data Link RX character semantics and ESC sequence state.
// The parent owns Link FSM and error precedence. Outputs are same-cycle
// events; only the ESC-pending context is registered here.
module spw_datalink_rx_decode (
    // Clock / hardware reset
    input  logic       i_clk,
    input  logic       i_rst_n,

    // RX data I/F
    input  logic [8:0] i_char,
    input  logic       i_valid,
    output logic [7:0] o_timecode_data,

    // RX control I/F
    input  logic       i_flush_evt,
    input  logic [2:0] i_link_state,
    output logic       o_is_ctrl,
    output logic       o_pending_esc,
    output logic       o_got_null,
    output logic       o_got_fct,
    output logic       o_got_nchar,
    output logic       o_got_timecode,
    output logic       o_esc_error,
    output logic       o_protocol_violation
);
    localparam logic [2:0]
        ST_ERROR_RESET = 3'd0,
        ST_ERROR_WAIT  = 3'd1,
        ST_READY       = 3'd2,
        ST_STARTED     = 3'd3,
        ST_CONNECTING  = 3'd4;

    logic w_is_esc, w_is_fct, w_is_nchar_ctrl;
    assign o_is_ctrl       = i_char[8];
    assign w_is_esc        = o_is_ctrl && (i_char[1:0] == 2'b11);
    assign w_is_fct        = o_is_ctrl && (i_char[1:0] == 2'b00);
    assign w_is_nchar_ctrl = o_is_ctrl && (i_char[1:0] == 2'b10 || i_char[1:0] == 2'b01);
    assign o_timecode_data = i_char[7:0];

    always_comb begin
        o_got_null           = 1'b0;
        o_got_fct            = 1'b0;
        o_got_nchar          = 1'b0;
        o_got_timecode       = 1'b0;
        o_esc_error          = 1'b0;
        o_protocol_violation = 1'b0;

        if (i_valid) begin
            if (o_pending_esc) begin
                if (w_is_fct) begin
                    o_got_null = 1'b1;
                end else if (!o_is_ctrl) begin
                    o_got_timecode = 1'b1;
                end else begin
                    o_esc_error = 1'b1;
                end
            end else if (w_is_esc) begin
                // Wait for the required second character.
            end else begin
                if (i_link_state == ST_ERROR_RESET || i_link_state == ST_ERROR_WAIT
                        || i_link_state == ST_READY || i_link_state == ST_STARTED) begin
                    if (w_is_fct || !o_is_ctrl || w_is_nchar_ctrl)
                        o_protocol_violation = 1'b1;
                end else if (i_link_state == ST_CONNECTING) begin
                    if (!o_is_ctrl || w_is_nchar_ctrl)
                        o_protocol_violation = 1'b1;
                    else if (w_is_fct)
                        o_got_fct = 1'b1;
                end else begin
                    if (w_is_fct)
                        o_got_fct = 1'b1;
                    else
                        o_got_nchar = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_pending_esc <= 1'b0;
        end else begin
            // Clocked branch: synchronous flush precedes RX event update.
            if (i_flush_evt) begin
                o_pending_esc <= 1'b0;
            end else if (i_valid) begin
                if (!o_pending_esc && w_is_esc)
                    o_pending_esc <= 1'b1;
                else
                    o_pending_esc <= 1'b0;
            end
        end
    end
endmodule
