    // =========================================================================
    // §6 수신 ESC 처리 FSM + §9.3 protocol violation + §9.5 ESC 수신 에러
    // =========================================================================
    // spw_enc.sv 실제 9비트 문자 포맷 기준
    // spw_enc 포맷과 불일치 — flag는 [8] 하나, code는 [1:0]에 있음. 아래는 그 실제
    // 포맷대로 재작성):
    //   i_enc_rx_char[8]   = flag (1=control, 0=data)
    //   i_enc_rx_char[1:0] = control code, FCT=00 EOP=10 EEP=01 ESC=11 (spw_enc.sv 헤더/
    //                    ERRATA-7 근거)
    //
    // 참조 모델 SpWLink.on_char() 대응. 순서 중요:
    //   1) r_rx_pending_esc=1 이면 이번 문자가 ESC 의 두 번째 문자
    //   2) 그 외, 이번 문자 자체가 ESC 이면 pending 진입 (FF 에서 처리, 여기선 판정만)
    //   3) 그 외에는 상태별 protocol_violation 검사 후 FCT/N-Char 판정
    logic w_is_ctrl, w_is_esc, w_is_fct, w_is_nchar_ctrl;
    assign w_is_ctrl       = i_enc_rx_char[8];
    assign w_is_esc        = w_is_ctrl && (i_enc_rx_char[1:0] == 2'b11);
    assign w_is_fct        = w_is_ctrl && (i_enc_rx_char[1:0] == 2'b00);
    assign w_is_nchar_ctrl = w_is_ctrl && (i_enc_rx_char[1:0] == 2'b10 || i_enc_rx_char[1:0] == 2'b01); // EOP/EEP

    always_comb begin
        w_got_null           = 1'b0;
        w_got_fct             = 1'b0;
        w_got_nchar           = 1'b0;
        w_got_timecode        = 1'b0;
        w_esc_error           = 1'b0;
        w_protocol_violation  = 1'b0;

        if (i_enc_rx_valid) begin
            if (r_rx_pending_esc) begin
                // ── ESC 의 두 번째 문자 ────────────────────────────
                if (w_is_fct) begin
                    w_got_null = 1'b1;              // ESC+FCT = Null 완성
                end else if (!w_is_ctrl) begin
                    w_got_timecode = 1'b1;           // ESC+DATA = Timecode 완성
                end else begin
                    w_esc_error = 1'b1;              // ESC+ (EOP/EEP/ESC) = 표준 위반
                end
                // Null/Timecode 자체는 protocol_violation 대상이 아님(참조 모델과 동일 —
                // on_char() 의 protocol_violation 검사는 pending_esc 분기 밖에서만 수행됨)

            end else if (w_is_esc) begin
                // ESC 시작 — 판정은 다음 문자까지 보류 (r_rx_pending_esc FF 에서 SET)

            end else begin
                // ── 첫 번째 문자 (ESC 아님) ────────────────────────
                // ECSS 5.5.7.2/.3/.4/.5: ErrorReset/ErrorWait/Ready/Started 에서
                // 순수 FCT 또는 N-Char(DATA/EOP/EEP) 수신 시 protocol_violation.
                // ECSS 5.5.7.6: Connecting 에서는 N-Char(DATA/EOP/EEP) 만 위반
                // (FCT 수신은 gotFCT 조건 자체이므로 정상).
                if (r_state == ST_ERROR_RESET || r_state == ST_ERROR_WAIT
                        || r_state == ST_READY || r_state == ST_STARTED) begin
                    if (w_is_fct || !w_is_ctrl || w_is_nchar_ctrl) begin
                        w_protocol_violation = 1'b1;
                    end
                end else if (r_state == ST_CONNECTING) begin
                    if (!w_is_ctrl || w_is_nchar_ctrl) begin
                        w_protocol_violation = 1'b1;   // N-Char만 위반, FCT는 정상(gotFCT)
                    end else if (w_is_fct) begin
                        w_got_fct = 1'b1;
                    end
                end else begin
                    // ST_RUN (그 외 상태는 이 분기에 도달하지 않음)
                    if (w_is_fct) begin
                        w_got_fct = 1'b1;
                    end else begin
                        w_got_nchar = 1'b1;             // DATA 또는 EOP/EEP
                    end
                end
            end
        end
    end

    // ── FF: r_rx_pending_esc ─────────────────────────────────────
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_pending_esc <= 1'b0;
        end else if (w_entering_error_reset) begin
            r_rx_pending_esc <= 1'b0;           // ErrorReset 진입 시 강제 clear (§9.1)
        end else if (i_enc_rx_valid) begin
            if (!r_rx_pending_esc && w_is_esc) begin
                r_rx_pending_esc <= 1'b1;       // ESC 수신 → pending
            end else begin
                r_rx_pending_esc <= 1'b0;       // 두 번째 문자 수신 완료(또는 최초부터 비ESC)
            end
        end
    end

    // ── Timecode 값 추출 (§6, w_got_timecode=1 인 클럭에 즉시 출력) ──
    assign o_rx_timecode_commit_evt  = w_got_timecode;
    assign o_rx_timecode_data  = i_enc_rx_char[7:0];

    // One-entry physical-event buffer now owns its state and P11 checks.
    spw_datalink_rx_hold u_rx_hold (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_flush_evt(w_entering_error_reset),
        .i_error_now(w_immediate_error),
        .i_nchar_evt(w_got_nchar),
        .i_char(i_enc_rx_char), .i_is_ctrl(w_is_ctrl),
        .i_net_ready(i_net_rx_ready),
        .o_valid(w_net_rx_hold_valid),
        .o_data(o_net_rx_data), .o_is_ctrl(o_net_rx_is_ctrl)
    );
    assign o_net_rx_valid   = w_net_rx_hold_valid;
