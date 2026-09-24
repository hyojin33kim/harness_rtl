    // =========================================================================
    // §3.2 공통 즉시 ErrorReset 조건
    // =========================================================================
    // 참조 모델 SpWLink.tick() 의 immediate_error 대응.
    // 주의: golden model 의 immediate_error 목록에는 disconnect/parity_error/
    // esc_error/protocol_violation/(RUN&&credit_error) 도 포함되지만, 그 신호들은
    // §5~§9 (credit/ESC/protocol_violation)에서 정의된다. 이 섹션(§3.3)에서는
    // 우선 !i_link_enable 만 즉시 조건으로 다루고, 나머지 즉시 에러는 §3.3 상태별
    // 전이 표에 개별 행으로 반영되어 있으므로 w_next_state comb 에서 함께 합류된다.
    logic w_immediate_error;
    assign w_immediate_error = (!i_link_enable) | i_disconnect_err_evt | i_enc_parity_error
                              | w_esc_error | w_protocol_violation
                              | (r_state == ST_RUN & w_credit_err);
    // ※ w_esc_error/w_protocol_violation/w_credit_err 는 각각 §6/§9.3/§5.1 에서
    //   정의될 예정. 지금은 §5~§9 미구현이라 항상 0으로 뜨므로, 이 FSM 단독으로는
    //   !i_link_enable 조건만 실제로 동작한다 (다음 단계에서 각 섹션 구현 시 자동 합류).

    // =========================================================================
    // §3.3 상태 전이 comb (w_next_state)
    // =========================================================================
    // 우선순위: (1) i_port_reset 동기 리셋 → 즉시 ErrorReset
    //           (2) w_immediate_error → 즉시 ErrorReset (그 상태에 계속 머묾)
    //           (3) 상태별 정상/에러 전이 조건 (guide §3.3 표)
    always_comb begin
        w_next_state = r_state;  // 기본값: 유지

        if (i_port_reset) begin
            w_next_state = ST_ERROR_RESET;
        end else if (w_immediate_error) begin
            w_next_state = ST_ERROR_RESET;
        end else begin
            unique case (r_state)
                ST_ERROR_RESET: begin
                    // ERRATA-1: ErrorReset은 CNT_6US
                    if (r_timer_cnt >= TIMER_W'(CNT_6US)) begin
                        w_next_state = ST_ERROR_WAIT;
                    end
                end

                ST_ERROR_WAIT: begin
                    // ERRATA-3: 순수 FCT 또는 N-Char 수신 시 즉시 ErrorReset
                    if (w_got_fct || w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if (r_timer_cnt >= TIMER_W'(CNT_12US)) begin
                        // ERRATA-1: ErrorWait은 CNT_12US
                        w_next_state = ST_READY;
                    end
                end

                ST_READY: begin
                    // ERRATA-3: Ready 에서도 순수 FCT/N-Char 수신 시 ErrorReset
                    if (w_got_fct || w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if (i_link_start || (i_auto_start && r_null_seen)) begin
                        // gotNull 선수신 필수 [P3-1] — auto_start 만으로는 부족
                        w_next_state = ST_STARTED;
                    end
                end

                ST_STARTED: begin
                    // ERRATA-3: 순수 FCT/N-Char 수신 시 ErrorReset (Null 완성 전)
                    if (w_got_fct || w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if ((r_null_seen || w_got_null)
                              && (r_sent_null || w_tx_null_fct_commit_evt)) begin
                        // Rev.1 requires both Sent Null and gotNull.
                        w_next_state = ST_CONNECTING;
                    end else if (r_timer_cnt >= TIMER_W'(CNT_12US)) begin
                        w_next_state = ST_ERROR_RESET;  // gotNull 없이 타임아웃
                    end
                end

                ST_CONNECTING: begin
                    // ERRATA-2: N-Char(DATA/EOP/EEP) 수신은 여기서 protocol violation
                    if (w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if ((r_got_fct || w_got_fct) && r_sent_fct) begin
                        // "gotFCT AND SentFCT" 만 Run 진입 조건 (gotNull/gotNChar 불포함).
                        // r_got_fct(래치) 뿐 아니라 같은 클럭에 막 도착한 w_got_fct 도
                        // 즉시 반영 — golden model 이 on_char()(수신 처리)를 tick()
                        // (전이 판단)보다 먼저 같은 클럭에서 실행하는 것과 동치.
                        w_next_state = ST_RUN;
                    end else if (r_timer_cnt >= TIMER_W'(CNT_12US)) begin
                        w_next_state = ST_ERROR_RESET;  // 조건 미달 타임아웃
                    end
                end

                ST_RUN: begin
                    // guide §3.3 표기 "r_got_null"은 오타/구용어로 판단 — §4/§12
                    // 대응표 기준 실제 레지스터명은 r_null_seen 이다 (미결 #5:
                    // "gotNull 래치 기반 판정"의 상태 기반 근사 대상).
                    //
                    // 단, RUN 도달 조건(Started→Connecting에 w_got_null 필수, §3.3)상
                    // RUN 상태에서는 r_null_seen 이 항상 1 이므로, 이 항은
                    // w_immediate_error 의 i_rx_parity_err_evt 단독 조건과 결과적으로 동치다.
                    // golden model(SpWLink.tick() 600행)도 parity_error 를
                    // null_seen 과 무관하게 단독 immediate_error 조건으로 둔다 —
                    // 즉 이 표의 "ERRATA-6 근사" 항은 이미 w_immediate_error 에
                    // 포함되어 실질적으로 중복이다. 명시성을 위해 남겨두되 실제
                    // 판단은 w_immediate_error 가 전담한다.
                    if (i_enc_parity_error && r_null_seen) begin
                        w_next_state = ST_ERROR_RESET;
                    end
                    // 나머지(disconnect/esc_error/credit_err)는 w_immediate_error 로 커버.
                end

                default: w_next_state = ST_ERROR_RESET;
            endcase
        end
    end

    assign w_entering_error_reset = (w_next_state == ST_ERROR_RESET)
                                   & (r_state     != ST_ERROR_RESET);

    // =========================================================================
    // r_state FF: async hardware reset; clocked next-state includes protocol reset
    // =========================================================================
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state <= ST_ERROR_RESET;
        end else begin
            r_state <= w_next_state;
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_sent_null <= 1'b0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_next_state == ST_ERROR_RESET || w_entering_connecting) begin
                r_sent_null <= 1'b0;
            end else if (r_state == ST_STARTED && w_tx_null_fct_commit_evt) begin
                r_sent_null <= 1'b1;
            end
        end
    end

    // =========================================================================
    // §3.4 타이머 (r_timer_cnt, r_timer_expired)
    // =========================================================================
    // 상태가 바뀌면 타이머를 0부터 새로 계수(sync reset).
    // 상태가 유지되더라도 w_immediate_error(또는 port_reset)로 ErrorReset에
    // "붙들려" 있는 동안에는 진행하지 않는다 — golden model SpWLink.tick()의
    // immediate_error 분기가 timer += 1 자체를 건너뛰는 것과 동일한 동작.
    // (이게 없으면 !i_link_enable 이 오래 지속되다 해제되는 순간 타이머가 이미
    //  CNT_6US 를 넘겨 즉시 ErrorWait 로 튀는 버그가 생김.)
    assign w_timer_sync_rst = (w_next_state != r_state);
    logic w_timer_hold;
    assign w_timer_hold = (r_state == ST_ERROR_RESET) && (i_port_reset || w_immediate_error);

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_timer_cnt <= '0;
        end else begin
            // Synchronous timer reset and counter update.
            if (w_timer_sync_rst) begin
                r_timer_cnt <= '0;
            end else if (!w_timer_hold) begin
                if (r_timer_cnt < TIMER_W'(TIMER_MAX))
                    r_timer_cnt <= r_timer_cnt + 1'b1;
            end
            // w_timer_hold 인 동안은 카운트 정지 (golden model 과 동일)
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_timer_expired <= 1'b0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_timer_sync_rst) begin
                r_timer_expired <= 1'b0;
            end else begin
                unique case (r_state)
                    ST_ERROR_RESET: r_timer_expired <= (r_timer_cnt >= TIMER_W'(CNT_6US));
                    ST_ERROR_WAIT,
                    ST_STARTED,
                    ST_CONNECTING: r_timer_expired <= (r_timer_cnt >= TIMER_W'(CNT_12US));
                    default:       r_timer_expired <= 1'b0;
                endcase
            end
        end
    end

    // =========================================================================
    // §3.5 Connecting → Run 전이 보조 래치 (r_got_fct, r_sent_fct)
    // =========================================================================
    // golden model SpWLink._enter(): 상태 전이마다 _fct_seen(=r_got_fct) 은 항상
    // 클리어, _fct_sent_in_connecting(=r_sent_fct) 은 CONNECTING 진입 시에만
    // False로 초기화. local FCT는 request가 아니라 wire COMMIT에서 인정한다.
    logic w_entering_connecting;
    assign w_entering_connecting = (w_next_state == ST_CONNECTING) && (r_state != ST_CONNECTING);

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_got_fct <= 1'b0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_next_state != r_state) begin
                // 모든 상태 전이(진입 포함)에서 클리어 — Connecting 진입 후 새로
                // 수신하는 FCT만 유효해야 함 (§3.5)
                r_got_fct <= 1'b0;
            end else if (r_state == ST_CONNECTING && w_got_fct) begin
                r_got_fct <= 1'b1;
            end
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_sent_fct <= 1'b0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_entering_connecting) begin
                r_sent_fct <= 1'b0;
            end else if (r_state == ST_CONNECTING && w_tx_fct_commit_evt) begin
                r_sent_fct <= 1'b1;
            end
        end
    end

    // =========================================================================
    // r_null_seen (auto_start 조건 — Ready 이후 Null 수신 이력)
    // =========================================================================
    // ECSS 5.4.6(b): gotNull is cleared only when RX Enable is de-asserted.
    // State transitions among ErrorWait/Ready/Started/Connecting/Run therefore
    // preserve it; entering ErrorReset clears it.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_null_seen <= 1'b0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_next_state == ST_ERROR_RESET) begin
                r_null_seen <= 1'b0;
            end else if (w_got_null) begin
                r_null_seen <= 1'b1;
            end
        end
    end

    // =========================================================================
    // o_link_state 출력
    // =========================================================================
    assign o_link_state = r_state;
    assign o_tx_enable = (r_state == ST_STARTED) || (r_state == ST_CONNECTING)
                       || (r_state == ST_RUN);
    assign o_rx_enable = (r_state != ST_ERROR_RESET);
    assign o_rx_parity_enable = o_rx_enable && r_null_seen;
