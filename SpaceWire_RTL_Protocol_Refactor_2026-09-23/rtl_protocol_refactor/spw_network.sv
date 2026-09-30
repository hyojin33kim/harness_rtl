// =============================================================================
// spw_network.sv
//
// SpaceWire Network Layer — 사용자 9비트 핀 <-> N-Char(DATA/EOP/EEP) 스트림
// 순수 변환기 + TX/RX FIFO. 우선순위 판단(언제 보낼지)은 하지 않는다 — 그건
// 전적으로 spw_datalink(§8.3 우선순위 로직)의 몫이다. Null/FCT/Timecode ESC
// 시퀀스는 이 모듈이 전혀 모르는 영역이다(spw_datalink가 전담).
//
// 기준: ECSS N-Char 형식과 본 검토본의 DataLink 경계 계약.
//
// [DECISION-13, 소유권 재배치 v6] o_host_tx_item_err_evt 는 spw_datalink가 아니라
// 이 모듈이 직접 판정·생성한다 — golden model SpWNetwork.push_tx() 375~392행
// 참조. spw_datalink는 §8.3에서 항상 유효한 FCT/ESC만 생성하므로 이 에러가
// spw_datalink 내부에서 발생할 여지가 없다.
//
// [리셋 범위, DECISION-16] 이 모듈은 프로토콜 상태가 없고(FIFO + 엣지검출뿐)
// golden model에서 i_port_reset은 SpWLink.state만 ERROR_RESET으로 되돌리고
// SpWNetwork(FIFO)는 건드리지 않는다(spw_ref_model.py 712행 부근). 따라서
// 이 모듈은 i_rst_n(전체 리셋)만 받고 i_port_reset은 받지 않는다.
//
// [포맷 비대칭 주의]
//   TX 방향(host -> datalink): 순수 pass-through. i_host_tx_item 는 §7.1의 9비트
//   통합 포맷(bit[8]=ctrl, [7:0]=0x00/0x01 for EOP/EEP, 그 외 DATA) 그대로
//   TX FIFO에 저장되고 o_net_tx_data로 나간다 — enc N-Char 제어코드
//   (FCT=00/EOP=10/EEP=01/ESC=11, ERRATA-7)로의 재인코딩은 spw_datalink의
//   몫이다 (HO_05 §2.1 에는 별도 ctrl 신호가 없다 — 9비트 값 자체가 자기서술적).
//
//   RX 방향(datalink -> host): 실제 변환이 필요하다. i_net_rx_data[8:0] +
//   i_net_rx_is_ctrl 은 enc N-Char 제어코드 포맷(제어문자면 data[1:0]에 code)
//   이고, 이 모듈이 §4.1 표대로 host 9비트 통합 포맷으로 변환해 rx_fifo에
//   저장한다.
// =============================================================================

