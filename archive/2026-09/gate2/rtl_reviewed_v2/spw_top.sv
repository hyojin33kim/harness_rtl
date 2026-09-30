// =============================================================================
// spw_top.sv
//
// SpaceWire 단일 포트 노드 최상위 통합 모듈.
// spw_phy -> spw_enc -> spw_datalink -> spw_network 4계층을 연결한다.
//
// 기준 문서: HO_06_spw_top_Wiring_v1.md (전체 배선 매트릭스, 실 RTL 대조 완료)
//           HO_04_spw_datalink_Handover_v2.md §3/§4 (spw_phy/enc/datalink 배선 근거)
//           HO_05_spw_network_Handover_v2.md §2/§3 (spw_datalink/network 배선 근거)
//
// 검증 상태는 RTL_GATE2_REVIEW.md가 단일 기준이다. 파일 헤더에는 과거 검증
// 이력을 주장하지 않는다.
//
// [DECISION-13, 소유권] o_host_tx_item_err_evt 는 spw_datalink가 아니라 spw_network의
// 출력이다 — spw_top에서 이 포트를 찾을 때 spw_datalink 쪽이 아니라 net 인스턴스
// 쪽을 봐야 한다(HO_06 §6.4).
//
// [리셋] i_rst_n(전체 async, 4개 모듈 전부 팬아웃) vs i_port_reset(spw_datalink에만,
// FSM만 동기 초기화, FIFO는 건드리지 않음 — DECISION-16). spw_network는
// i_port_reset을 받지 않는다(자체 프로토콜 상태가 없으므로 i_rst_n만 받음).
//
// [i_link_recovery_evt, v2 핵심] spw_datalink.o_link_recovery_evt 을 spw_enc.i_link_recovery_evt 뿐
// 아니라 spw_phy.i_link_recovery_evt 에도 반드시 팬아웃해야 재연결 데드락이 방지된다
// (HO_06 §4, 빠뜨리면 silent failure).
// =============================================================================

