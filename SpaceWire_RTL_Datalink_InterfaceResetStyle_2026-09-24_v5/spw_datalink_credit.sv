// v4: credit/FCT ownership extracted from spw_datalink; parent owns event timing.
module spw_datalink_credit #(
    parameter int RX_FIFO_DEPTH = 128,
    parameter int MAX_CREDIT = 56
) (
    // Clock / hardware and synchronous protocol reset
    input  logic i_clk,
    input  logic i_rst_n,
    input  logic i_credit_sync_rst,

    // TX credit data I/F
    output logic [5:0] o_tx_credit,

    // TX credit control I/F
    input  logic i_got_fct,
    input  logic i_tx_nchar_commit_evt,

    // RX credit data I/F
    input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] i_rx_fifo_free_count,
    input  logic i_rx_hold_valid,
    output logic [5:0] o_rx_credit,

    // RX credit control I/F
    input  logic i_got_nchar,
    input  logic i_tx_fct_commit_evt,
    output logic [2:0] o_req_initial_fct,
    output logic o_fct_send_ok,

    // Link-wide control and error
    input  logic [2:0] i_link_state,
    input  logic i_entering_connecting,
    output logic o_credit_err
);
    localparam logic [2:0] ST_CONNECTING = 3'd4;
    localparam logic [2:0] ST_RUN = 3'd5;
    logic [5:0] r_tx_credit, r_rx_credit;
    logic [2:0] r_req_initial_fct;
    logic w_tx_credit_err, w_rx_credit_err, w_credit_err, w_fct_send_ok;
    assign o_tx_credit = r_tx_credit;
    assign o_rx_credit = r_rx_credit;
    assign o_req_initial_fct = r_req_initial_fct;
    assign o_credit_err = w_credit_err;
    assign o_fct_send_ok = w_fct_send_ok;
    // =========================================================================
    // §5 Flow Control — Credit 카운터 (ERRATA-11/20 반영)
    // =========================================================================
    // ERRATA-11 핵심: "독립 FCT 송신"과 "Null 유휴 필러의 FCT 절반"은 와이어
    // 레벨에서 같은 심볼이지만 의미가 다르다 — 후자는 credit 승인이 아니다.
    // 이 설계는 애초에 두 COMMIT 이벤트를 다른 신호로 분리한다:
    // i_tx_fct_commit_evt(독립 FCT) vs parent의 Null FCT-half commit.
    // §5.2 는 독립 FCT COMMIT만 참조하므로
    // Null 필러가 자동으로 credit 이중계상에서 제외된다(참조모델 패치와 동일 효과,
    // note_tx_char_sent(is_independent_fct) 구분에 대응).
    //
    // ERRATA-20 반영: r_tx_credit 은 ST_CONNECTING 도 포함해서 갱신(아래 §5.1).
    // r_rx_credit(§5.2) 과 상태 게이트를 대칭으로 통일.


    // ── Comb: credit 오버플로우/언더플로우 사전 검사 ──────────────
    // ⚠️ 폭 주의: r_tx_credit(6비트, 0~63) + 8 이 64를 넘으면(예: 56+8=64) 6비트
    // 산술에서 mod-64 wrap 이 발생해 "64 > 56" 비교가 거짓으로 나와 credit_err
    // 검출 자체가 실패한다(guide §5.1 원문 코드를 그대로 옮기면 재현되는 버그 —
    // 이 구현에서 시뮬레이션으로 실제 발견/수정). 비교 전 폭을 7비트로 넓혀
    // wrap 없이 계산한다.
    logic [6:0] w_tx_credit_next_ext;
    assign w_tx_credit_next_ext = {1'b0, r_tx_credit}
                                + (i_got_fct ? 7'd8 : 7'd0)
                                - (i_tx_nchar_commit_evt ? 7'd1 : 7'd0);

    always_comb begin
        // TX: FCT 수신으로 56 초과 여부 (Connecting/Run 에서만 유효한 검사)
        w_tx_credit_err = i_got_fct
                        & (i_link_state == ST_CONNECTING || i_link_state == ST_RUN)
                        & (w_tx_credit_next_ext > {1'b0, MAX_CREDIT[5:0]});

        // RX: credit 없는데 N-Char 수신
        w_rx_credit_err = i_got_nchar & (r_rx_credit == 6'd0);

        w_credit_err = w_tx_credit_err | w_rx_credit_err;
    end

    // ── FF: r_tx_credit (§5.1, ERRATA-20 반영 — CONNECTING 포함) ──
    // 증가/감소 동시 이벤트는 한 case에서 +7로 처리해 NBA 덮어쓰기를 방지한다.
    logic w_tx_credit_inc_evt;
    logic w_tx_credit_dec_evt;

    assign w_tx_credit_inc_evt = (i_link_state == ST_CONNECTING || i_link_state == ST_RUN)
                               && i_got_fct && !w_tx_credit_err;
    assign w_tx_credit_dec_evt = (i_link_state == ST_RUN) && i_tx_nchar_commit_evt;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_credit <= 6'd0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (i_credit_sync_rst) begin
                r_tx_credit <= 6'd0;
            end else begin
                unique case ({w_tx_credit_inc_evt, w_tx_credit_dec_evt})
                    2'b10: r_tx_credit <= r_tx_credit + 6'd8;
                    2'b01: r_tx_credit <= r_tx_credit - 6'd1;
                    2'b11: r_tx_credit <= r_tx_credit + 6'd7;
                    default: r_tx_credit <= r_tx_credit;
                endcase
            end
        end
    end

    // ── FF: r_rx_credit (§5.2) ──────────────────────────────────
    // i_tx_fct_commit_evt는 독립 FCT의 wire completion에만 1이다. Null FCT
    // half는 parent에서 별도로 분류하므로 여기 포함하지 않는다.
    // ⚠️ 폭 주의: 여기엔 §5.1(w_tx_credit_sum)과 달리 명시적 7비트 오버플로우
    // 사전검사가 없다 — r_rx_credit 은 §7.1 FCT 송신 게이트
    // (w_fct_send_ok = r_rx_credit <= MAX_CREDIT-8) 가 애초에 48 초과 시 FCT 를
    // 보내지 않도록 원천 차단하는 구조로 설계되어 있어(§7 구현 시 이 게이트가
    // 독립 FCT request의 필요조건이 됨), r_rx_credit 자체가 56을 넘을 방법이 없다.
    // 단, 이건 §7 구현을 전제로 한 안전성이므로 §7 완성 시 이 가정이 실제로
    // 지켜지는지 반드시 재검증할 것.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_credit <= 6'd0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (i_credit_sync_rst) begin
                r_rx_credit <= 6'd0;
            end else if ((i_link_state == ST_CONNECTING || i_link_state == ST_RUN) && !w_rx_credit_err) begin
                r_rx_credit <= r_rx_credit
                    + (i_tx_fct_commit_evt ? 6'd8 : 6'd0)
                    - (i_got_nchar ? 6'd1 : 6'd0);
            end
        end
    end

    // ── FF: r_req_initial_fct (§5.4, Connecting 진입 시 min(FIFO/8,7)) ──
    // ECSS 5.5.4.k: min(RX_FIFO_DEPTH/8, 7)
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_req_initial_fct <= 3'd0;
        end else begin
            // Clocked branch: synchronous control has priority over updates.
            if (i_entering_connecting) begin
                r_req_initial_fct <= 3'(RX_FIFO_DEPTH / 8 < 7 ? RX_FIFO_DEPTH / 8 : 7);
            end else if (i_tx_fct_commit_evt && r_req_initial_fct > 3'd0) begin
                r_req_initial_fct <= r_req_initial_fct - 3'd1;
            end
        end
    end

    // =========================================================================
    // §9.4 credit_error 검출 (미결 #3 — 구현 완료)
    // =========================================================================
    // ⚠️ guide §10 미결#3 원문 코드는 next_state 계산에 "래치된 r_err_credit"을
    // 쓰라고 하지만, 이는 golden model 대비 1클럭 지연 버그다 — golden model
    // (SpWLink.tick())은 그 클럭에 이미 SET 된 내부 credit_error 플래그를
    // immediate_error 계산에서 즉시(같은 클럭) 검사한다. §3.3 의
    // parent의 w_immediate_error 는 이 모듈의 조합 o_credit_err 를 직접
    // 참조하도록 구현되어 있어 golden model과 지연 없이 일치한다 — 이게 옳은
    // 형태이므로 별도의 래치를 next_state 판단에 끼워넣지 않는다.
    //
    // parent 출력 o_credit_err_evt 도 golden model 의 "err_credit = credit_error
    // 매 클럭 그대로 미러링" 방식을 따라 w_credit_err 를 직접 반영한다(스티키
    // 래치가 아님 — ErrorReset 을 유발한 바로 그 클럭에도 값이 보이고, 다음
    // 클럭엔 원인이 사라지면 그대로 0 이 되는 게 golden model 과 동일한 거동).

    // =========================================================================
    // §7 FCT 송신 조건 (2개 AND)
    // =========================================================================
    // 조건 A (물리적 여유): spw_network 제공 raw 값, 비교는 본 모듈 내부 완결
    // 조건 B (논리적 크레딧): r_rx_credit <= MAX_CREDIT-8 이어야 다음 FCT로
    //   56을 넘기지 않는다 (§5.2 의 r_rx_credit 오버플로우 방지 전제가 바로 이 게이트)
    logic [$clog2(RX_FIFO_DEPTH+1):0] rx_reserved_need;
    logic [$clog2(RX_FIFO_DEPTH+1):0] effective_rx_free;
    assign rx_reserved_need = {1'b0, r_rx_credit} + 8;
    assign effective_rx_free = (i_rx_hold_valid && i_rx_fifo_free_count != '0)
                             ? ({1'b0, i_rx_fifo_free_count} - 1'b1)
                             : {1'b0, i_rx_fifo_free_count};
    assign w_fct_send_ok = (effective_rx_free >= rx_reserved_need)
                         & (r_rx_credit <= (MAX_CREDIT - 8));
endmodule
