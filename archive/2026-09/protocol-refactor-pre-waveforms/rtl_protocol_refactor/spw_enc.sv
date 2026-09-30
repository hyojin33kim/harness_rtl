// =============================================================================
// spw_enc — SpaceWire Encoding Layer (D-S 인코딩/디코딩, 문자 조립, 패리티)
// ECSS-E-ST-50-12C Rev.1 §5.4 / HO_04_RTL_Design_v3.md §5.2 / HO_03_Checklist_v2.md §4.2
//
// 근거: spw_ref_model.py SpWEncoder(156~220행) / SpWDecoder(226~342행)
//
// ECSS-E-ST-50-12C Rev.1 5.4.3.4:
//   현재 문자의 P와 data/control flag는 이전 문자의 payload를 보호한다.
//   따라서 RX commit은 다음 문자의 flag에서 이전 문자 parity가 확인된 뒤 발생한다.
//
// [필수 정정, ERRATA-7] Control code = FCT:00 EOP:10 EEP:01 ESC:11 (LSB가 code[0]).
//   Data/Control payload 비트 모두 LSB 먼저 송수신.
//
// 인터페이스 명명 정리 (spw_phy 포트와 일치시킴):
//   RX: i_rx_ds_data / i_rx_ds_strobe  <- spw_phy.ow_rx_data_bit/strobe_bit (이미 2FF 동기화됨)
//   TX: o_tx_ds_data / o_tx_ds_strobe -> spw_phy.i_tx_data_bit/strobe_bit
//
// 캐릭터 9비트 포맷 (spw_datalink <-> spw_enc 내부 규약):
//   bit[8]=0            : Data-shaped 문자 (DATA 또는 ESC 다음의 Timecode 페이로드), bit[7:0]=값
//   bit[8]=1, bit[1:0]  : Control 문자, code = FCT(00)/EEP(01)/EOP(10)/ESC(11)
// =============================================================================

module spw_enc #(
    parameter int CLK_FREQ_HZ  = 100_000_000,
    parameter int TX_RATE_MBPS = 10
) (
    input  logic i_clk,
    input  logic i_rst_n,

    // ── Link(spw_datalink) 제어 ──────────────────────────────────
    // [정정, HO_01_Encoding_Layer_DeepDive.md 부록A 반영] Enable 레벨 신호가
    // 아니라, ErrorReset 진입 그 클럭에만 1클럭 assert 되는 pulse 리셋이다.
    // enc/dec 는 그 외엔 항상 동작한다 — Started/Connecting 단계에서도
    // gotNull/gotFCT 감지를 위해 문자 디코딩이 계속 이뤄져야 하므로,
    // "Run 상태에서만 enable" 식의 레벨 게이팅은 링크 수립 자체를 막는다.
    input  logic i_link_recovery_evt,   // datalink 가 ErrorReset 진입 시 1클럭 pulse
    input  logic i_tx_enable,
    input  logic i_rx_enable,
    input  logic i_rx_parity_enable,

    // ── TX 캐릭터 인터페이스 (spw_datalink -> spw_enc) ────────────
    input  logic [8:0] i_enc_tx_char,
    input  logic       i_enc_tx_valid,
    output logic       o_enc_tx_ready,
    output logic       o_enc_tx_commit,
    output logic       o_enc_tx_abort,

    // ── RX 캐릭터 인터페이스 (spw_enc -> spw_datalink) ────────────
    output logic [8:0] o_enc_rx_char,
    output logic       o_enc_rx_valid,
    output logic       o_enc_parity_error,

    // ── spw_phy 인터페이스 ─────────────────────────────────────────
    output logic o_tx_ds_data,
    output logic o_tx_ds_strobe,
    input  logic i_rx_ds_data,
    input  logic i_rx_ds_strobe
);

    // ── Control code (ERRATA-7) ───────────────────────────────────
    localparam logic [1:0] CODE_FCT = 2'b00;
    localparam logic [1:0] CODE_EEP = 2'b01;
    localparam logic [1:0] CODE_EOP = 2'b10;
    localparam logic [1:0] CODE_ESC = 2'b11;

    // ── TX bit-period divider ────────────────────────────────────
    localparam int TX_RATE_HZ = (TX_RATE_MBPS > 0) ? TX_RATE_MBPS * 1_000_000 : 1;
    localparam int BIT_PERIOD_CYCLES = CLK_FREQ_HZ / TX_RATE_HZ;
    localparam int BPC_W = (BIT_PERIOD_CYCLES <= 1) ? 1 : $clog2(BIT_PERIOD_CYCLES);

    // =================================================================
    // TX 측 — 문자 조립 + parity 생성 + 직렬화
    // =================================================================

    logic       w_tx_flag;
    logic [7:0] w_tx_payload8;
    logic [1:0] w_tx_code;
    logic       w_tx_payload_parity;
    logic       w_tx_p_bit;
    logic [3:0] w_tx_len;
    logic [9:0] w_tx_load_bits;

    logic [9:0] r_tx_shift;
    logic [3:0] r_tx_bits_left;
    logic [BPC_W-1:0] r_tx_cyc_cnt;
    logic       r_tx_prev_payload_parity;
    logic       r_tx_first_char;

    logic r_prev_tx_bit_d, r_prev_tx_bit_s;
    logic or_tx_data_bit, or_tx_strobe_bit;
    logic r_prev_tx_enable;
    logic r_line_reset_active;
    localparam int RESET_W = (BIT_PERIOD_CYCLES <= 1) ? 1 : $clog2(BIT_PERIOD_CYCLES);
    logic [RESET_W-1:0] r_line_reset_cnt;

    logic w_tx_bit_tick;
    logic w_tx_accept_evt;
    logic w_tx_pop;
    logic w_tx_next_bit;
    logic w_tx_reset_evt;
    logic r_tx_char_commit_evt;
    logic r_tx_char_abort_evt;
    logic r_tx_active;

