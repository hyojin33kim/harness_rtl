# SpaceWire RTL Protocol Refactor

SpaceWire 링크의 Network–DataLink–Encoder 경계를 명시적인 transaction 및
completion contract로 재구성한 RTL 검증 저장소다. 최신 candidate에는
SystemVerilog RTL, directed regression, 통합 story waveform, GTKWave preset이
포함되어 있다.

## Current candidate

[`SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/`](SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/)

- `rtl_protocol_refactor/`: RTL, directed testbench, regression script 및 검토 문서
- `story_waveforms/`: link initialization, flow control, error recovery 파형 시나리오

핵심 interface contract는 다음과 같다.

| Boundary | Contract |
|---|---|
| Network → DataLink | `net_tx_valid && net_tx_ready`에서 ownership transfer |
| DataLink → Encoder | registered `enc_tx_valid/ready` request |
| Encoder → DataLink | accepted character마다 `enc_tx_commit` 또는 `enc_tx_abort` |
| DataLink → Network | one-entry holding register를 둔 `net_rx_valid/ready` |

상세 설계 판단과 검증 근거는
[`PROTOCOL_REFACTOR_REPORT.md`](SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor/PROTOCOL_REFACTOR_REPORT.md)를 참조한다.

## Requirements

- Linux 또는 호환 shell 환경
- Icarus Verilog 12.x
- GTKWave (파형을 직접 열 때만 필요)

Ubuntu 계열에서는 다음과 같이 설치한다.

```bash
sudo apt-get update
sudo apt-get install -y iverilog gtkwave
```

## Run regression

```bash
cd SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor
./run_regression.sh
```

전체 실행은 다음을 검증한다.

- 8개 directed RTL test
- `spw_top` compile
- link initialization / flow control / parity-error recovery / reconnect story
- 4개 GTKWave preset에 선언된 signal path의 실제 VCD 존재 여부

성공 기준은 9개 simulation PASS와 모든 필수 VCD의 생성이다. `build/`, VCD,
VVP 및 log는 재생성 가능한 산출물이므로 Git에서 제외한다.

## Open story waveforms

Regression 실행 후:

```bash
cd ../story_waveforms
gtkwave spw_story.vcd overview.gtkw
```

세부 관점은 `link_initialize.gtkw`, `flow_control.gtkw`,
`error_recovery.gtkw`로 분리되어 있다. HTML 파형은 narrative 설명용이며,
cycle-accurate 판단은 simulation VCD와 assertion 결과를 기준으로 한다.

## Verification status

2026-09-23 기준 Icarus Verilog 12.0에서:

- directed RTL tests: 8/8 PASS
- integrated story test: PASS
- GTKWave signal checks: 4/4 PASS

이 결과는 저장소에 구현된 interface와 event contract의 로컬 검증 근거다.
SpaceWire compliance certification, FPGA CDC/timing closure 또는 실제 PHY 환경의
recovery 검증을 의미하지 않는다.

## Engineering rules and handover

- [`docs/RTL_RULES.md`](docs/RTL_RULES.md): architecture, interface, ownership,
  event, naming, reset/CDC, verification, waveform, and change-control rules
- [`HANDOVER_WAVEFORM_INTERFACE_RESET_PARITY.md`](docs/handover/HANDOVER_WAVEFORM_INTERFACE_RESET_PARITY.md):
  next-session execution order and evidence gates
