# SpaceWire Story Waveforms

목적은 모든 signal을 동시에 보는 것이 아니라 `State → Transaction → Physical` 순서로 drill-down하는 것이다.

## 실행

```bash
./run_story.sh ../rtl_protocol_refactor
gtkwave spw_story.vcd link_initialize.gtkw
gtkwave spw_story.vcd flow_control.gtkw
gtkwave spw_story.vcd error_recovery.gtkw
gtkwave spw_story.vcd overview.gtkw
```

`run_story.sh`는 시뮬레이션 후 `spw_story.vcd`를 필수 생성하고, 4개
`.gtkw`에 적힌 모든 signal path가 VCD에 실제 존재하는지 검사한다.
하나라도 RTL 변경으로 사라지면 regression이 실패하므로 preset의 silent
degradation을 막는다.

`spw_story_waveforms.html`은 상위 narrative 기준파형이며 cycle-accurate 증거가 아니다.
실제 판단은 `tb_spw_story.sv`가 생성한 VCD와 RTL assertion 결과로 한다.

## Link state code

- 0: ERROR_RESET
- 1: ERROR_WAIT
- 2: READY
- 3: STARTED
- 4: CONNECTING
- 5: RUN

## Story phase

- 0: reset
- 1: link initialization
- 2: flow control / N-Char loopback
- 3: parity-error injection
- 4: reconnect

## Observability code

`obs_*`는 `spw_wave_observer.sv`의 TB 전용 관찰 신호이며 RTL 기능이나
interface를 변경하지 않는다. GTKWave에서는 `tb_spw_story.u_obs.obs_*`로
보인다. DUT 내부 계층 연결은 `tb_spw_story.sv`의 observer instance 한 곳에
모아 RTL 이름 변경 시 수정 범위를 제한한다.
GTKWave preset은 `@28` 표시 속성으로 vector/bus를 기본 hex로 연다.

- `obs_tx_char_kind`, `obs_rx_char_kind`: `0=IDLE, 1=ESC, 2=NULL, 3=FCT, 4=DATA, 5=EOP, 6=EEP, 7=TIMECODE, F=UNKNOWN`
- `obs_ser_bit_role`: `0=IDLE, 1=P, 2=C, 3=D`
- `obs_*_char_evt`: 의미가 확정된 character event. raw commit보다 1 clock 늦지만 한 cycle 안정적으로 표시된다.
- `obs_tx_is_*`, `obs_rx_is_*`: ESC/NULL/FCT/N-Char one-hot event
- `obs_link_*`, `obs_recovery_*`: link initialization/run/recovery/reconnect 구간
- `obs_*_credit_hex`, `obs_*_fifo_level_hex`: flow-control 요약 bus
- `obs_flow_blocked`: RUN에서 TX N-Char가 대기하지만 TX credit이 0인 구간
- `obs_net_tx_accept_evt`: Network→DataLink ownership transfer (`valid && ready`)
- `obs_net_rx_accept_evt`: DataLink→Network ownership transfer (`valid && ready`)

NULL은 `ESC + FCT` 시퀀스다. 첫 character commit은 `ESC`, 두 번째
character commit은 독립 FCT와 구분하여 `NULL`로 표시한다.

## 주의

Error story의 parity error는 Link recovery 흐름만 분리해서 보기 위해 TB에서 내부 error event를 강제한다.
실제 D/S bit corruption에 의한 parity 검증은 별도 Encoding physical test가 담당해야 한다.