`ifndef SYNTHESIS
    initial begin
        if (TX_RATE_MBPS <= 0)
            $fatal(1, "TX_RATE_MBPS must be positive");
        if (CLK_FREQ_HZ < TX_RATE_HZ)
            $fatal(1, "CLK_FREQ_HZ must be at least TX_RATE_MBPS * 1_000_000");
        if ((CLK_FREQ_HZ % TX_RATE_HZ) != 0)
            $fatal(1, "CLK_FREQ_HZ must be an integer multiple of TX bit rate");
    end
`endif

    assign w_tx_bit_tick = (r_tx_cyc_cnt == BPC_W'(BIT_PERIOD_CYCLES - 1));
    assign w_tx_reset_evt = i_link_recovery_evt || (r_prev_tx_enable && !i_tx_enable);
    assign o_enc_tx_ready = i_tx_enable && !w_tx_reset_evt && !r_line_reset_active
                          && (r_tx_bits_left == 4'd0) && w_tx_bit_tick;
    assign w_tx_accept_evt = i_enc_tx_valid && o_enc_tx_ready;
    assign w_tx_pop = w_tx_accept_evt
                    || (i_tx_enable && !r_line_reset_active
                        && (r_tx_bits_left != 4'd0) && w_tx_bit_tick);
    assign w_tx_next_bit = w_tx_accept_evt ? w_tx_load_bits[0] : r_tx_shift[0];

    always_comb begin
        w_tx_flag     = i_enc_tx_char[8];
        w_tx_payload8 = i_enc_tx_char[7:0];
        w_tx_code     = i_enc_tx_char[1:0];
        w_tx_payload_parity = w_tx_flag ? (^w_tx_code) : (^w_tx_payload8);

        // ECSS 5.4.3.4: P covers the previous character payload and the
        // current data/control flag. The first Null starts with P=0 (5.4.5).
        w_tx_p_bit = r_tx_first_char ? 1'b0
                                     : ~(r_tx_prev_payload_parity ^ w_tx_flag);
        w_tx_len = w_tx_flag ? 4'd4 : 4'd10;
        if (w_tx_flag)
            w_tx_load_bits = {6'b0, w_tx_code[1:0], w_tx_flag, w_tx_p_bit};
        else
            w_tx_load_bits = {w_tx_payload8, w_tx_flag, w_tx_p_bit};
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_shift <= '0;
            r_tx_bits_left <= '0;
            r_tx_cyc_cnt <= '0;
            r_tx_prev_payload_parity <= 1'b0;
            r_tx_first_char <= 1'b1;
            r_tx_char_commit_evt <= 1'b0;
            r_tx_char_abort_evt <= 1'b0;
            r_tx_active <= 1'b0;
        end else if (w_tx_reset_evt) begin
            r_tx_shift <= '0;
            r_tx_bits_left <= '0;
            r_tx_cyc_cnt <= '0;
            r_tx_prev_payload_parity <= 1'b0;
            r_tx_first_char <= 1'b1;
            r_tx_char_commit_evt <= 1'b0;
            r_tx_char_abort_evt <= r_tx_active;
            r_tx_active <= 1'b0;
        end else if (r_line_reset_active || !i_tx_enable) begin
            r_tx_cyc_cnt <= '0;
            r_tx_char_commit_evt <= 1'b0;
            r_tx_char_abort_evt <= 1'b0;
        end else begin
            r_tx_char_commit_evt <= r_tx_active
                                  && (r_tx_bits_left == 4'd1) && w_tx_bit_tick;
            r_tx_char_abort_evt <= 1'b0;
            if (w_tx_bit_tick)
                r_tx_cyc_cnt <= '0;
            else
                r_tx_cyc_cnt <= r_tx_cyc_cnt + 1'b1;

            if (w_tx_accept_evt) begin
                r_tx_shift <= w_tx_load_bits >> 1;
                r_tx_bits_left <= w_tx_len - 4'd1;
                r_tx_prev_payload_parity <= w_tx_payload_parity;
                r_tx_first_char <= 1'b0;
                r_tx_active <= 1'b1;
            end else if ((r_tx_bits_left != 4'd0) && w_tx_bit_tick) begin
                r_tx_shift <= r_tx_shift >> 1;
                r_tx_bits_left <= r_tx_bits_left - 4'd1;
                if (r_tx_bits_left == 4'd1)
                    r_tx_active <= 1'b0;
            end
        end
    end

    assign o_enc_tx_commit = r_tx_char_commit_evt;
    assign o_enc_tx_abort  = r_tx_char_abort_evt;

    // Controlled D/S reset: Strobe is reset first; Data follows one current
    // bit period later. This avoids a simultaneous transition (ECSS 5.4.4c-e).
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            or_tx_data_bit <= 1'b0;
            or_tx_strobe_bit <= 1'b0;
            r_prev_tx_bit_d <= 1'b0;
            r_prev_tx_bit_s <= 1'b0;
            r_prev_tx_enable <= 1'b0;
            r_line_reset_active <= 1'b0;
            r_line_reset_cnt <= '0;
        end else begin
            r_prev_tx_enable <= i_tx_enable;
            if (w_tx_reset_evt) begin
                or_tx_strobe_bit <= 1'b0;
                r_line_reset_active <= 1'b1;
                r_line_reset_cnt <= RESET_W'(BIT_PERIOD_CYCLES - 1);
            end else if (r_line_reset_active) begin
                if (r_line_reset_cnt == '0) begin
                    or_tx_data_bit <= 1'b0;
                    r_prev_tx_bit_d <= 1'b0;
                    r_prev_tx_bit_s <= 1'b0;
                    r_line_reset_active <= 1'b0;
                end else begin
                    r_line_reset_cnt <= r_line_reset_cnt - 1'b1;
                end
            end else if (w_tx_pop) begin
                or_tx_data_bit <= w_tx_next_bit;
                or_tx_strobe_bit <= ~(w_tx_next_bit ^ r_prev_tx_bit_d ^ r_prev_tx_bit_s);
                r_prev_tx_bit_d <= w_tx_next_bit;
                r_prev_tx_bit_s <= ~(w_tx_next_bit ^ r_prev_tx_bit_d ^ r_prev_tx_bit_s);
            end
        end
    end

    assign o_tx_ds_data = or_tx_data_bit;
    assign o_tx_ds_strobe = or_tx_strobe_bit;

    // =================================================================
    // RX 측 — 변화 감지 + 문자 파싱 + parity 검사
    // =================================================================

    typedef enum logic [1:0] {
        RX_WAIT_PARITY = 2'd0,
        RX_WAIT_FLAG   = 2'd1,
        RX_WAIT_BITS   = 2'd2
    } rx_state_e;

    rx_state_e r_rx_state;
    logic       r_rx_prev_data, r_rx_prev_strobe;
    logic       r_rx_parity_bit;
    logic       r_rx_flag;
    logic [3:0] r_rx_need;
    logic [3:0] r_rx_cnt;
    logic [7:0] r_rx_acc;
    logic       r_rx_prev_payload_parity;
    logic       r_rx_pending_valid;
    logic [8:0] r_rx_pending_char;
    logic       r_rx_locked;
    logic [7:0] r_rx_sync_shift;

    logic       w_rx_changed;
    logic       w_rx_bit;

    always_comb begin
        w_rx_changed = (i_rx_ds_data != r_rx_prev_data) || (i_rx_ds_strobe != r_rx_prev_strobe);
        w_rx_bit     = i_rx_ds_data;   // 변화 시점의 Data 라인 값 = 수신 비트
    end

    logic       or_rx_char_valid;
    logic [8:0] or_rx_char;
    logic       or_parity_err;

    logic       w_rx_finish;
    logic [3:0] w_rx_need_next;

    assign w_rx_finish    = w_rx_changed && (r_rx_state == RX_WAIT_BITS) && (r_rx_cnt + 4'd1 == r_rx_need);
    assign w_rx_need_next = w_rx_bit ? 4'd2 : 4'd8;   // WAIT_FLAG 에서 다음 필요 비트수 계산용

    logic [7:0] w_rx_acc_next;
    assign w_rx_acc_next    = r_rx_acc | (8'(w_rx_bit) << r_rx_cnt);

    logic w_rx_prev_parity_ok;
    assign w_rx_prev_parity_ok = r_rx_prev_payload_parity
                               ^ r_rx_parity_bit ^ w_rx_bit;
    logic [7:0] w_rx_sync_next;
    assign w_rx_sync_next = {r_rx_sync_shift[6:0], w_rx_bit};

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_prev_data   <= 1'b0;
            r_rx_prev_strobe <= 1'b0;
            r_rx_state       <= RX_WAIT_PARITY;
            r_rx_parity_bit  <= 1'b0;
            r_rx_flag        <= 1'b0;
            r_rx_need        <= 4'd0;
            r_rx_cnt         <= 4'd0;
            r_rx_acc         <= 8'd0;
            r_rx_prev_payload_parity <= 1'b0;
            r_rx_pending_valid <= 1'b0;
            r_rx_pending_char  <= 9'd0;
            r_rx_locked        <= 1'b0;
            r_rx_sync_shift    <= 8'd0;
            or_rx_char_valid <= 1'b0;
            or_rx_char       <= 9'd0;
            or_parity_err    <= 1'b0;
        end else begin
            // 매 클럭 1클럭 pulse 신호들은 기본적으로 내림
            or_rx_char_valid <= 1'b0;
            or_parity_err    <= 1'b0;

            // 라인 레벨 변화 추적은 framing_reset 과 무관하게 항상 계속한다
            // (DeepDive 부록A: prev_data/prev_strobe 는 i_rst_n 으로만 초기화)
            r_rx_prev_data   <= i_rx_ds_data;
            r_rx_prev_strobe <= i_rx_ds_strobe;

            if (i_link_recovery_evt || !i_rx_enable) begin
                // sync reset: 프레이밍 상태만 초기화 (reset_framing() 과 동일 취지).
                // ErrorReset 진입 그 클럭에 1클럭만 assert.
                r_rx_state <= RX_WAIT_PARITY;
                r_rx_need  <= 4'd0;
                r_rx_cnt   <= 4'd0;
                r_rx_acc   <= 8'd0;
                r_rx_prev_payload_parity <= 1'b0;
                r_rx_pending_valid <= 1'b0;
                r_rx_locked <= 1'b0;
                r_rx_sync_shift <= 8'd0;
            end else begin
                if (!r_rx_locked) begin
                    // ECSS 5.4.5 first Null acquisition. Search the transition
                    // bit stream for P=0, ESC, P=0, FCT (chronological bits
                    // 0,1,1,1,0,1,0,0) before assuming a character boundary.
                    if (w_rx_changed) begin
                        r_rx_sync_shift <= w_rx_sync_next;
                        if (w_rx_sync_next == 8'b01110100) begin
                            r_rx_locked <= 1'b1;
                            r_rx_state <= RX_WAIT_PARITY;
                            r_rx_prev_payload_parity <= 1'b0; // FCT payload 00
                            r_rx_pending_char <= {1'b1, 6'd0, 2'b00};
                            r_rx_pending_valid <= 1'b1;
                            // Deliver ESC now; FCT is held until its parity is
                            // closed by the following character's P/flag.
                            or_rx_char <= {1'b1, 6'd0, 2'b11};
                            or_rx_char_valid <= 1'b1;
                        end
                    end
                end else if (w_rx_changed) begin
                    unique case (r_rx_state)
                        RX_WAIT_PARITY: begin
                            r_rx_parity_bit <= w_rx_bit;
                            r_rx_state      <= RX_WAIT_FLAG;
                        end
                        RX_WAIT_FLAG: begin
                            r_rx_flag  <= w_rx_bit;
                            r_rx_need  <= w_rx_bit ? 4'd2 : 4'd8;
                            r_rx_cnt   <= 4'd0;
                            r_rx_acc   <= 8'd0;
                            r_rx_state <= RX_WAIT_BITS;
                            // ECSS 5.4.3.4: current P and flag close the parity
                            // field for the previous character payload. Hold a
                            // decoded character until this check is available.
                            if (r_rx_pending_valid) begin
                                if (i_rx_parity_enable && !w_rx_prev_parity_ok) begin
                                    or_parity_err <= 1'b1;
                                end else begin
                                    or_rx_char_valid <= 1'b1;
                                    or_rx_char <= r_rx_pending_char;
                                end
                                r_rx_pending_valid <= 1'b0;
                            end
                        end
                        RX_WAIT_BITS: begin
                            if (w_rx_finish) begin
                                // Character completion updates the payload parity
                                // consumed by the following character's P+flag.
                                if (r_rx_flag) begin
                                    r_rx_pending_char <= {1'b1, 6'd0, w_rx_acc_next[1:0]};
                                    r_rx_prev_payload_parity <= ^w_rx_acc_next[1:0];
                                end else begin
                                    r_rx_pending_char <= {1'b0, w_rx_acc_next};
                                    r_rx_prev_payload_parity <= ^w_rx_acc_next;
                                end
                                r_rx_pending_valid <= 1'b1;
                                r_rx_state <= RX_WAIT_PARITY;
                                r_rx_cnt   <= 4'd0;
                                r_rx_acc   <= 8'd0;
                            end else begin
                                r_rx_acc <= w_rx_acc_next;
                                r_rx_cnt <= r_rx_cnt + 4'd1;
                            end
                        end
                        default: r_rx_state <= RX_WAIT_PARITY;
                    endcase
                end
            end
        end
    end

    assign o_enc_rx_valid    = or_rx_char_valid;
    assign o_enc_rx_char     = or_rx_char;
    assign o_enc_parity_error = or_parity_err;

`ifndef SYNTHESIS
    logic a_tx_outstanding;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            a_tx_outstanding <= 1'b0;
        end else begin
            if (r_tx_char_commit_evt && r_tx_char_abort_evt)
                $error("P2: TX commit and abort asserted together");
            if ((r_tx_char_commit_evt || r_tx_char_abort_evt)
                    && !a_tx_outstanding)
                $error("P3: TX completion without prior ACCEPT");
            if (w_tx_accept_evt && a_tx_outstanding
                    && !(r_tx_char_commit_evt || r_tx_char_abort_evt))
                $error("P4: second TX ACCEPT before prior completion");

            case ({w_tx_accept_evt,
                   (r_tx_char_commit_evt || r_tx_char_abort_evt)})
                2'b10: a_tx_outstanding <= 1'b1;
                2'b01: a_tx_outstanding <= 1'b0;
                2'b11: a_tx_outstanding <= 1'b1; // retire old, accept new
                default: a_tx_outstanding <= a_tx_outstanding;
            endcase
        end
    end
`endif

endmodule
