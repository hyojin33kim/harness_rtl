`timescale 1ns/1ps

module tb_spw_story;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 100 MHz

    logic link_enable = 0, link_start = 0, auto_start = 0, port_reset = 0;
    logic [8:0] host_tx_item = 0;
    logic host_tx_valid = 0, host_tx_ready;
    logic [8:0] host_rx_item;
    logic host_rx_valid, host_rx_ready = 1;
    logic host_tc_req = 0;
    logic [7:0] host_tc_data = 0;
    logic host_rx_tc_evt;
    logic [7:0] host_rx_tc_data;
    logic [2:0] link_state;
    logic err_disconnect, err_parity, err_esc, err_credit;
    logic err_host_tx, err_phy_disconnect;
    logic tx_d, tx_s;
    logic rx_d, rx_s;
    logic [2:0] story_phase; // 0=reset, 1=initialize, 2=flow, 3=error, 4=reconnect

    // -----------------------------------------------------------------
    // Waveform observability layer (TB-only, non-synthesizable intent)
    // Character kind: 0=IDLE, 1=ESC, 2=NULL, 3=FCT, 4=DATA,
    //                 5=EOP, 6=EEP, 7=TIMECODE, F=UNKNOWN/ERROR
    // Serializer role: 0=IDLE, 1=P(arity), 2=C(ontrol flag), 3=D(ata/code)
    // -----------------------------------------------------------------
    localparam logic [3:0] OBS_CHAR_IDLE = 4'h0;
    localparam logic [3:0] OBS_CHAR_ESC  = 4'h1;
    localparam logic [3:0] OBS_CHAR_NULL = 4'h2;
    localparam logic [3:0] OBS_CHAR_FCT  = 4'h3;
    localparam logic [3:0] OBS_CHAR_DATA = 4'h4;
    localparam logic [3:0] OBS_CHAR_EOP  = 4'h5;
    localparam logic [3:0] OBS_CHAR_EEP  = 4'h6;
    localparam logic [3:0] OBS_CHAR_TC   = 4'h7;
    localparam logic [3:0] OBS_CHAR_UNK  = 4'hf;

    localparam logic [1:0] OBS_SER_IDLE = 2'h0;
    localparam logic [1:0] OBS_SER_P    = 2'h1;
    localparam logic [1:0] OBS_SER_C    = 2'h2;
    localparam logic [1:0] OBS_SER_D    = 2'h3;

    logic obs_link_init_active, obs_link_run;
    logic obs_recovery_active, obs_reconnect_active;
    logic obs_seen_run;
    logic obs_error_any_evt;

    logic [3:0] obs_tx_char_kind, obs_rx_char_kind;
    logic [8:0] obs_tx_char_hex, obs_rx_char_hex;
    logic obs_tx_char_evt, obs_rx_char_evt;
    logic obs_tx_is_esc, obs_tx_is_null, obs_tx_is_fct, obs_tx_is_nchar;
    logic obs_rx_is_esc, obs_rx_is_null, obs_rx_is_fct, obs_rx_is_nchar;
    logic [8:0] obs_tx_accepted_char;

    logic obs_ser_bit_evt, obs_ser_bit_value;
    logic [1:0] obs_ser_bit_role;

    logic obs_credit_available, obs_flow_blocked;
    logic [5:0] obs_tx_credit_hex, obs_rx_credit_hex;
    logic [4:0] obs_tx_fifo_level_hex, obs_rx_fifo_level_hex;

    assign rx_d = tx_d;
    assign rx_s = tx_s;

    assign obs_link_init_active = rst_n && !obs_seen_run;
    assign obs_link_run = (link_state == 3'd5);
    assign obs_reconnect_active = obs_recovery_active && !obs_link_run;
    assign obs_error_any_evt = err_disconnect | err_parity | err_esc | err_credit
                             | err_host_tx | err_phy_disconnect;

    assign obs_tx_credit_hex = dut.u_spw_datalink.r_tx_credit;
    assign obs_rx_credit_hex = dut.u_spw_datalink.r_rx_credit;
    assign obs_tx_fifo_level_hex = dut.u_spw_network.r_tx_count;
    assign obs_rx_fifo_level_hex = dut.u_spw_network.r_rx_count;
    assign obs_credit_available = (obs_tx_credit_hex != 6'd0);
    assign obs_flow_blocked = obs_link_run && dut.tx_nchar_valid
                            && !obs_credit_available;

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

    // The raw D/S stream is intentionally not interpreted by eye.  These
    // signals expose the serializer's current P/C/D role at each emitted bit.
    assign obs_ser_bit_evt   = dut.u_spw_enc.w_tx_pop;
    assign obs_ser_bit_value = dut.u_spw_enc.w_tx_next_bit;
    always_comb begin
        obs_ser_bit_role = OBS_SER_IDLE;
        if (obs_ser_bit_evt) begin
            if (dut.u_spw_enc.w_tx_accept_evt)
                obs_ser_bit_role = OBS_SER_P;
            else if ((dut.u_spw_enc.r_tx_bits_left == 4'd9)
                  || (dut.u_spw_enc.r_tx_bits_left == 4'd3))
                obs_ser_bit_role = OBS_SER_C;
            else
                obs_ser_bit_role = OBS_SER_D;
        end
    end

    // Latch the accepted TX character because the Data Link output may move
    // to the next offer before the serializer reports the final-bit commit.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            obs_tx_accepted_char <= 9'd0;
        end else if (dut.tx_char_valid && dut.tx_char_ready) begin
            obs_tx_accepted_char <= dut.tx_char_data;
        end
    end

    // Register semantic events one cycle after the raw commit boundary. This
    // keeps the decoded kind stable for a complete waveform cycle.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            obs_tx_char_evt  <= 1'b0;
            obs_tx_char_kind <= OBS_CHAR_IDLE;
            obs_tx_char_hex  <= 9'd0;
        end else begin
            obs_tx_char_evt <= dut.tx_char_commit_evt;
            if (dut.tx_char_commit_evt) begin
                obs_tx_char_hex <= obs_tx_accepted_char;
                case (dut.u_spw_datalink.r_tx_inflight_kind)
                    3'd1, 3'd2: obs_tx_char_kind <= OBS_CHAR_ESC;
                    3'd3:       obs_tx_char_kind <= OBS_CHAR_NULL;
                    3'd4:       obs_tx_char_kind <= OBS_CHAR_TC;
                    3'd5:       obs_tx_char_kind <= OBS_CHAR_FCT;
                    3'd6: begin
                        if (!obs_tx_accepted_char[8])
                            obs_tx_char_kind <= OBS_CHAR_DATA;
                        else case (obs_tx_accepted_char[1:0])
                            2'b10: obs_tx_char_kind <= OBS_CHAR_EOP;
                            2'b01: obs_tx_char_kind <= OBS_CHAR_EEP;
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

    // RX sequence context is sampled before the Data Link updates its ESC
    // pending state, so NULL and TIMECODE are decoded without ambiguity.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            obs_rx_char_evt  <= 1'b0;
            obs_rx_char_kind <= OBS_CHAR_IDLE;
            obs_rx_char_hex  <= 9'd0;
        end else begin
            obs_rx_char_evt <= dut.rx_char_commit_evt;
            if (dut.rx_char_commit_evt) begin
                obs_rx_char_hex <= dut.rx_char_data;
                if (dut.u_spw_datalink.r_rx_pending_esc) begin
                    if (dut.rx_char_data[8] && dut.rx_char_data[1:0] == 2'b00)
                        obs_rx_char_kind <= OBS_CHAR_NULL;
                    else if (!dut.rx_char_data[8])
                        obs_rx_char_kind <= OBS_CHAR_TC;
                    else
                        obs_rx_char_kind <= OBS_CHAR_UNK;
                end else if (!dut.rx_char_data[8]) begin
                    obs_rx_char_kind <= OBS_CHAR_DATA;
                end else begin
                    case (dut.rx_char_data[1:0])
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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            obs_seen_run <= 1'b0;
            obs_recovery_active <= 1'b0;
        end else begin
            if (obs_link_run)
                obs_seen_run <= 1'b1;
            if (dut.link_recovery_evt)
                obs_recovery_active <= 1'b1;
            else if (obs_link_run)
                obs_recovery_active <= 1'b0;
        end
    end

    spw_top #(
        .CLK_FREQ_HZ(100_000_000),
        .TX_RATE_MBPS(25),
        .DISCONNECT_TIMEOUT_NS(850),
        .TX_FIFO_DEPTH(16),
        .RX_FIFO_DEPTH(16),
        .MAX_CREDIT(56)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_enable(link_enable), .i_link_start(link_start),
        .i_auto_start(auto_start), .i_port_reset(port_reset),
        .i_rx_ds_data_pad(rx_d), .i_rx_ds_strobe_pad(rx_s),
        .o_tx_ds_data_pad(tx_d), .o_tx_ds_strobe_pad(tx_s),
        .i_host_tx_item(host_tx_item), .i_host_tx_valid(host_tx_valid),
        .o_host_tx_ready(host_tx_ready),
        .o_host_rx_item(host_rx_item), .o_host_rx_valid(host_rx_valid),
        .i_host_rx_ready(host_rx_ready),
        .i_host_tx_timecode_req(host_tc_req),
        .i_host_tx_timecode_data(host_tc_data),
        .o_host_rx_timecode_commit_evt(host_rx_tc_evt),
        .o_host_rx_timecode_data(host_rx_tc_data),
        .o_link_state(link_state),
        .o_disconnect_err_evt(err_disconnect), .o_parity_err_evt(err_parity),
        .o_esc_err_evt(err_esc), .o_credit_err_evt(err_credit),
        .o_host_tx_item_err_evt(err_host_tx),
        .o_phy_disconnect_err_evt(err_phy_disconnect)
    );

    task automatic wait_state(input logic [2:0] expected, input integer max_cycles);
        integer n;
        begin
            for (n = 0; n < max_cycles && link_state != expected; n = n + 1)
                @(posedge clk);
            if (link_state != expected)
                $fatal(1, "state timeout: expected=%0d actual=%0d", expected, link_state);
        end
    endtask

    task automatic host_send(input logic [8:0] item);
        begin
            @(negedge clk);
            host_tx_item = item;
            host_tx_valid = 1'b1;
            do @(posedge clk); while (!host_tx_ready);
            @(negedge clk);
            host_tx_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("spw_story.vcd");
        $dumpvars(0, tb_spw_story);
        story_phase = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Story 1: Link initialization
        story_phase = 1;
        link_enable = 1;
        link_start = 1;
        wait_state(3'd5, 10000); // RUN
        repeat (20) @(posedge clk);

        // Story 2: Flow control and N-Char transfer
        story_phase = 2;
        host_send(9'h041);
        host_send(9'h042);
        host_send(9'h043);
        host_send(9'h100); // Host EOP
        repeat (300) @(posedge clk);

        // Story 3: deterministic parity-error recovery trigger.
        // Force is TB-only; it isolates Link recovery behavior from bit corruption details.
        story_phase = 3;
        @(negedge clk);
        force dut.u_spw_enc.or_parity_err = 1'b1;
        @(posedge clk);
        @(negedge clk);
        release dut.u_spw_enc.or_parity_err;
        wait_state(3'd0, 50); // ERROR_RESET

        // Reconnect narrative
        story_phase = 4;
        wait_state(3'd5, 10000);
        repeat (30) @(posedge clk);
        $display("PASS tb_spw_story");
        $finish;
    end

    initial #500_000 $fatal(1, "story timeout");
endmodule
