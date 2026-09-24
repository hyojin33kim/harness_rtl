    // §9.1 ErrorReset 진입 시 리셋 — o_link_recovery_evt 펄스
    // =========================================================================
    assign o_link_recovery_evt = w_entering_error_reset;  // 1클럭 pulse (spw_enc 강제 리셋)

    // =========================================================================
    // §9.1/§9.2 Disconnect 게이팅 — (A) 결정: spw_phy 로 역할 일원화
    // =========================================================================
    // ⚠️ 아키텍처 결정 기록: guide §9.2 는 spw_datalink 내부에
    // r_seen_any_transition 을 별도로 두고 i_disconnect_err_evt 를 다시 게이팅하라고
    // 명시하지만, golden model 을 재확인한 결과 seen_any_transition 은
    // SpWDecoder(=spw_phy 대응) 계층 하나에만 존재하고 SpWLink(=spw_datalink
    // 대응)는 이를 별도로 갖지 않는다 — SpWLink.disconnect 는 이미 Decoder 가
    // 게이트를 마친 최종값을 그대로 받아쓸 뿐이다. 즉 guide §9.2 가 요구하는
    // 이중 게이트는 golden model 구조와 어긋나는 설계였다.
    //
    // 실제로 spw_datalink 로컬 게이트를 구현해보니, i_disconnect_err_evt 가 ErrorReset
    // 전이를 유발하는 바로 그 클럭에 게이트 클리어와 판정이 동시에 일어나
    // o_disconnect_err_evt 가 그 원인 클럭에도 정상 관측되지 않는 레이스가
    // 발생함을 시뮬레이션으로 확인했다.
    //
    // (A) 결정: spw_phy.sv 에 i_link_reset 포트를 신설해(v2), spw_datalink 가
    // ErrorReset 에 재진입하는 클럭마다 spw_phy 의 r_seen_any_transition 을
    // 직접 재초기화하도록 근본 해결했다(spw_top 배선 시 o_link_recovery_evt 또는
    // 동일한 w_entering_error_reset 신호를 spw_phy.i_link_reset 에 연결).
    // 따라서 spw_datalink 는 spw_phy 가 이미 재연결 세션 단위로 올바르게
    // 게이트한 i_disconnect_err_evt 를 그대로 신뢰하면 된다 — 이중 게이트 불필요.
    //
    // r_seen_any_transition 레지스터는 guide §4 문서와의 대응을 위해 이름만
    // 유지하되 항상 0(미사용)으로 고정한다. §12 참조모델 대응표 갱신 필요.
    assign r_seen_any_transition = 1'b0;  // 미사용 — 역할은 spw_phy.r_seen_any_transition 으로 이전

    // =========================================================================
    // §9.2 Disconnect 에러 활성화 (ERRATA-5, DECISION-08) — (A) 결정 반영
    // =========================================================================
    // spw_phy 가 이미 i_link_reset 기반으로 재연결 세션마다 올바르게 게이트한
    // 값이므로, 여기서는 그대로 신뢰한다 (추가 게이팅 없음).
    assign w_valid_disconnect = i_disconnect_err_evt;

    // =========================================================================
    // §9.1 나머지 에러 출력 (o_disconnect_err_evt/parity/esc)
    // =========================================================================
    // §9.4(credit_error)와 동일한 이유로, golden model 처럼 "그 클럭의 원인
    // 신호를 그대로 미러링"하는 조합 방식을 쓴다(스티키 래치 아님) — 이렇게
    // 해야 ErrorReset 을 유발한 바로 그 클럭에도 값이 보이고, 다음 클럭부터는
    // 원인이 사라지면 그대로 0 이 되는 golden model(SpWLink.tick() 끝부분:
    // err_disconnect=disconnect, err_parity=parity_error, err_esc=esc_error)
    // 과 정확히 같은 거동이 된다.
    assign r_err_disconnect  = w_valid_disconnect;
    assign r_err_parity      = i_enc_parity_error;
    assign r_err_esc         = w_esc_error;

    assign o_disconnect_err_evt = w_valid_disconnect;
    assign o_parity_err_evt     = i_enc_parity_error;
    assign o_esc_err_evt        = w_esc_error;

    // =========================================================================
    // DECISION-13 — ow_err_tx_invalid 는 [v2] 에서 spw_network로 소유권 이전됨
    // =========================================================================
    // (기존 위치의 1'b0 고정 assign 제거. §헤더 [v2 변경 이력] 및
    //  spw_datalink_rtl_guide_v6.md 참조. spw_top 배선 시 ow_err_tx_invalid는
    //  spw_network 모듈에서 직접 가져올 것 — 이 모듈에는 더 이상 없음.)

`ifndef SYNTHESIS
    // Simulation contract checks. These are intentionally local to the owning
    // boundary so failures identify the first lifecycle divergence.
    logic       a_req_stalled;
    logic [8:0] a_req_char;
    tx_kind_e   a_req_kind;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            a_req_stalled    <= 1'b0;
            a_req_char       <= 9'd0;
            a_req_kind       <= TXK_NONE;
        end else begin
            if (a_req_stalled && !w_entering_error_reset && o_tx_enable) begin
                if (!r_tx_req_valid || r_tx_req_char !== a_req_char
                        || r_tx_req_kind !== a_req_kind)
                    $error("P1: Encoder TX request changed while stalled");
            end
            a_req_stalled <= r_tx_req_valid && !i_enc_tx_ready
                           && !w_entering_error_reset && o_tx_enable;
            if (r_tx_req_valid && !i_enc_tx_ready) begin
                a_req_char <= r_tx_req_char;
                a_req_kind <= r_tx_req_kind;
            end

            if (i_enc_tx_commit && r_tx_inflight_kind == TXK_NONE)
                $error("P3: Encoder TX commit without accepted inflight request");
            if (w_rx_pending_esc && w_got_nchar)
                $error("RX decoder emitted N-Char while ESC second character was pending");
            if (w_tx_nchar_commit_evt && w_tx_credit == 6'd0)
                $error("P5: N-Char commit with zero TX credit");
            if (w_tx_credit > MAX_CREDIT[5:0] || w_rx_credit > MAX_CREDIT[5:0])
                $error("credit register exceeded MAX_CREDIT");
            if (r_esc_pending && r_tx_req_valid
                    && ((!r_esc_kind && r_tx_req_kind != TXK_NULL_FCT)
                     || ( r_esc_kind && r_tx_req_kind != TXK_BC_DATA)))
                $error("P12: unrelated character interleaved in ESC sequence");
        end
    end
`endif
