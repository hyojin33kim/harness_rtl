// =============================================================================
// spw_datalink — SpaceWire Data Link Layer (Link State FSM, Flow Control, ESC)
// ECSS-E-ST-50-12C Rev.1 §5.5 기준 검토본.
//
// 경계 규약:
//   - *_valid/*_ready는 level handshake이며 accept = valid && ready.
//   - *_accept_evt, *_commit_evt, *_err_evt는 1-clock event다.
//   - accept는 Encoding Layer 소유권 이전, commit은 마지막 비트 직렬화 완료다.
//   - ESC+FCT/Timecode는 r_esc_pending으로 원자성을 유지한다.
//
// 상위 배치: spw_top
//   spw_phy → spw_enc → spw_datalink(본 모듈) → spw_network
//
// 주요 보정: 동시 credit +8/-1 단일 갱신, RX FIFO reserve 반영,
// 오류 우선 commit 차단, SentNull/SentFCT commit 시점 판정, 가변 타이머 폭.
// =============================================================================

module spw_datalink #(
    parameter int RX_FIFO_DEPTH = 128,
    parameter int MAX_CREDIT    = 56,    // 7 x 8 (ECSS 5.5.4)
    parameter int CNT_6US       = 640,   // @ 100MHz
    parameter int CNT_12US      = 1280   // @ 100MHz
) (
    // ── Clock / Reset ────────────────────────────────────────────
    input  logic        i_clk,
    input  logic        i_rst_n,          // Active-Low Async (전체 초기화, DECISION-16)

    // ── MIB 제어 ─────────────────────────────────────────────────
    input  logic        i_link_enable,        // LinkEnable
    input  logic        i_link_start,     // LinkStart
    input  logic        i_auto_start,     // AutoStart
    input  logic        i_port_reset,     // PortReset (동기, 프로토콜 상태만, DECISION-16)

    // ── Encoding Layer → DataLink (수신 문자) ───────────────────
    // 주의: spw_enc가 10비트 심볼을 완성한 다음 클럭에 1클럭 pulse
    input  logic [8:0]  i_enc_rx_char,
    input  logic        i_enc_rx_valid,         // unstalled Encoder RX event
    input  logic        i_enc_parity_error,
    input  logic        i_disconnect_err_evt,     // Disconnect 에러 펄스

    // ── Data Link → Encoding enable contract (ECSS 5.5.2.h) ──────
    output logic        o_tx_enable,
    output logic        o_rx_enable,
    output logic        o_rx_parity_enable,

    // ── DataLink → Encoding Layer (송신 문자) ───────────────────
    output logic [8:0]  o_enc_tx_char,        // registered character request
    output logic        o_enc_tx_valid,       // held until ENC_TX_ACCEPT
    input  logic        i_enc_tx_ready,
    input  logic        i_enc_tx_commit,      // final serialized bit reached D/S boundary
    input  logic        i_enc_tx_abort,       // accepted character terminated by recovery
    output logic        o_link_recovery_evt,     // Encoder 강제 리셋 (ErrorReset 진입 시 1클럭 pulse)

    // ── Network Layer TX ─────────────────────────────────────────
    input  logic [8:0]  i_net_tx_data,       // Network TX FIFO head
    input  logic        i_net_tx_valid,      // Network owns data while valid && !ready
    output logic        o_net_tx_ready,      // DataLink takes ownership on valid && ready

    // ── Network Layer RX ─────────────────────────────────────────
    output logic [8:0]  o_net_rx_data,
    output logic        o_net_rx_valid,
    input  logic        i_net_rx_ready,
    output logic        o_net_rx_is_ctrl,

    // ── FCT 조건 A: spw_network 제공 ─────────────────────────────
    // 값 = RX_FIFO_DEPTH - rx_fifo 점유량, 폭 = $clog2(RX_FIFO_DEPTH+1) 비트
    // 비교(>=8, <=48) 로직은 본 모듈 내부 완결, spw_network는 raw 값만 제공
    input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] i_rx_fifo_free_count,

    // ── Timecode ──────────────────────────────────────────────────
    // i_tx_timecode_req_evt은 spw_network에서 rising edge 감지 후 1클럭 펄스로 전달
    input  logic        i_tx_timecode_req_evt,        // Timecode 송신 트리거 (미결 #4, 해소: RUN 아니면 discard)
    input  logic [7:0]  i_tx_timecode_data,        // flag[7:6] + counter[5:0]
    output logic        o_rx_timecode_commit_evt,      // 수신 Timecode 완성 펄스
    output logic [7:0]  o_rx_timecode_data,      // 수신 Timecode 값

    // ── 상태 출력 ─────────────────────────────────────────────────
    output logic [2:0]  o_link_state,    // 0:ER 1:EW 2:RD 3:ST 4:CN 5:RN
    output logic        o_disconnect_err_evt,
    output logic        o_parity_err_evt,
    output logic        o_esc_err_evt,
    output logic        o_credit_err_evt     // 미결 #3, 본 파일에서 구현
    // [v2, DECISION-13 소유권 재배치] ow_err_tx_invalid 포트 제거됨.
    // spw_network 세션(HO_05)에서 golden model SpWNetwork.push_tx() 재대조 결과,
    // 9비트 TX 핀 유효성 검사는 spw_network가 i_tx_data9 수신 시점에 직접 판정하는
    // 로직임을 확인 — spw_datalink §8.3은 항상 유효한 FCT/ESC만 생성해 이 에러가
    // 발생할 여지가 구조적으로 없다(§9 원 주석과 결론 일치). 이제 spw_network가
    // 자신의 포트로 spw_top에 직접 노출한다. spw_datalink_rtl_guide_v6.md 참조.
);

    localparam int TIMER_MAX = (CNT_6US > CNT_12US) ? CNT_6US : CNT_12US;
    localparam int TIMER_W   = (TIMER_MAX < 1) ? 1 : $clog2(TIMER_MAX + 1);

    // =========================================================================
    // 3.1 Link State 인코딩
    // =========================================================================
    localparam logic [2:0]
        ST_ERROR_RESET = 3'd0,
        ST_ERROR_WAIT  = 3'd1,
        ST_READY       = 3'd2,
        ST_STARTED     = 3'd3,
        ST_CONNECTING  = 3'd4,
        ST_RUN         = 3'd5;

    // =========================================================================
    // 내부 레지스터 (§4)
    // =========================================================================
    logic [2:0]  r_state;
    logic [TIMER_W-1:0] r_timer_cnt;
    logic        r_timer_expired;

    logic [5:0]  r_tx_credit;             // 0~56
    logic [5:0]  r_rx_credit;             // 0~56

    logic        r_null_seen;             // auto_start 조건
    logic        r_got_fct;               // Connecting→Run 조건
    logic        r_sent_fct;              // SentFCT 래치 (Connecting)
    logic [2:0]  r_req_initial_fct;       // min(RX_FIFO_DEPTH/8, 7) 카운트다운

    logic        r_seen_any_transition;   // D/S 최초 천이 감지 (disconnect 게이트)

    logic        r_err_disconnect;
    logic        r_err_parity;
    logic        r_err_esc;
    logic        r_err_credit;            // 미결 #3

    logic        r_rx_pending_esc;        // 수신 ESC FSM: ESC 후 다음 문자 대기
    logic        r_esc_pending;           // 송신 ESC 원자적 시퀀스 진행 중
    logic        r_esc_kind;              // 0=Null용FCT, 1=Timecode
    logic [7:0]  r_tc_value;              // 송신 대기 Timecode 값
    logic        r_tc_pending;            // 래치된 Timecode 유효 플래그
    logic [7:0]  r_bc_value;              // accepted Broadcast sequence payload

    // =========================================================================
    // 내부 comb 신호 (다음 단계에서 §3.3/§5~§9 구현 시 채움)
    // =========================================================================
    logic [2:0]  w_next_state;
    logic        w_timer_sync_rst;
    logic        w_credit_sync_rst;
    logic        w_entering_error_reset;

    logic        w_got_null, w_got_fct, w_got_nchar, w_got_timecode, w_esc_error;
    logic        w_tx_credit_err, w_rx_credit_err, w_credit_err;
    logic        w_fct_send_ok;
    logic        w_enc_tx_accept_evt;
    logic        w_tx_bc_esc_accept_evt;
    logic        w_tx_nchar_commit_evt;
    logic        w_tx_fct_commit_evt;
    logic        w_tx_null_esc_commit_evt;
    logic        w_tx_null_fct_commit_evt;
    logic        w_tx_bc_esc_commit_evt;
    logic        w_tx_bc_data_commit_evt;
    logic        r_sent_null;
    logic        w_valid_disconnect;
    logic        w_protocol_violation;
    logic        r_net_rx_valid;
    logic [8:0]  r_net_rx_data;
    logic        r_net_rx_is_ctrl;
    logic        w_net_rx_source_evt;
    logic        w_net_rx_accept_evt;
    logic        w_net_rx_overflow_evt;

    // -------------------------------------------------------------------------
    // (§9.2 는 이번 단계에서 구현 완료 — 스텁 제거됨)
    // -------------------------------------------------------------------------

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
    // r_state FF (async reset only)
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
        end else if (w_next_state == ST_ERROR_RESET || w_entering_connecting) begin
            r_sent_null <= 1'b0;
        end else if (r_state == ST_STARTED && w_tx_null_fct_commit_evt) begin
            r_sent_null <= 1'b1;
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
        end else if (w_timer_sync_rst) begin
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
        end else if (w_next_state != r_state) begin
            // 모든 상태 전이(진입 포함)에서 클리어 — Connecting 진입 후 새로
            // 수신하는 FCT만 유효해야 함 (§3.5)
            r_got_fct <= 1'b0;
        end else if (r_state == ST_CONNECTING && w_got_fct) begin
            r_got_fct <= 1'b1;
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_sent_fct <= 1'b0;
        end else if (w_entering_connecting) begin
            r_sent_fct <= 1'b0;
        end else if (r_state == ST_CONNECTING && w_tx_fct_commit_evt) begin
            r_sent_fct <= 1'b1;
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
        end else if (w_next_state == ST_ERROR_RESET) begin
            r_null_seen <= 1'b0;
        end else if (w_got_null) begin
            r_null_seen <= 1'b1;
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

    // ── Network Layer RX: physical event -> one-entry decoupling register ──
    // Encoder RX cannot stall. A valid N-Char is captured here, then held stable
    // until Network accepts it. A second physical event while this register is
    // blocked is a flow-control invariant violation, never a silent drop policy.
    assign w_net_rx_source_evt = w_got_nchar & !w_immediate_error;
    assign w_net_rx_accept_evt = r_net_rx_valid && i_net_rx_ready;
    assign w_net_rx_overflow_evt = w_net_rx_source_evt
                                 && r_net_rx_valid && !i_net_rx_ready;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_net_rx_valid   <= 1'b0;
            r_net_rx_data    <= 9'd0;
            r_net_rx_is_ctrl <= 1'b0;
        end else if (w_entering_error_reset) begin
            r_net_rx_valid   <= 1'b0;
            r_net_rx_data    <= 9'd0;
            r_net_rx_is_ctrl <= 1'b0;
        end else if (w_net_rx_source_evt) begin
            if (!r_net_rx_valid || i_net_rx_ready) begin
                r_net_rx_valid   <= 1'b1;
                r_net_rx_data    <= i_enc_rx_char;
                r_net_rx_is_ctrl <= w_is_ctrl;
            end
        end else if (w_net_rx_accept_evt) begin
            r_net_rx_valid <= 1'b0;
        end
    end

    assign o_net_rx_valid   = r_net_rx_valid;
    assign o_net_rx_data    = r_net_rx_data;
    assign o_net_rx_is_ctrl = r_net_rx_is_ctrl;

