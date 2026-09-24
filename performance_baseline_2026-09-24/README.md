# SpaceWire RTL cycle performance baseline — 2026-09-24

## Baseline and scope

- Source: `main@49fdf4032ac5d773189035bb7f10bad149995f21`.
- RTL: `SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor/spw_*.sv`.
- No RTL, testbench, observer, or GTKWave preset was changed for this measurement.
- Tool versions: Icarus Verilog 12.0; Verilator 5.038.
- Configuration: 100 MHz system clock and 25 Mbps configured TX bit rate;
  story TX/RX FIFOs are 16 entries and burst TX/RX FIFOs are 128 entries.
  This differs from the 10 Mbps default `spw_top` parameters and from
  `CLK-01`'s general regression default.
- Measurements: existing `tb_spw_story` VCD and the separate
  `tb_spw_perf_burst.sv` with 64 continuous, value-checked data items. Both use
  a self-looped D/S connection. The story also injects a parity error by a
  TB-only force and reconnects.

## Results

| Metric | Observed | Interpretation |
|---|---:|---|
| Reset release → first RUN | 2,015 cycles / 20.150 µs | Story initialization under the configuration above |
| Reconnect phase start → second RUN | 2,698.5 cycles / 26.985 µs | Phase marker precedes a state transition; this is not error detection latency |
| Story Network TX accept intervals | 40, 40, 40 cycles | Four-item directed sequence |
| Network TX/RX accepts in flow phase | 4 / 4 | The directed self-loop received all four accepted items |
| Flow phase duration | 307 cycles | Includes host pacing and post-send wait; not a throughput denominator |
| Flow-block episodes | 0 | Backpressure/credit-limited throughput was not exercised |
| TX character commits / RX character events | 15 / 14 | Counts include control/idle traffic; not payload counts |

The ordinal TX→RX accept deltas are 51, 51, 51, and 27 cycles. They match the
event order in this one scenario, but the script does not compare item values;
do not use them as a general per-item latency guarantee. The shorter EOP delta
needs a payload-tagged test before attributing it to the datapath.

### 64-item continuous data burst

| Metric | Observed |
|---|---:|
| Host accepted / Network accepted / Host received | 64 / 64 / 64, values 0–63 in order |
| First → last Network accept | 2,632 cycles / 26.32 µs, across 63 intervals |
| Network accept gap distribution | 56 × 40 cycles, 7 × 56 cycles |
| Mean Network accept spacing | 41.78 cycles / 417.8 ns |
| Measured item rate over the 63 intervals | 2.394 Mitems/s |
| Measured 8-bit payload rate over the 63 intervals | 19.15 Mbps |
| First / last Network accept → Host receive | 52 / 52 cycles |

At 25 Mbps, a ten-bit SpaceWire data character occupies a minimum 40 system
clocks, corresponding to a 20 Mbps payload ceiling for continuous data
characters. The seven 56-cycle gaps cost 112 clocks over the 63 intervals.
The test does not classify the cause of those gaps; a transaction-kind trace
is needed before attributing them to FCT insertion or credit arbitration.
This is a finite 64-item result with an always-ready host RX; it does not
cover a blocked receiver, FIFO wrap under pressure, or target FPGA timing.

## Quality and closure limits

- Full regression: eight directed tests, integrated story, and four GTKWave
  signal-path checks passed; exit code 0.
- Verilator `--lint-only --timing -Wall -Wno-fatal` reports 24 warnings:
  8 width, 15 unused, 1 mixed sync/async reset-net use. Plain `-Wall`
  exits nonzero because warnings are fatal by default; the current lint gate
  is therefore **open**. Warning categories need review before synthesis.
- Yosys, target synthesis, and place-and-route tools were unavailable in the
  local environment. Fmax, WNS/TNS, LUT/FF/BRAM, and power are unmeasured.
- The 100 MHz/25 Mbps simulation configuration is not evidence for high-speed
  D/S input capture closure; `CDC-02` remains an architectural risk.

## Reproduce

From repository root:

```bash
cd SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor
./run_regression.sh
cd ../..
python3 performance_baseline_2026-09-24/analyze_story_vcd.py \
  SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/story_waveforms/spw_story.vcd
```

For the 64-item burst, from `rtl_protocol_refactor`:

```bash
iverilog -g2012 -s tb_spw_perf_burst -o /tmp/tb_spw_perf_burst.vvp \
  spw_phy.sv spw_enc.sv spw_datalink.sv spw_network.sv spw_top.sv \
  ../../performance_baseline_2026-09-24/tb_spw_perf_burst.sv
vvp /tmp/tb_spw_perf_burst.vvp
```

Lint from the `rtl_protocol_refactor` directory:

```bash
verilator --lint-only --timing -Wall -Wno-fatal --top-module spw_top \
  spw_phy.sv spw_enc.sv spw_datalink.sv spw_network.sv spw_top.sv
```

## Next performance gate

A dual-endpoint burst and explicit credit/backpressure scenarios are needed
before ranking a refactored RTL version across operating conditions. Target
FPGA, device, speed grade, clock constraints,
and synthesis/P&R tools are needed before any PPA comparison. New RTL should be
placed in a distinct version directory and compared against this exact source
commit with identical tests and constraints.
