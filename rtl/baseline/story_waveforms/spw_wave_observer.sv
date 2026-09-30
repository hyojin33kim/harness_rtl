`timescale 1ns/1ps

// TB-only semantic observer for SpaceWire waveform review.
// This module does not drive the DUT and is intentionally excluded from RTL.
module spw_wave_observer (
    input  logic       i_clk,
    input  logic       i_rst_n,
    input  logic [2:0] i_link_state,
    input  logic       i_err_disconnect_evt,
    input  logic       i_err_parity_evt,
    input  logic       i_err_esc_evt,
    input  logic       i_err_credit_evt,
    input  logic       i_err_host_tx_evt,
    input  logic       i_err_phy_disconnect_evt,

    input  logic       i_net_tx_valid,
    input  logic       i_net_tx_ready,
    input  logic       i_net_rx_valid,
    input  logic       i_net_rx_ready,

    input  logic [8:0] i_enc_tx_char,
    input  logic       i_enc_tx_valid,
    input  logic       i_enc_tx_ready,
    input  logic       i_enc_tx_commit_evt,
    input  logic       i_enc_tx_abort_evt,
    input  logic [8:0] i_enc_rx_char,
    input  logic       i_enc_rx_valid,
    input  logic       i_link_recovery_evt,

    input  logic [5:0] i_tx_credit,
    input  logic [5:0] i_rx_credit,
    input  logic [4:0] i_tx_fifo_level,
    input  logic [4:0] i_rx_fifo_level,

    input  logic [2:0] i_tx_inflight_kind,
    input  logic       i_rx_pending_esc,
    input  logic       i_ser_bit_evt,
    input  logic       i_ser_bit_value,
    input  logic       i_ser_accept_evt,
    input  logic [3:0] i_ser_bits_left
);
    // Character kind: 0=IDLE, 1=ESC, 2=NULL, 3=FCT, 4=DATA,
    //                 5=EOP, 6=EEP, 7=TIMECODE, F=UNKNOWN/ERROR.
    localparam logic [3:0] OBS_CHAR_IDLE = 4'h0;
    localparam logic [3:0] OBS_CHAR_ESC  = 4'h1;
    localparam logic [3:0] OBS_CHAR_NULL = 4'h2;
    localparam logic [3:0] OBS_CHAR_FCT  = 4'h3;
    localparam logic [3:0] OBS_CHAR_DATA = 4'h4;
    localparam logic [3:0] OBS_CHAR_EOP  = 4'h5;
    localparam logic [3:0] OBS_CHAR_EEP  = 4'h6;
    localparam logic [3:0] OBS_CHAR_TC   = 4'h7;
    localparam logic [3:0] OBS_CHAR_UNK  = 4'hf;

    // Serializer role: 0=IDLE, 1=P(arity), 2=C(ontrol flag), 3=D(ata/code).
    localparam logic [1:0] OBS_SER_IDLE = 2'h0;
    localparam logic [1:0] OBS_SER_P    = 2'h1;
    localparam logic [1:0] OBS_SER_C    = 2'h2;
    localparam logic [1:0] OBS_SER_D    = 2'h3;

    logic       obs_link_init_active;
    logic       obs_link_run;
    logic       obs_recovery_active;
    logic       obs_reconnect_active;
    logic       obs_seen_run;
    logic       obs_error_any_evt;

    logic [3:0] obs_tx_char_kind;
    logic [3:0] obs_rx_char_kind;
    logic [8:0] obs_tx_char_hex;
    logic [8:0] obs_rx_char_hex;
    logic       obs_tx_char_evt;
    logic       obs_rx_char_evt;
    logic       obs_tx_abort_evt;
    logic       obs_tx_is_esc;
    logic       obs_tx_is_null;
    logic       obs_tx_is_fct;
    logic       obs_tx_is_nchar;
    logic       obs_rx_is_esc;
    logic       obs_rx_is_null;
    logic       obs_rx_is_fct;
    logic       obs_rx_is_nchar;
    logic [8:0] obs_tx_accepted_char;

    logic       obs_net_tx_accept_evt;
    logic       obs_net_rx_accept_evt;
    logic       obs_ser_bit_evt;
    logic       obs_ser_bit_value;
    logic [1:0] obs_ser_bit_role;

    logic       obs_credit_available;
    logic       obs_flow_blocked;
    logic [5:0] obs_tx_credit_hex;
    logic [5:0] obs_rx_credit_hex;
    logic [4:0] obs_tx_fifo_level_hex;
    logic [4:0] obs_rx_fifo_level_hex;

    assign obs_link_run           = (i_link_state == 3'd5);
    assign obs_link_init_active   = i_rst_n && !obs_seen_run;
    assign obs_reconnect_active   = obs_recovery_active && !obs_link_run;
    assign obs_error_any_evt      = i_err_disconnect_evt | i_err_parity_evt
                                  | i_err_esc_evt | i_err_credit_evt
                                  | i_err_host_tx_evt | i_err_phy_disconnect_evt;

    assign obs_tx_credit_hex      = i_tx_credit;
    assign obs_rx_credit_hex      = i_rx_credit;
    assign obs_tx_fifo_level_hex  = i_tx_fifo_level;
    assign obs_rx_fifo_level_hex  = i_rx_fifo_level;
    assign obs_credit_available   = (i_tx_credit != 6'd0);
    assign obs_flow_blocked       = obs_link_run && i_net_tx_valid
                                  && !obs_credit_available;
    assign obs_net_tx_accept_evt  = i_net_tx_valid && i_net_tx_ready;
    assign obs_net_rx_accept_evt  = i_net_rx_valid && i_net_rx_ready;
    assign obs_tx_abort_evt       = i_enc_tx_abort_evt;

    assign obs_tx_is_esc   = obs_tx_char_evt && (obs_tx_char_kind == OBS_CHAR_ESC);
    assign obs_tx_is_null  = obs_tx_char_evt && (obs_tx_char_kind == OBS_CHAR_NULL);
    assign obs_tx_is_fct   = obs_tx_char_evt && (obs_tx_char_kind == OBS_CHAR_FCT);
    assign obs_tx_is_nchar = obs_tx_char_evt && (obs_tx_char_kind >= OBS_CHAR_DATA)
                            && (obs_tx_char_kind <= OBS_CHAR_EEP);
    assign obs_rx_is_esc   = obs_rx_char_evt && (obs_rx_char_kind == OBS_CHAR_ESC);
    assign obs_rx_is_null  = obs_rx_char_evt && (obs_rx_char_kind == OBS_CHAR_NULL);
    assign obs_rx_is_fct   = obs_rx_char_evt && (obs_rx_char_kind == OBS_CHAR_FCT);
    assign obs_rx_is_nchar = obs_rx_char_evt && (obs_rx_char_kind >= OBS_CHAR_DATA)
                            && (obs_rx_char_kind <= OBS_CHAR_EEP);

    // Expose the serializer's current P/C/D role at each emitted D/S bit.
    assign obs_ser_bit_evt   = i_ser_bit_evt;
    assign obs_ser_bit_value = i_ser_bit_value;
    always_comb begin
        obs_ser_bit_role = OBS_SER_IDLE;
        if (i_ser_bit_evt) begin
            if (i_ser_accept_evt)
                obs_ser_bit_role = OBS_SER_P;
            else if ((i_ser_bits_left == 4'd9) || (i_ser_bits_left == 4'd3))
                obs_ser_bit_role = OBS_SER_C;
            else
                obs_ser_bit_role = OBS_SER_D;
        end
    end

    // Latch the accepted character. The Data Link offer may change before
    // the Encoder reports its final-bit commit.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            obs_tx_accepted_char <= 9'd0;
        else if (i_enc_tx_valid && i_enc_tx_ready)
            obs_tx_accepted_char <= i_enc_tx_char;
    end

    // Register semantic events one cycle after the raw commit boundary so
    // kind/data remain stable for a complete waveform cycle.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            obs_tx_char_evt  <= 1'b0;
            obs_tx_char_kind <= OBS_CHAR_IDLE;
            obs_tx_char_hex  <= 9'd0;
        end else begin
            obs_tx_char_evt <= i_enc_tx_commit_evt;
            if (i_enc_tx_commit_evt) begin
                obs_tx_char_hex <= obs_tx_accepted_char;
                case (i_tx_inflight_kind)
                    3'd1, 3'd2: obs_tx_char_kind <= OBS_CHAR_ESC;
                    3'd3:       obs_tx_char_kind <= OBS_CHAR_NULL;
                    3'd4:       obs_tx_char_kind <= OBS_CHAR_TC;
                    3'd5:       obs_tx_char_kind <= OBS_CHAR_FCT;
                    3'd6: begin
                        if (!obs_tx_accepted_char[8])
                            obs_tx_char_kind <= OBS_CHAR_DATA;
                        else case (obs_tx_accepted_char[1:0])
                            2'b10:   obs_tx_char_kind <= OBS_CHAR_EOP;
                            2'b01:   obs_tx_char_kind <= OBS_CHAR_EEP;
                            default: obs_tx_char_kind <= OBS_CHAR_UNK;
                        endcase
                    end
                    default: obs_tx_char_kind <= OBS_CHAR_UNK;
                endcase
            end else begin
                obs_tx_char_kind <= OBS_CHAR_IDLE;
            end
        end
    end

    // Sample the pre-update ESC context to decode NULL and Timecode.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            obs_rx_char_evt  <= 1'b0;
            obs_rx_char_kind <= OBS_CHAR_IDLE;
            obs_rx_char_hex  <= 9'd0;
        end else begin
            obs_rx_char_evt <= i_enc_rx_valid;
            if (i_enc_rx_valid) begin
                obs_rx_char_hex <= i_enc_rx_char;
                if (i_rx_pending_esc) begin
                    if (i_enc_rx_char[8] && i_enc_rx_char[1:0] == 2'b00)
                        obs_rx_char_kind <= OBS_CHAR_NULL;
                    else if (!i_enc_rx_char[8])
                        obs_rx_char_kind <= OBS_CHAR_TC;
                    else
                        obs_rx_char_kind <= OBS_CHAR_UNK;
                end else if (!i_enc_rx_char[8]) begin
                    obs_rx_char_kind <= OBS_CHAR_DATA;
                end else begin
                    case (i_enc_rx_char[1:0])
                        2'b00: obs_rx_char_kind <= OBS_CHAR_FCT;
                        2'b01: obs_rx_char_kind <= OBS_CHAR_EEP;
                        2'b10: obs_rx_char_kind <= OBS_CHAR_EOP;
                        2'b11: obs_rx_char_kind <= OBS_CHAR_ESC;
                    endcase
                end
            end else begin
                obs_rx_char_kind <= OBS_CHAR_IDLE;
            end
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            obs_seen_run        <= 1'b0;
            obs_recovery_active <= 1'b0;
        end else begin
            if (obs_link_run)
                obs_seen_run <= 1'b1;
            if (i_link_recovery_evt)
                obs_recovery_active <= 1'b1;
            else if (obs_link_run)
                obs_recovery_active <= 1'b0;
        end
    end
endmodule
