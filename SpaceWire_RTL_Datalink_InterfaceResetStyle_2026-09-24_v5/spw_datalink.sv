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
    // Clock / hardware reset
    input  logic        i_clk,
    input  logic        i_rst_n,

    // TX data I/F: Network -> Data Link -> Encoder
    input  logic [8:0]  i_net_tx_data,
    input  logic        i_net_tx_valid,
    output logic        o_net_tx_ready,
    output logic [8:0]  o_enc_tx_char,
    output logic        o_enc_tx_valid,
    input  logic        i_enc_tx_ready,

    // TX control I/F: completion, enable, timecode and recovery
    input  logic        i_enc_tx_commit,
    input  logic        i_enc_tx_abort,
    output logic        o_tx_enable,
    input  logic        i_tx_timecode_req_evt,
    input  logic [7:0]  i_tx_timecode_data,
    output logic        o_link_recovery_evt,

    // RX data I/F: Encoder -> Data Link -> Network
    input  logic [8:0]  i_enc_rx_char,
    input  logic        i_enc_rx_valid,
    output logic [8:0]  o_net_rx_data,
    output logic        o_net_rx_valid,
    input  logic        i_net_rx_ready,

    // RX control I/F: classification, reserve and timecode
    input  logic        i_enc_parity_error,
    output logic        o_rx_enable,
    output logic        o_rx_parity_enable,
    output logic        o_net_rx_is_ctrl,
    input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] i_rx_fifo_free_count,
    output logic        o_rx_timecode_commit_evt,
    output logic [7:0]  o_rx_timecode_data,

    // Link-wide control and status
    input  logic        i_link_enable,
    input  logic        i_link_start,
    input  logic        i_auto_start,
    input  logic        i_port_reset,
    input  logic        i_disconnect_err_evt,
    output logic [2:0]  o_link_state,
    output logic        o_disconnect_err_evt,
    output logic        o_parity_err_evt,
    output logic        o_esc_err_evt,
    output logic        o_credit_err_evt
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

    wire [5:0]   w_tx_credit;             // child-owned, 0~56
    wire [5:0]   w_rx_credit;             // child-owned, 0~56

    logic        r_null_seen;             // auto_start 조건
    logic        r_got_fct;               // Connecting→Run 조건
    logic        r_sent_fct;              // SentFCT 래치 (Connecting)
    wire [2:0]   w_req_initial_fct;       // child-owned countdown

    logic        r_seen_any_transition;   // D/S 최초 천이 감지 (disconnect 게이트)

    logic        r_err_disconnect;
    logic        r_err_parity;
    logic        r_err_esc;
    logic        r_err_credit;            // 미결 #3

    logic        w_rx_pending_esc;        // RX decoder state output for debug
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
    wire         w_credit_err;
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
    logic        w_net_rx_hold_valid;  // child-state output for FCT reserve

    // -------------------------------------------------------------------------
    // (§9.2 는 이번 단계에서 구현 완료 — 스텁 제거됨)
    // -------------------------------------------------------------------------

    `include "spw_datalink_link_fsm.svh"
    `include "spw_datalink_rx.svh"
    assign w_credit_sync_rst = (w_next_state == ST_ERROR_RESET);
    assign r_err_credit = w_credit_err;
    assign o_credit_err_evt = w_credit_err;

    spw_datalink_credit #(
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .MAX_CREDIT(MAX_CREDIT)
    ) u_credit (
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),
        .i_credit_sync_rst(w_credit_sync_rst),
        .i_link_state(r_state),
        .i_entering_connecting(w_entering_connecting),
        .i_got_fct(w_got_fct),
        .i_got_nchar(w_got_nchar),
        .i_tx_nchar_commit_evt(w_tx_nchar_commit_evt),
        .i_tx_fct_commit_evt(w_tx_fct_commit_evt),
        .i_rx_fifo_free_count(i_rx_fifo_free_count),
        .i_rx_hold_valid(w_net_rx_hold_valid),
        .o_tx_credit(w_tx_credit),
        .o_rx_credit(w_rx_credit),
        .o_req_initial_fct(w_req_initial_fct),
        .o_credit_err(w_credit_err),
        .o_fct_send_ok(w_fct_send_ok)
    );
    `include "spw_datalink_tx.svh"
    `include "spw_datalink_error_checks.svh"
endmodule