`ifndef SYNTHESIS
    always @(posedge i_clk) begin
        if (i_rst_n && w_net_rx_overflow_evt)
            $error("NET_RX overflow: physical N-Char arrived while holding register stalled");
    end
`endif

    // =========================================================================
    // §5 Flow Control — Credit 카운터 (ERRATA-11/20 반영)
    // =========================================================================
    // ERRATA-11 핵심: "독립 FCT 송신"과 "Null 유휴 필러의 FCT 절반"은 와이어
    // 레벨에서 같은 심볼이지만 의미가 다르다 — 후자는 credit 승인이 아니다.
    // 이 설계는 애초에 두 COMMIT 이벤트를 다른 신호로 분리한다:
    // w_tx_fct_commit_evt(독립 FCT) vs w_tx_null_fct_commit_evt(Null의 FCT half).
    // §5.2 는 독립 FCT COMMIT만 참조하므로
    // Null 필러가 자동으로 credit 이중계상에서 제외된다(참조모델 패치와 동일 효과,
    // note_tx_char_sent(is_independent_fct) 구분에 대응).
    //
    // ERRATA-20 반영: r_tx_credit 은 ST_CONNECTING 도 포함해서 갱신(아래 §5.1).
    // r_rx_credit(§5.2) 과 상태 게이트를 대칭으로 통일.

    assign w_credit_sync_rst = (w_next_state == ST_ERROR_RESET);

    // ── Comb: credit 오버플로우/언더플로우 사전 검사 ──────────────
    // ⚠️ 폭 주의: r_tx_credit(6비트, 0~63) + 8 이 64를 넘으면(예: 56+8=64) 6비트
    // 산술에서 mod-64 wrap 이 발생해 "64 > 56" 비교가 거짓으로 나와 credit_err
    // 검출 자체가 실패한다(guide §5.1 원문 코드를 그대로 옮기면 재현되는 버그 —
    // 이 구현에서 시뮬레이션으로 실제 발견/수정). 비교 전 폭을 7비트로 넓혀
    // wrap 없이 계산한다.
    logic [6:0] w_tx_credit_next_ext;
    assign w_tx_credit_next_ext = {1'b0, r_tx_credit}
                                + (w_got_fct ? 7'd8 : 7'd0)
                                - (w_tx_nchar_commit_evt ? 7'd1 : 7'd0);

    always_comb begin
        // TX: FCT 수신으로 56 초과 여부 (Connecting/Run 에서만 유효한 검사)
        w_tx_credit_err = w_got_fct
                        & (r_state == ST_CONNECTING || r_state == ST_RUN)
                        & (w_tx_credit_next_ext > {1'b0, MAX_CREDIT[5:0]});

        // RX: credit 없는데 N-Char 수신
        w_rx_credit_err = w_got_nchar & (r_rx_credit == 6'd0);

        w_credit_err = w_tx_credit_err | w_rx_credit_err;
    end

    // ── FF: r_tx_credit (§5.1, ERRATA-20 반영 — CONNECTING 포함) ──
    // 증가/감소 동시 이벤트는 한 case에서 +7로 처리해 NBA 덮어쓰기를 방지한다.
    logic w_tx_credit_inc_evt;
    logic w_tx_credit_dec_evt;

    assign w_tx_credit_inc_evt = (r_state == ST_CONNECTING || r_state == ST_RUN)
                               && w_got_fct && !w_tx_credit_err;
    assign w_tx_credit_dec_evt = (r_state == ST_RUN) && w_tx_nchar_commit_evt;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_credit <= 6'd0;
        end else if (w_credit_sync_rst) begin
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

    // ── FF: r_rx_credit (§5.2) ──────────────────────────────────
    // w_tx_fct_commit_evt는 독립 FCT의 wire completion에만 1이다. Null FCT
    // half는 w_tx_null_fct_commit_evt이므로 여기 포함하지 않는다.
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
        end else if (w_credit_sync_rst) begin
            r_rx_credit <= 6'd0;
        end else if ((r_state == ST_CONNECTING || r_state == ST_RUN) && !w_rx_credit_err) begin
            r_rx_credit <= r_rx_credit
                + (w_tx_fct_commit_evt ? 6'd8 : 6'd0)
                - (w_got_nchar ? 6'd1 : 6'd0);
        end
    end

    // ── FF: r_req_initial_fct (§5.4, Connecting 진입 시 min(FIFO/8,7)) ──
    // ECSS 5.5.4.k: min(RX_FIFO_DEPTH/8, 7)
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_req_initial_fct <= 3'd0;
        end else if (w_entering_connecting) begin
            r_req_initial_fct <= 3'(RX_FIFO_DEPTH / 8 < 7 ? RX_FIFO_DEPTH / 8 : 7);
        end else if (w_tx_fct_commit_evt && r_req_initial_fct > 3'd0) begin
            r_req_initial_fct <= r_req_initial_fct - 3'd1;
        end
    end

    // =========================================================================
    // §9.4 credit_error 검출 (미결 #3 — 구현 완료)
    // =========================================================================
    // ⚠️ guide §10 미결#3 원문 코드는 next_state 계산에 "래치된 r_err_credit"을
    // 쓰라고 하지만, 이는 golden model 대비 1클럭 지연 버그다 — golden model
    // (SpWLink.tick())은 그 클럭에 이미 SET 된 내부 credit_error 플래그를
    // immediate_error 계산에서 즉시(같은 클럭) 검사한다. §3.3 의
    // w_immediate_error 는 이미 w_credit_err(그 클럭의 comb 원인)를 직접
    // 참조하도록 구현되어 있어 golden model과 지연 없이 일치한다 — 이게 옳은
    // 형태이므로 별도의 래치를 next_state 판단에 끼워넣지 않는다.
    //
    // 출력 o_credit_err_evt 도 같은 이유로 golden model 의 "err_credit = credit_error
    // 매 클럭 그대로 미러링" 방식을 따라 w_credit_err 를 직접 반영한다(스티키
    // 래치가 아님 — ErrorReset 을 유발한 바로 그 클럭에도 값이 보이고, 다음
    // 클럭엔 원인이 사라지면 그대로 0 이 되는 게 golden model 과 동일한 거동).
    assign r_err_credit  = w_credit_err;   // 내부 미사용이지만 §4 선언과의 일관성을 위해 유지
    assign o_credit_err_evt = w_credit_err;

    // =========================================================================
    // §7 FCT 송신 조건 (2개 AND)
    // =========================================================================
    localparam int RX_FREE_THRESH = 8;

    // 조건 A (물리적 여유): spw_network 제공 raw 값, 비교는 본 모듈 내부 완결
    // 조건 B (논리적 크레딧): r_rx_credit <= MAX_CREDIT-8 이어야 다음 FCT로
    //   56을 넘기지 않는다 (§5.2 의 r_rx_credit 오버플로우 방지 전제가 바로 이 게이트)
    logic [$clog2(RX_FIFO_DEPTH+1):0] rx_reserved_need;
    logic [$clog2(RX_FIFO_DEPTH+1):0] effective_rx_free;
    assign rx_reserved_need = {1'b0, r_rx_credit} + 8;
    assign effective_rx_free = (r_net_rx_valid && i_rx_fifo_free_count != '0)
                             ? ({1'b0, i_rx_fifo_free_count} - 1'b1)
                             : {1'b0, i_rx_fifo_free_count};
    assign w_fct_send_ok = (effective_rx_free >= rx_reserved_need)
                         & (r_rx_credit <= (MAX_CREDIT - 8));

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
        end else if (w_entering_error_reset) begin
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

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_bc_value <= 8'd0;
        end else if (w_entering_error_reset) begin
            r_bc_value <= 8'd0;
        end else if (w_tx_bc_esc_accept_evt) begin
            r_bc_value <= r_tc_value;
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
            end else if (i_net_tx_valid && r_tx_credit > 6'd0) begin
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
            // 1순위: 초기 FCT 선송신 (§5.4 r_req_initial_fct)
            if (r_req_initial_fct > 3'd0) begin
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
        end else if (w_entering_error_reset || !o_tx_enable) begin
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

    assign w_enc_tx_accept_evt    = r_tx_req_valid && i_enc_tx_ready;
    assign w_tx_bc_esc_accept_evt = w_enc_tx_accept_evt && (r_tx_req_kind == TXK_BC_ESC);

    // Encoder can hold one accepted character. Preserve its kind until the
    // serializer reports the final bit so Link-FSM "Sent" conditions are not
    // asserted merely because the character entered the Encoding Layer.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_inflight_kind <= TXK_NONE;
        end else if (w_entering_error_reset) begin
            r_tx_inflight_kind <= TXK_NONE;
        end else if (w_enc_tx_accept_evt) begin
            r_tx_inflight_kind <= r_tx_req_kind;
        end else if (i_enc_tx_commit || i_enc_tx_abort) begin
            r_tx_inflight_kind <= TXK_NONE;
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
        end else if (w_entering_error_reset) begin
            r_esc_pending <= 1'b0;       // ESC 시퀀스 강제 중단 (§9.1)
            r_esc_kind    <= 1'b0;
        end else if (w_tx_null_esc_commit_evt || w_tx_bc_esc_commit_evt) begin
            r_esc_pending <= 1'b1;       // ESC wire completion → second request
            r_esc_kind    <= w_tx_bc_esc_commit_evt;
        end else if (w_tx_null_fct_commit_evt || w_tx_bc_data_commit_evt) begin
            r_esc_pending <= 1'b0;       // two-character sequence committed
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
    logic       a_net_rx_stalled;
    logic [8:0] a_net_rx_data;
    logic       a_net_rx_ctrl;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            a_req_stalled    <= 1'b0;
            a_req_char       <= 9'd0;
            a_req_kind       <= TXK_NONE;
            a_net_rx_stalled <= 1'b0;
            a_net_rx_data    <= 9'd0;
            a_net_rx_ctrl    <= 1'b0;
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

            if (a_net_rx_stalled) begin
                if (!r_net_rx_valid || r_net_rx_data !== a_net_rx_data
                        || r_net_rx_is_ctrl !== a_net_rx_ctrl)
                    $error("P11: Network RX transaction changed while stalled");
            end
            a_net_rx_stalled <= r_net_rx_valid && !i_net_rx_ready;
            if (r_net_rx_valid && !i_net_rx_ready) begin
                a_net_rx_data <= r_net_rx_data;
                a_net_rx_ctrl <= r_net_rx_is_ctrl;
            end

            if (i_enc_tx_commit && r_tx_inflight_kind == TXK_NONE)
                $error("P3: Encoder TX commit without accepted inflight request");
            if (w_tx_nchar_commit_evt && r_tx_credit == 6'd0)
                $error("P5: N-Char commit with zero TX credit");
            if (r_tx_credit > MAX_CREDIT[5:0] || r_rx_credit > MAX_CREDIT[5:0])
                $error("credit register exceeded MAX_CREDIT");
            if (r_esc_pending && r_tx_req_valid
                    && ((!r_esc_kind && r_tx_req_kind != TXK_NULL_FCT)
                     || ( r_esc_kind && r_tx_req_kind != TXK_BC_DATA)))
                $error("P12: unrelated character interleaved in ESC sequence");
        end
    end
`endif

endmodule