module spw_network #(
    parameter int TX_FIFO_DEPTH   = 128,
    parameter int RX_FIFO_DEPTH   = 128,
    parameter bit ENABLE_TIMECODE = 1
) (
    input  logic i_clk,
    input  logic i_rst_n,          // 전체 리셋 (FIFO 포함) — DECISION-16, §헤더 참조

    // ---------------- 사용자 TX 핀 (호스트 -> spw_network), §3.1 ----------------
    input  logic [8:0] i_host_tx_item,
    input  logic        i_host_tx_valid,
    output logic        o_host_tx_ready,      // TX FIFO 에 여유 있음 (push_tx() 반환값과 동일 의미)

    // ---------------- 사용자 RX 핀 (spw_network -> 호스트), §3.2 ----------------
    output logic [8:0] o_host_rx_item,
    output logic        o_host_rx_valid,      // rx_fifo 에 꺼낼 게 있음 (peek 성격)
    input  logic        i_host_rx_ready,       // 호스트가 이번 클럭에 pop 하겠다는 신호

    // ---------------- DECISION-13: 9비트 TX 핀 유효성 에러 ----------------
    output logic        o_host_tx_item_err_evt, // 1클럭 pulse, bit[8]=1인데 0x100/0x101 아닌 경우

    // ---------------- spw_datalink TX 방향, §2.1 ----------------
    // (HO_05 원문 포트명 o_host_tx_ready/ow_tx_data 는 §3.1 호스트측과 이름이
    //  충돌하므로, 이 모듈 내부에서는 ow_dl_* 로 구분해 명명한다.)
    output logic [8:0] o_net_tx_data,       // TX FIFO head; stable while valid && !ready
    output logic        o_net_tx_valid,      // TX FIFO not empty
    input  logic        i_net_tx_ready,      // DataLink accepts ownership on valid && ready

    // ---------------- spw_datalink RX 방향, §2.2 ----------------
    input  logic [8:0] i_net_rx_data,
    input  logic       i_net_rx_valid,
    output logic       o_net_rx_ready,
    input  logic       i_net_rx_is_ctrl,

    // ---------------- FCT 조건 A, §2.3 ----------------
    output logic [$clog2(RX_FIFO_DEPTH+1)-1:0] o_rx_fifo_free_count, // = RX_FIFO_DEPTH - rx_fifo 점유량, 매 클럭 갱신

    // ---------------- Timecode, §2.4 ----------------
    input  logic        i_host_tx_timecode_req,         // 호스트 원시 레벨 입력
    input  logic [7:0]  i_host_tx_timecode_data,         // flag[7:6] + counter[5:0], 분해하지 않고 통과
    output logic        o_tx_timecode_req_evt,     // rising-edge 1클럭 펄스 -> datalink i_host_tx_timecode_req
    output logic [7:0]  o_tx_timecode_data,     // 통과 -> datalink i_host_tx_timecode_data

    input  logic        i_rx_timecode_commit_evt,     // datalink o_host_rx_timecode_commit_evt (수신 Timecode 완성 펄스)
    input  logic [7:0]  i_rx_timecode_data,     // datalink o_host_rx_timecode_data
    output logic        o_host_rx_timecode_commit_evt,       // 호스트로 그대로 통과
    output logic [7:0]  o_host_rx_timecode_data        // 호스트로 그대로 통과
);

    localparam int TXW = (TX_FIFO_DEPTH > 1) ? $clog2(TX_FIFO_DEPTH) : 1;
    localparam int RXW = (RX_FIFO_DEPTH > 1) ? $clog2(RX_FIFO_DEPTH) : 1;
    localparam int TXCW = $clog2(TX_FIFO_DEPTH + 1);
    localparam int RXCW = $clog2(RX_FIFO_DEPTH + 1);

    // =========================================================================
    // TX FIFO — host 9비트 포맷 그대로 저장 (pass-through). peek/pop 분리.
    // =========================================================================
    logic [8:0]      tx_mem   [0:TX_FIFO_DEPTH-1];
    logic [TXW-1:0]  r_tx_wptr, r_tx_rptr;
    logic [TXCW-1:0] r_tx_count;

    logic       w_tx_ctrl_valid;   // bit[8]=1 인데 0x100/0x101 인 정상 제어 요청
    logic       w_tx_ctrl_invalid; // bit[8]=1 인데 그 외(정의되지 않음)
    logic       w_tx_push;

    assign o_host_tx_ready      = (r_tx_count < TX_FIFO_DEPTH[TXCW-1:0]);
    assign w_tx_ctrl_valid   = i_host_tx_item[8] && (i_host_tx_item[7:0] == 8'h00 || i_host_tx_item[7:0] == 8'h01);
    assign w_tx_ctrl_invalid = i_host_tx_item[8] && !(i_host_tx_item[7:0] == 8'h00 || i_host_tx_item[7:0] == 8'h01);
    // DATA(bit[8]=0) 또는 유효한 제어(EOP/EEP)만 큐잉. invalid 는 조용히 버림(§4.2, DECISION-13).
    assign w_tx_push = i_host_tx_valid && o_host_tx_ready && !w_tx_ctrl_invalid;

    logic w_net_tx_accept;

    assign o_net_tx_valid = (r_tx_count != '0);
    assign w_net_tx_accept = o_net_tx_valid && i_net_tx_ready;

    // Host item format and Encoding N-Char format are intentionally different.
    // Host: 9'h100=EOP, 9'h101=EEP. Encoding: EOP=ctrl 2'b10,
    // EEP=ctrl 2'b01. This boundary owns the TX canonicalization.
    always_comb begin
        if (!o_net_tx_valid)
            o_net_tx_data = 9'd0;
        else if (!tx_mem[r_tx_rptr][8])
            o_net_tx_data = {1'b0, tx_mem[r_tx_rptr][7:0]};
        else if (tx_mem[r_tx_rptr][7:0] == 8'h00)
            o_net_tx_data = 9'h102;
        else
            o_net_tx_data = 9'h101;
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_wptr  <= '0;
            r_tx_rptr  <= '0;
            r_tx_count <= '0;
        end else begin
            if (w_tx_push) begin
                tx_mem[r_tx_wptr] <= i_host_tx_item;
                r_tx_wptr <= (r_tx_wptr == TX_FIFO_DEPTH-1) ? '0 : r_tx_wptr + 1'b1;
            end
            if (w_net_tx_accept) begin
                r_tx_rptr <= (r_tx_rptr == TX_FIFO_DEPTH-1) ? '0 : r_tx_rptr + 1'b1;
            end
            case ({w_tx_push, w_net_tx_accept})
                2'b10:   r_tx_count <= r_tx_count + 1'b1;
                2'b01:   r_tx_count <= r_tx_count - 1'b1;
                default: r_tx_count <= r_tx_count; // 00: 변화없음, 11: push&pop 동시 -> 순증감 0
            endcase
        end
    end

    // ---- DECISION-13: o_host_tx_item_err_evt, 1클럭 registered pulse ----
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_host_tx_item_err_evt <= 1'b0;
        end else begin
            o_host_tx_item_err_evt <= i_host_tx_valid && o_host_tx_ready && w_tx_ctrl_invalid;
        end
    end

    // =========================================================================
    // RX FIFO — datalink enc N-Char 코드 포맷을 host 9비트 통합 포맷으로 변환
    // 저장 (§4.1). 오버플로우 시 방어적 드롭(에러 신호 없음, §4.5).
    // =========================================================================
    logic [8:0]      rx_mem  [0:RX_FIFO_DEPTH-1];
    logic [RXW-1:0]  r_rx_wptr, r_rx_rptr;
    logic [RXCW-1:0] r_rx_count;

    logic [8:0] w_rx_data9;   // §4.1 변환 결과
    logic       w_net_rx_accept;

    always_comb begin
        if (i_net_rx_is_ctrl) begin
            // FCT/ESC는 datalink가 이미 걸러내므로 이 지점엔 EOP/EEP만 온다 (§4.1)
            if (i_net_rx_data[1:0] == 2'b10)
                w_rx_data9 = 9'h100; // EOP
            else
                w_rx_data9 = 9'h101; // EEP (2'b01, 그 외 조합은 발생하지 않는다는 전제)
        end else begin
            w_rx_data9 = {1'b0, i_net_rx_data[7:0]}; // DATA
        end
    end

    assign o_host_rx_valid       = (r_rx_count != '0);
    assign o_host_rx_item       = o_host_rx_valid ? rx_mem[r_rx_rptr] : 9'b0;
    assign o_rx_fifo_free_count  = RX_FIFO_DEPTH[RXCW-1:0] - RXCW'(r_rx_count);

    wire w_rx_pop = i_host_rx_ready && o_host_rx_valid;
    assign o_net_rx_ready = (r_rx_count < RX_FIFO_DEPTH[RXCW-1:0]) || w_rx_pop;
    assign w_net_rx_accept = i_net_rx_valid && o_net_rx_ready;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_wptr  <= '0;
            r_rx_rptr  <= '0;
            r_rx_count <= '0;
        end else begin
            if (w_net_rx_accept) begin
                rx_mem[r_rx_wptr] <= w_rx_data9;
                r_rx_wptr <= (r_rx_wptr == RX_FIFO_DEPTH-1) ? '0 : r_rx_wptr + 1'b1;
            end
            if (w_rx_pop) begin
                r_rx_rptr <= (r_rx_rptr == RX_FIFO_DEPTH-1) ? '0 : r_rx_rptr + 1'b1;
            end
            case ({w_net_rx_accept, w_rx_pop})
                2'b10:   r_rx_count <= r_rx_count + 1'b1;
                2'b01:   r_rx_count <= r_rx_count - 1'b1;
                default: r_rx_count <= r_rx_count;
            endcase
        end
    end

    // =========================================================================
    // Timecode — i_host_tx_timecode_req rising-edge 검출 후 1클럭 펄스 변환 (§2.4)
    // ENABLE_TIMECODE=0 이면 pulse 자체를 생성하지 않는다(sample_tick_in()과 동일 동작).
    // i_host_tx_timecode_data/o_tx_timecode_data, i_rx_timecode_commit_evt/i_rx_timecode_data -> o_host_rx_timecode_commit_evt/o_host_rx_timecode_data
    // 은 분해하지 않고 그대로 통과한다(spw_datalink/호스트가 분해).
    // =========================================================================
    logic r_prev_tick_in;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_prev_tick_in <= 1'b0;
        end else begin
            r_prev_tick_in <= i_host_tx_timecode_req;
        end
    end

    assign o_tx_timecode_req_evt = ENABLE_TIMECODE ? (i_host_tx_timecode_req && !r_prev_tick_in) : 1'b0;
    assign o_tx_timecode_data = i_host_tx_timecode_data;

    assign o_host_rx_timecode_commit_evt = i_rx_timecode_commit_evt;
    assign o_host_rx_timecode_data = i_rx_timecode_data;

`ifndef SYNTHESIS
    logic       a_net_tx_stalled;
    logic [8:0] a_net_tx_data;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            a_net_tx_stalled <= 1'b0;
            a_net_tx_data    <= 9'd0;
        end else begin
            if (a_net_tx_stalled && (!o_net_tx_valid || o_net_tx_data !== a_net_tx_data))
                $error("P1/P10: Network TX FIFO head changed without ACCEPT");
            a_net_tx_stalled <= o_net_tx_valid && !i_net_tx_ready;
            if (o_net_tx_valid && !i_net_tx_ready)
                a_net_tx_data <= o_net_tx_data;
        end
    end
`endif

endmodule
