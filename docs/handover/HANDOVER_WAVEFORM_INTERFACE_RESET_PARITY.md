# Handover — Waveform, Interface Naming, Reset, and Parity Closure

- Date: 2026-09-23
- Start baseline: `main@49ad5c2`
- Working branch: `docs/rtl-rule-registry`
- Rule entry point: `docs/RTL_RULES.md`
- Authoritative debug assets: GTKWave presets committed on remote `main`

## Objective

Continue the next RTL work session without losing the current protocol contract
or overwriting user-edited waveform presets. Close four areas in independently
reviewable gates:

1. parity-error cause and controlled fault injection;
2. waveform readability and independent TX/RX traffic;
3. interface/internal naming normalization;
4. reset-domain structure cleanup.

## Current verified baseline

- Network↔Data Link and Data Link↔Encoder ownership contracts are implemented.
- ACCEPT, COMMIT, and ABORT are distinct.
- Directed RTL tests: 8/8 PASS at the recorded baseline.
- Integrated story test and GTKWave signal-path checks pass at the recorded baseline.
- RTL/TB/observer in the prior scratch export matched remote; three GTKWave
  presets differed because remote contains later user edits. Remote wins.
- This evidence is not independent ECSS compliance, CDC/timing closure, or FPGA proof.

## Required reading before modification

1. `docs/RTL_RULES.md`
2. `README.md`
3. `SpaceWire_RTL_Protocol_Refactor_With_Waveforms_2026-09-23/rtl_protocol_refactor/PROTOCOL_REFACTOR_REPORT.md`
4. The five RTL modules, story TB, observer, four GTKWave presets, and regression scripts

## Execution order and gates

### Gate 0 — Reproduce baseline

- Run the complete regression from a clean checkout.
- Confirm all simulations PASS, all required VCDs are non-empty, and all
  committed GTKWave signal paths resolve.
- Do not continue if baseline behavior cannot be reproduced.

### Gate 1 — Parity diagnosis, no RTL redesign

- Prove that repeated `9'h103, 9'h100` NULL characters do not inherently cause parity error.
- Document the exact inter-character parity equation and protected-bit timing.
- Separate the current story's deliberate forced parity error from a naturally
  decoded parity failure.
- Add a controlled RX D/S fault BFM test that flips the intended P bit; do not
  use a deep DUT `force` as the final verification mechanism.
- Exit: normal stream has no error; one-bit fault produces exactly one parity
  event and the expected recovery transition.

### Gate 2 — Waveform readability and dual endpoint story

- Add two connected endpoints for normal bidirectional integration traffic.
- Host A payload: `F8,72`; Host B payload: `4E,1F`.
- Preserve serializer LSB-first behavior, but display logical wire order
  `P,C,D0...D7` in the observer.
- Add observer-only TX/RX `Data XOR Strobe` clocks and packed-ASCII Link state.
- Set bus radix to hexadecimal and numeric Link state to decimal in all affected presets.
- Preserve user layout/grouping unless a new signal requires an explicit addition.
- Exit: distinct TX/RX payloads are visible, preset checks pass, and the full
  existing regression remains green.

### Gate 3 — Naming-only refactor

- First create an exhaustive old→new module-port/top-net/observer/TB map.
- Freeze the source-owner grammar before editing RTL.
- Apply module ports `i_/o_`, sequential `r_`, combinational `w_`, and next-value
  `n_`; retain semantic suffixes `_valid/_ready/_evt/_pending/_active`.
- Keep layer vocabulary distinct without giving one boundary two incompatible meanings.
- No functional or reset behavior change is allowed in this gate.
- Exit: compile, full regression, VCD checks, and GTKWave checks pass with an
  interface-only diff.

### Gate 4 — Reset-domain refactor

- Create a register reset-domain matrix before code changes:
  `hardware async`, `protocol sync`, `recovery event`, or `deliberately unreset`.
- Use the global asynchronous reset only for hardware initialization.
- Derive synchronous protocol reset conditions inside the relevant clock domain.
- Preserve the current architectural intent: PortReset resets Data Link protocol
  state but not Network FIFOs; recovery restarts Encoder/PHY session state.
- Review D/S transition-history registers separately because resetting them can
  create a false transition.
- Exit: reset matrix reviewed, existing regression green, and new reset/recovery
  tests prove FIFO preservation, abort semantics, and clean reconnect.

## Change-control constraints

- Use a feature branch based on the latest remote `main`.
- Never copy the scratch GTKWave files over the remote versions.
- Keep parity/waveform, naming-only, and reset-functional work in separate commits.
- Update `docs/RTL_RULES.md` if a proposed rule becomes a frozen contract.
- Do not claim independent verification from the two-endpoint test; use the RX
  fault BFM and later golden/scoreboard evidence for independence.

## Completion evidence

The handover is complete only when the final report records:

- exact commit IDs for each gate;
- commands and simulator versions;
- test/VCD/GTKWave signal-check counts;
- old→new naming map and reset-domain matrix;
- parity normal/fault traces;
- remaining CDC, high-speed PHY, golden-model, and ECSS traceability risks.
