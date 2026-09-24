    // =========================================================================
    // §8.2 Timecode 래치 (r_tc_pending, r_tc_value)
    // =========================================================================
    // 미결 #4 (해소, ERRATA-19): RUN 이전 도착한 i_tx_timecode_req_evt 은 래치하지 않고
    // discard. golden model 의 deque(maxlen=1) 큐잉이 버그였고, 이 RTL(선택 A)
    // 이 원래 정확했다는 게 v4/v5 에서 확정됨.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tc_pending <= 1'b0;
            r_tc_value   <= 8'd0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_entering_error_reset) begin
                r_tc_pending <= 1'b0;   // ErrorReset 진입 시 폐기 (§9.1)
                r_tc_value   <= 8'd0;
            end else if (i_tx_timecode_req_evt && r_state == ST_RUN) begin
                // 새 Timecode 요청 — drop-old 정책 (참조 모델 deque(maxlen=1) 동작과
                // 동일한 "최신값으로 덮어쓰기". RUN 이전 도착은 이 조건 자체가
                // 거짓이라 자동으로 discard 됨(ERRATA-19).
                r_tc_pending <= 1'b1;
                r_tc_value   <= i_tx_timecode_data;
            end else if (w_tx_bc_esc_accept_evt) begin
                // Broadcast ESC ownership moved to Encoder; retain payload in
                // r_bc_value while a newer host request may occupy r_tc_value.
                r_tc_pending <= 1'b0;
            end
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_bc_value <= 8'd0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_entering_error_reset) begin
                r_bc_value <= 8'd0;
            end else if (w_tx_bc_esc_accept_evt) begin
                r_bc_value <= r_tc_value;
            end
        end
    end

    // =========================================================================
    // §8.3 송신 우선순위 결정 (comb) + §8.1 ESC 원자적 시퀀스 TX 구조
    // =========================================================================
    typedef enum logic [2:0] {
        TXK_NONE        = 3'd0,
        TXK_NULL_ESC    = 3'd1,
        TXK_BC_ESC      = 3'd2,
        TXK_NULL_FCT    = 3'd3,
        TXK_BC_DATA     = 3'd4,
        TXK_FCT         = 3'd5,
        TXK_NCHAR       = 3'd6
    } tx_kind_e;

    logic     w_tx_candidate_valid;
    logic [8:0] w_tx_candidate_data;
    tx_kind_e w_tx_candidate_kind;
    logic     r_tx_req_valid;
    logic [8:0] r_tx_req_char;
    tx_kind_e r_tx_req_kind;
    tx_kind_e r_tx_inflight_kind;

    // 우선순위 (RUN): ESC 시퀀스 진행중(최우선) > Timecode > FCT > N-Char > Null(유휴)
    // 우선순위 (CONNECTING): 초기 FCT > 일반 FCT > Null
    // STARTED: Null 만 (850ns 타임아웃 방지)
    // ErrorReset/ErrorWait/Ready: 아무것도 송신 안 함 (ECSS 5.5.7.4.a.1, DECISION-14)
    always_comb begin
        w_tx_candidate_valid = 1'b0;
        w_tx_candidate_data  = 9'b0;
        w_tx_candidate_kind  = TXK_NONE;

        // ── 최우선: ESC 원자적 시퀀스 진행 중 (두 번째 문자 완성) ──
        if (r_esc_pending) begin
            w_tx_candidate_valid = 1'b1;
            if (r_esc_kind == 1'b0) begin
                w_tx_candidate_data = {1'b1, 6'b0, 2'b00};
                w_tx_candidate_kind = TXK_NULL_FCT;
            end else begin
                w_tx_candidate_data = {1'b0, r_bc_value};
                w_tx_candidate_kind = TXK_BC_DATA;
            end

        end else if (r_state == ST_RUN) begin
            // ── RUN 상태 ─────────────────────────────────────────
            // 1순위: Timecode ESC (ECSS 5.5.6 — Broadcast code 최우선)
            if (r_tc_pending) begin
                w_tx_candidate_valid = 1'b1;
                w_tx_candidate_data  = {1'b1, 6'b0, 2'b11};
                w_tx_candidate_kind  = TXK_BC_ESC;

            // 2순위: FCT 요청 (독립 FCT)
            end else if (w_fct_send_ok) begin
                w_tx_candidate_valid = 1'b1;
                w_tx_candidate_data  = {1'b1, 6'b0, 2'b00};
                w_tx_candidate_kind  = TXK_FCT;

            // 3순위: N-Char (credit 있고 TX FIFO 에 데이터 있을 때)
            end else if (i_net_tx_valid && w_tx_credit > 6'd0) begin
                w_tx_candidate_valid = 1'b1;
                w_tx_candidate_data  = i_net_tx_data;
                w_tx_candidate_kind  = TXK_NCHAR;

            // 4순위: Null (idle filler — ESC 보내고 다음 클럭 FCT, ERRATA-11 대상)
            end else begin
                w_tx_candidate_valid = 1'b1;
                w_tx_candidate_data  = {1'b1, 6'b0, 2'b11};
                w_tx_candidate_kind  = TXK_NULL_ESC;
            end

        end else if (r_state == ST_CONNECTING) begin
            // ── CONNECTING 상태 ──────────────────────────────────
            // 1순위: 초기 FCT 선송신 (§5.4 w_req_initial_fct)
            if (w_req_initial_fct > 3'd0) begin
                w_tx_candidate_valid = 1'b1;
                w_tx_candidate_data  = {1'b1, 6'b0, 2'b00};
                w_tx_candidate_kind  = TXK_FCT;

            // 2순위: 일반 FCT 요청
            end else if (w_fct_send_ok) begin
                w_tx_candidate_valid = 1'b1;
                w_tx_candidate_data  = {1'b1, 6'b0, 2'b00};
                w_tx_candidate_kind  = TXK_FCT;

            // 3순위: Null
            end else begin
                w_tx_candidate_valid = 1'b1;
                w_tx_candidate_data  = {1'b1, 6'b0, 2'b11};
                w_tx_candidate_kind  = TXK_NULL_ESC;
            end

        end else if (r_state == ST_STARTED) begin
            // ── STARTED: Null 만 송신 (850ns 타임아웃 방지, DECISION-14 전제) ──
            w_tx_candidate_valid = 1'b1;
            w_tx_candidate_data  = {1'b1, 6'b0, 2'b11};
            w_tx_candidate_kind  = TXK_NULL_ESC;
        end
        // ErrorReset/ErrorWait/Ready: 아무것도 송신하지 않음
        // (ECSS 5.5.7.4.a.1: Ready 에서 Transmit Enable 비활성화 — v5 원문 확정)
    end

    // One-entry source buffer: valid and data remain stable until accepted.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_req_valid <= 1'b0;
            r_tx_req_char  <= 9'd0;
            r_tx_req_kind  <= TXK_NONE;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_entering_error_reset || !o_tx_enable) begin
                r_tx_req_valid <= 1'b0;
                r_tx_req_char  <= 9'd0;
                r_tx_req_kind  <= TXK_NONE;
            end else if (r_tx_req_valid && i_enc_tx_ready) begin
                r_tx_req_valid <= 1'b0;
                r_tx_req_kind  <= TXK_NONE;
            end else if (!r_tx_req_valid && r_tx_inflight_kind == TXK_NONE
                         && w_tx_candidate_valid) begin
                r_tx_req_valid <= 1'b1;
                r_tx_req_char  <= w_tx_candidate_data;
                r_tx_req_kind  <= w_tx_candidate_kind;
            end
        end
    end

    assign w_enc_tx_accept_evt    = r_tx_req_valid && i_enc_tx_ready;
    assign w_tx_bc_esc_accept_evt = w_enc_tx_accept_evt && (r_tx_req_kind == TXK_BC_ESC);

    // Encoder can hold one accepted character. Preserve its kind until the
    // serializer reports the final bit so Link-FSM "Sent" conditions are not
    // asserted merely because the character entered the Encoding Layer.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_inflight_kind <= TXK_NONE;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_entering_error_reset) begin
                r_tx_inflight_kind <= TXK_NONE;
            end else if (w_enc_tx_accept_evt) begin
                r_tx_inflight_kind <= r_tx_req_kind;
            end else if (i_enc_tx_commit || i_enc_tx_abort) begin
                r_tx_inflight_kind <= TXK_NONE;
            end
        end
    end

    assign w_tx_nchar_commit_evt   = i_enc_tx_commit && (r_tx_inflight_kind == TXK_NCHAR);
    assign w_tx_fct_commit_evt     = i_enc_tx_commit && (r_tx_inflight_kind == TXK_FCT);
    assign w_tx_null_esc_commit_evt = i_enc_tx_commit && (r_tx_inflight_kind == TXK_NULL_ESC);
    assign w_tx_null_fct_commit_evt = i_enc_tx_commit && (r_tx_inflight_kind == TXK_NULL_FCT);
    assign w_tx_bc_esc_commit_evt   = i_enc_tx_commit && (r_tx_inflight_kind == TXK_BC_ESC);
    assign w_tx_bc_data_commit_evt  = i_enc_tx_commit && (r_tx_inflight_kind == TXK_BC_DATA);

    // ── FF: r_esc_pending, r_esc_kind (§8.1 ESC 원자적 시퀀스) ──
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_esc_pending <= 1'b0;
            r_esc_kind    <= 1'b0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (w_entering_error_reset) begin
                r_esc_pending <= 1'b0;       // ESC 시퀀스 강제 중단 (§9.1)
                r_esc_kind    <= 1'b0;
            end else if (w_tx_null_esc_commit_evt || w_tx_bc_esc_commit_evt) begin
                r_esc_pending <= 1'b1;       // ESC wire completion → second request
                r_esc_kind    <= w_tx_bc_esc_commit_evt;
            end else if (w_tx_null_fct_commit_evt || w_tx_bc_data_commit_evt) begin
                r_esc_pending <= 1'b0;       // two-character sequence committed
            end
        end
    end

    // =========================================================================
    // §8.4 Network -> DataLink ownership transfer
    // =========================================================================
    // guide §8.4 원문(3개 AND: state==RUN & credit>0 & enc_ready)은 §8.3 의
    // 우선순위(Timecode/FCT 가 N-Char 보다 앞설 수 있음)를 반영하지 않아, FCT나
    // ready is asserted only when the one-entry DataLink request buffer is empty
    // and the scheduler selected the Network N-Char. The Network FIFO pops on
    // valid && ready; from that edge onward r_tx_req_* owns a stable copy.
    assign o_net_tx_ready = !r_tx_req_valid
                          && (r_tx_inflight_kind == TXK_NONE)
                          && w_tx_candidate_valid
                          && (w_tx_candidate_kind == TXK_NCHAR);

    // ── Encoder 인터페이스 출력 ────────────────────────────────
    assign o_enc_tx_valid = r_tx_req_valid;
    assign o_enc_tx_char  = r_tx_req_char;

    // =========================================================================
