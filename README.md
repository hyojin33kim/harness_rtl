# SpaceWire RTL Protocol Refactor

SpaceWire 링크의 Network–DataLink–Encoder 경계를 명시적인 transaction 및
completion contract로 재구성하고, DataLink 내부 경계와 arbitration 정책을
단계적으로 검증하는 RTL 저장소다.

## Current status

- Baseline: [`rtl/baseline/`](rtl/baseline/)
- Latest isolated candidate: [`rtl/candidates/datalink-v5/`](rtl/candidates/datalink-v5/)
- Verification: 2026-09-30 candidate regression PASS
- Adoption status: DECISION-17 제품 정책 확정; 기본 RTL 반영은 미구현

제품 기본 정책은 strict Broadcast priority를 유지하는 Option A와
`latest-wins + drop counter` admission이다. Run-time link-rate 변경은 Option C
성능 확장안으로 분리한다. v5는 v4의 interface/reset-style 정리 위에
DECISION-17 Option B를 추가한 실험 candidate다.
Timecode가 FCT 또는 credited N-Char와 연속 경합할 때 8회마다 다른 traffic에
한 slot을 허용해 저속 링크의 starvation을 제한한다. baseline과 이전 candidate는
비교 및 회귀 검증 근거로 유지한다.

## Candidate evolution

| Candidate | Scope |
|---|---|
| [`ReviewSplit v1`](archive/2026-09/datalink-v1-review-split/) | DataLink review boundary 분리 |
| [`RxHold v2`](archive/2026-09/datalink-v2-rx-hold/) | RX holding contract 분리 |
| [`RxDecode v3`](archive/2026-09/datalink-v3-rx-decode/) | RX decode contract 분리 |
| [`Credit v4`](rtl/candidates/datalink-v4/) | credit accounting boundary 분리; v5 비교 기준 |
| [`InterfaceResetStyle v5`](rtl/candidates/datalink-v5/) | interface/reset-style 정리 및 DECISION-17 실험 |

구조 변경 전 전체 상태는 tag `pre-layout-cleanup-2026-09-30`에 보존했다.
초기 실험 snapshot은 [`archive/2026-09/`](archive/2026-09/)에 두고,
현재 회귀검증에 필요한 baseline과 v4/v5만 `rtl/`에 유지한다.

## Interface contracts

| Boundary | Contract |
|---|---|
| Network → DataLink | `net_tx_valid && net_tx_ready`에서 ownership transfer |
| DataLink → Encoder | registered `enc_tx_valid/ready` request |
| Encoder → DataLink | accepted character마다 `enc_tx_commit` 또는 `enc_tx_abort` |
| DataLink → Network | one-entry holding register를 둔 `net_rx_valid/ready` |

Baseline의 상세 설계 판단은
[`PROTOCOL_REFACTOR_REPORT.md`](rtl/baseline/rtl_protocol_refactor/PROTOCOL_REFACTOR_REPORT.md),
최신 candidate의 변경과 측정값은
[`v5 README`](rtl/candidates/datalink-v5/README.md)를
참조한다.

## Requirements

- Linux 또는 호환 shell 환경
- Icarus Verilog 12.x
- Python 3
- GTKWave (파형을 직접 열 때만 필요)

Ubuntu 계열 설치 예:

```bash
sudo apt-get update
sudo apt-get install -y iverilog gtkwave python3
```

## Run latest candidate regression

저장소 루트에서 실행한다.

```bash
bash rtl/candidates/datalink-v5/run_candidate_regression.sh
```

전체 실행 범위:

- `spw_top` compile
- 8개 directed RTL test
- RX hold/decode/credit child contract 3개
- link initialization, flow control, error recovery, reconnect story
- GTKWave preset 4개의 signal-path 검사
- 64-item burst performance regression
- DECISION-17 rate/request-period 조합 5개

성공 시 마지막에 다음 문구가 출력된다.

```text
PASS candidate regression: 8 directed + RX hold/decode/credit contracts + story + 4 presets + 64-item burst + 5 DECISION-17 rate/period cases
```

## Verification status

2026-09-30 현재 체크아웃에서 Icarus Verilog regression을 재실행한 결과:

- directed RTL tests: 8/8 PASS
- child contracts: 3/3 PASS
- integrated story: PASS
- GTKWave signal checks: 4/4 PASS
- 64-item burst: PASS, network-accept span 2,632 cycles
- DECISION-17 cases: 5/5 PASS
- 10 Mbps, 700/1,000 ns 요청 주기: 300 DATA + EOP 완료
- 25 Mbps, 700/1,000 ns 요청 주기: throttle grant 없이 완료

이 결과는 구현된 interface/event contract와 제한된 rate/traffic 조합의 directed
검증 근거다. SpaceWire compliance certification, 전체 rate envelope, FPGA
CDC/timing closure, 실제 PHY recovery 또는 formal equivalence를 의미하지 않는다.

## DECISION-17 product policy

ECSS-E-ST-50-12C Rev.1 5.5.6은 Broadcast에 FCT/N-Char보다 높은 priority를
요구한다. 따라서 제품 기본 정책은 다음과 같이 확정했다.

1. **Option A — 기본 정책:** strict Broadcast priority를 유지한다.
2. **Admission:** pending Timecode가 전송되기 전에 새 요청이 오면 최신 값으로
   교체하고, 폐기된 이전 요청을 drop counter에 누적한다.
3. **Option C — 성능 확장:** per-port Run-time link-rate 변경은 별도 설계와
   검증을 거쳐 추가한다.

현재 v5 Option B throttle은 성능 실험 근거로 보존하지만 제품 기본 RTL에는
채택하지 않는다. 정책의 구현 경계와 검증 조건은
[`DECISION-17_TIMECODE_ADMISSION.md`](docs/decisions/DECISION-17_TIMECODE_ADMISSION.md),
측정 근거는
[`HANDOVER_DECISION17_RATE_ENVELOPE_2026-09-25.md`](docs/handover/HANDOVER_DECISION17_RATE_ENVELOPE_2026-09-25.md)에 정리되어 있다.

## Open story waveforms

candidate regression 실행 후:

```bash
gtkwave \
  rtl/candidates/datalink-v5/build/spw_story.vcd \
  rtl/baseline/story_waveforms/overview.gtkw
```

세부 preset은 candidate 디렉터리의 `link_initialize.gtkw`,
`flow_control.gtkw`, `error_recovery.gtkw`다. HTML 파형은 narrative 설명용이며,
cycle-accurate 판단은 simulation VCD와 assertion 결과를 기준으로 한다.

## Engineering rules and handover

- [`docs/RTL_RULES.md`](docs/RTL_RULES.md): architecture, interface, ownership,
  event, naming, reset/CDC, verification, waveform, change-control 규칙
- [`HANDOVER_WAVEFORM_INTERFACE_RESET_PARITY.md`](docs/handover/HANDOVER_WAVEFORM_INTERFACE_RESET_PARITY.md):
  waveform/interface/reset/parity 작업 인계
- [`HANDOVER_DECISION17_RATE_ENVELOPE_2026-09-25.md`](docs/handover/HANDOVER_DECISION17_RATE_ENVELOPE_2026-09-25.md):
  DECISION-17 결과, compliance 쟁점, rate-envelope 후속 결정

`build/`, VCD, VVP, log와 `codex_*.md` 세션 로그는 재생성 가능하거나 로컬 전용인
자료이므로 Git에서 제외한다. RTL과 script의 줄바꿈은 `.gitattributes`에서 LF로
고정한다.