module spw_top #(
    parameter int  CLK_FREQ_HZ           = 100_000_000,
    parameter int  TX_RATE_MBPS          = 10,
    parameter int  DISCONNECT_TIMEOUT_NS = 850,
    parameter int  TX_FIFO_DEPTH         = 128,
    parameter int  RX_FIFO_DEPTH         = 128,
    parameter int  MAX_CREDIT            = 56,
    parameter bit  ENABLE_TIMECODE       = 1
) (
    // ── Clock / Reset ────────────────────────────────────────────
    input  logic i_clk,
    input  logic i_rst_n,          // 전체 async 리셋 (4개 모듈 전부, DECISION-16)

    // ── MIB 제어 (§6.1) ──────────────────────────────────────────
    input  logic i_link_enable,
    input  logic i_link_start,
    input  logic i_auto_start,
    input  logic i_port_reset,     // 동기, spw_datalink FSM만 (FIFO 불변)

    // ── 물리 DS 인터페이스 (Pure Digital) ────────────────────────
    input  logic i_rx_ds_data_pad,
    input  logic i_rx_ds_strobe_pad,
    output logic o_tx_ds_data_pad,
    output logic o_tx_ds_strobe_pad,

    // ── 사용자 데이터 핀 (§6.2) ──────────────────────────────────
    input  logic [8:0] i_host_tx_item,
    input  logic        i_host_tx_valid,
    output logic        o_host_tx_ready,

    output logic [8:0] o_host_rx_item,
    output logic        o_host_rx_valid,
    input  logic        i_host_rx_ready,

    // ── Timecode 핀 (§6.3, spw_network 경유) ─────────────────────
    input  logic        i_host_tx_timecode_req,
    input  logic [7:0]  i_host_tx_timecode_data,
    output logic        o_host_rx_timecode_commit_evt,
    output logic [7:0]  o_host_rx_timecode_data,

    // ── 상태/에러 출력 (§6.4) ─────────────────────────────────────
    output logic [2:0] o_link_state,
    output logic       o_disconnect_err_evt,  // 조합 미러 (spw_datalink)
    output logic       o_parity_err_evt,      // 조합 미러 (spw_datalink)
    output logic       o_esc_err_evt,         // 조합 미러 (spw_datalink)
    output logic       o_credit_err_evt,      // 조합 미러 (spw_datalink)
    output logic       o_host_tx_item_err_evt,  // ★ registered pulse, 출처 = spw_network (DECISION-13)
    output logic       o_phy_disconnect_err_evt       // spw_phy 원신호 (선택적 top 노출, HO_06 §6.4 참조)
);

    // =========================================================================
    // §7 파라미터 전파 — CNT_6US/CNT_12US는 CLK_FREQ_HZ 기반으로 여기서 계산해
    // spw_datalink에 넘긴다 (직접 상수 하드코딩 금지, HO_06 §7)
    // =========================================================================
    localparam longint CNT_6US_CALC =
        (64'(CLK_FREQ_HZ) * 64 + 9_999_999) / 10_000_000;
    localparam int CNT_6US  = (CNT_6US_CALC < 1) ? 1 : CNT_6US_CALC;
    localparam int CNT_12US = CNT_6US * 2;

    // =========================================================================
    // 모듈 간 내부 배선 (HO_06 §2~§5)
    // =========================================================================

    // -- spw_phy <-> spw_enc --
    logic rx_ds_data, rx_ds_strobe;
    logic tx_ds_data, tx_ds_strobe;

    // -- spw_phy <-> spw_datalink (v2 신규, disconnect 게이팅 일원화) --
    logic disconnect_err_evt;      // spw_phy.o_phy_disconnect_err_evt -> spw_datalink.i_disconnect_err_evt
    logic link_recovery_evt;      // spw_datalink.o_link_recovery_evt -> spw_phy.i_link_recovery_evt (+ spw_enc.i_link_recovery_evt)

    // -- spw_enc <-> spw_datalink --
    logic        enc_recovery_evt;        // = link_recovery_evt (팬아웃 소스, 이름만 구분)
    logic [8:0]  tx_char_data;
    logic        tx_char_valid;
    logic        tx_char_ready;        // spw_enc.o_tx_char_ready -> spw_datalink.i_tx_char_ready (이름 다름 주의)
    logic        tx_char_commit_evt;
    logic [8:0]  rx_char_data;
    logic        rx_char_commit_evt;
    logic        rx_parity_err_evt;
    logic        tx_enable;
    logic        rx_enable;
    logic        rx_parity_enable;

    // -- spw_datalink <-> spw_network --
    logic [8:0] tx_nchar_data;    // spw_network.o_tx_nchar_data -> spw_datalink.i_tx_nchar_data
    logic       tx_nchar_valid;   // spw_network.o_tx_nchar_valid -> spw_datalink.i_tx_nchar_valid
    logic       tx_nchar_accept_evt;   // spw_datalink.o_tx_nchar_accept_evt -> spw_network.i_tx_nchar_accept_evt

    logic [8:0] rx_nchar_data;  // spw_datalink.o_rx_nchar_data -> spw_network.i_rx_nchar_data
    logic       rx_nchar_commit_evt; // spw_datalink.o_rx_nchar_commit_evt -> spw_network.i_rx_nchar_commit_evt
    logic       rx_nchar_is_ctrl;  // spw_datalink.o_rx_nchar_is_ctrl -> spw_network.i_rx_nchar_is_ctrl

    logic [$clog2(RX_FIFO_DEPTH+1)-1:0] rx_fifo_free_count; // spw_network -> spw_datalink

    logic       tx_timecode_req_evt;    // spw_network.ow_dl_tick_in -> spw_datalink.i_host_tx_timecode_req
    logic [7:0] tx_timecode_data;    // spw_network.ow_dl_time_in -> spw_datalink.i_host_tx_timecode_data
    logic       rx_timecode_commit_evt;   // spw_datalink.o_host_rx_timecode_commit_evt -> spw_network.i_dl_tick_out
    logic [7:0] rx_timecode_data;   // spw_datalink.o_host_rx_timecode_data -> spw_network.i_dl_time_out

    assign enc_recovery_evt = link_recovery_evt;

    // =========================================================================
    // spw_phy
    // =========================================================================
    spw_phy #(
        .CLK_FREQ_HZ          (CLK_FREQ_HZ),
        .DISCONNECT_TIMEOUT_NS(DISCONNECT_TIMEOUT_NS)
    ) u_spw_phy (
        .i_clk           (i_clk),
        .i_rst_n         (i_rst_n),

        .i_link_recovery_evt    (link_recovery_evt),      // HO_06 §4 — 필수 배선

        .i_rx_ds_data_pad    (i_rx_ds_data_pad),
        .i_rx_ds_strobe_pad  (i_rx_ds_strobe_pad),
        .o_tx_ds_data_pad   (o_tx_ds_data_pad),
        .o_tx_ds_strobe_pad (o_tx_ds_strobe_pad),

        .o_rx_ds_data  (rx_ds_data),
        .o_rx_ds_strobe(rx_ds_strobe),

        .i_tx_ds_data   (tx_ds_data),
        .i_tx_ds_strobe (tx_ds_strobe),

        .o_disconnect_err_evt(disconnect_err_evt)
    );

    assign o_phy_disconnect_err_evt = disconnect_err_evt;

    // =========================================================================
    // spw_enc
    // =========================================================================
    spw_enc #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .TX_RATE_MBPS(TX_RATE_MBPS)
    ) u_spw_enc (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),

        .i_link_recovery_evt  (enc_recovery_evt),         // HO_06 §3 — spw_datalink.o_link_recovery_evt 팬아웃
        .i_tx_enable(tx_enable),
        .i_rx_enable(rx_enable),
        .i_rx_parity_enable(rx_parity_enable),

        .i_tx_char_data       (tx_char_data),
        .i_tx_char_valid (tx_char_valid),
        .o_tx_char_ready(tx_char_ready),       // 이름 다름: enc 쪽 ready -> datalink 쪽 enc_ready
        .o_tx_char_commit_evt(tx_char_commit_evt),

        .o_rx_char_data      (rx_char_data),
        .o_rx_char_commit_evt(rx_char_commit_evt),
        .o_rx_parity_err_evt   (rx_parity_err_evt),

        .o_tx_ds_data  (tx_ds_data),
        .o_tx_ds_strobe(tx_ds_strobe),
        .i_rx_ds_data   (rx_ds_data),
        .i_rx_ds_strobe (rx_ds_strobe)
    );

    // =========================================================================
    // spw_datalink
    // =========================================================================
    spw_datalink #(
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .MAX_CREDIT   (MAX_CREDIT),
        .CNT_6US      (CNT_6US),
        .CNT_12US     (CNT_12US)
    ) u_spw_datalink (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),

        .i_link_enable    (i_link_enable),
        .i_link_start (i_link_start),
        .i_auto_start (i_auto_start),
        .i_port_reset (i_port_reset),

        .i_rx_char_commit_evt(rx_char_commit_evt),
        .i_rx_char_data      (rx_char_data),
        .i_rx_parity_err_evt   (rx_parity_err_evt),
        .i_disconnect_err_evt   (disconnect_err_evt),
        .o_tx_enable(tx_enable),
        .o_rx_enable(rx_enable),
        .o_rx_parity_enable(rx_parity_enable),

        .o_tx_char_valid(tx_char_valid),
        .o_tx_char_data      (tx_char_data),
        .i_tx_char_ready     (tx_char_ready),
        .i_tx_char_commit_evt(tx_char_commit_evt),
        .o_link_recovery_evt    (link_recovery_evt),      // HO_06 §4 — spw_phy.i_link_recovery_evt 로도 팬아웃(위에서 처리)

        .i_tx_nchar_data (tx_nchar_data),
        .i_tx_nchar_valid(tx_nchar_valid),
        .o_tx_nchar_accept_evt(tx_nchar_accept_evt),

        .o_rx_nchar_data (rx_nchar_data),
        .o_rx_nchar_commit_evt(rx_nchar_commit_evt),
        .o_rx_nchar_is_ctrl (rx_nchar_is_ctrl),

        .i_rx_fifo_free_count(rx_fifo_free_count),

        .i_tx_timecode_req_evt(tx_timecode_req_evt),
        .i_tx_timecode_data(tx_timecode_data),
        .o_rx_timecode_commit_evt(rx_timecode_commit_evt),
        .o_rx_timecode_data(rx_timecode_data),

        .o_link_state    (o_link_state),
        .o_disconnect_err_evt(o_disconnect_err_evt),
        .o_parity_err_evt    (o_parity_err_evt),
        .o_esc_err_evt       (o_esc_err_evt),
        .o_credit_err_evt    (o_credit_err_evt)
        // o_host_tx_item_err_evt 포트 없음 — [v2, DECISION-13 재배치] spw_network가 대신 생성 (아래)
    );

    // =========================================================================
    // spw_network
    // =========================================================================
    spw_network #(
        .TX_FIFO_DEPTH  (TX_FIFO_DEPTH),
        .RX_FIFO_DEPTH  (RX_FIFO_DEPTH),
        .ENABLE_TIMECODE(ENABLE_TIMECODE)
    ) u_spw_network (
        .i_clk  (i_clk),
        .i_rst_n(i_rst_n),          // i_port_reset 없음 — DECISION-16, 자체 프로토콜 상태 없음

        .i_host_tx_item(i_host_tx_item),
        .i_host_tx_valid(i_host_tx_valid),
        .o_host_tx_ready(o_host_tx_ready),

        .o_host_rx_item(o_host_rx_item),
        .o_host_rx_valid(o_host_rx_valid),
        .i_host_rx_ready (i_host_rx_ready),

        .o_host_tx_item_err_evt(o_host_tx_item_err_evt),  // ★ DECISION-13 출처 — spw_network

        .o_tx_nchar_data (tx_nchar_data),
        .o_tx_nchar_valid(tx_nchar_valid),
        .i_tx_nchar_accept_evt   (tx_nchar_accept_evt),

        .i_rx_nchar_data (rx_nchar_data),
        .i_rx_nchar_commit_evt(rx_nchar_commit_evt),
        .i_rx_nchar_is_ctrl (rx_nchar_is_ctrl),

        .o_rx_fifo_free_count(rx_fifo_free_count),

        .i_host_tx_timecode_req(i_host_tx_timecode_req),
        .i_host_tx_timecode_data(i_host_tx_timecode_data),
        .o_tx_timecode_req_evt(tx_timecode_req_evt),
        .o_tx_timecode_data(tx_timecode_data),

        .i_rx_timecode_commit_evt(rx_timecode_commit_evt),
        .i_rx_timecode_data(rx_timecode_data),
        .o_host_rx_timecode_commit_evt  (o_host_rx_timecode_commit_evt),
        .o_host_rx_timecode_data  (o_host_rx_timecode_data)
    );

endmodule
