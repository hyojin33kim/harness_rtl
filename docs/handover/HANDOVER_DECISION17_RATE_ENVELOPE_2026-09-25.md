# Handover — DECISION-17 and SpaceWire rate envelope

- Date: 2026-09-25
- Scope: `SpaceWire_RTL_Datalink_InterfaceResetStyle_2026-09-24_v5` candidate only
- Status: implementation and directed tests complete; adoption and compliance
  decision open; default RTL unchanged; no merge or commit made in this work
- Source design repository: `../../../../spec2rtl/spacewire`

## Current result

The v5 candidate implements DECISION-17 Option B: after eight contested
Timecode selections, one scheduler slot goes to a ready FCT or N-Char. It
counts new request selections, not cycles spent holding a request or sending
the second character of an atomic ESC pair. Hardware reset and ErrorReset
clear the count. The candidate README records the changed RTL and full
before/after measurements.

- Original v5 under a maximum-rate Timecode toggle: RX stalled at 16/300 DATA
  bytes after 140,000 traffic clocks, without credit/ESC error.
- Modified v5: 300/300 DATA plus EOP in 16,927 clocks; 72 throttle grants;
  no data mismatch or credit/ESC error.
- Golden model scenario_24: 501/501 items in 72,360 clocks (baseline 50,280).
- Existing v5 candidate regression and the new stress TB: PASS. The 64-item
  burst span is 2,632 clocks. v4/v5 dual-comparison metrics remain identical
  for its ordinary traffic.
- Periodic 700/1,000 ns follow-up: at 10 Mbps the original v5 stalls at
  16/32 received bytes and the candidate reaches count 8 and completes;
  at 25 Mbps both complete and candidate count peaks at 3/1. These four
  periodic cases are now in the parameterized candidate regression. The
  original-v5 negative control remains recorded evidence, outside the
  routine regression.

## Standards and implementation boundary

ECSS-E-ST-50-12C Rev.1 clauses 5.4.10 and 5.5.7.7 specify 10 +/- 1 Mbps
after reset/disconnect and permit an output-port rate change in Run. The two
directions may use different rates. The implementation-specific maximum is
not fixed at 200 Mbps. Clause 5.5.6 gives Broadcast priority over FCT and
N-Char, without a throttle exception. Thus the candidate's grant while a
Timecode remains pending requires a compliance decision; a successful packet
test does not resolve it.

- Standard: https://ecss.nl/wp-content/uploads/2019/05/ECSS-E-ST-50-12C-Rev.1(15May2019).pdf
- Commercial examples: GR718B separates initialization and per-port Run
  divisors; SpW-10X provides a per-port TXRATE divider for frequent changes.
  https://download.gaisler.com/products/gr718b/doc/gr718b-ds-um-3_9.pdf
  https://ww1.microchip.com/downloads/en/DeviceDoc/UoD_SpW_10X_UserManual_3.5.pdf
- Current harness Encoder has a compile-time `TX_RATE_MBPS` parameter and
  requires an integer system-clocks-per-bit ratio. At its 100 MHz default it
  does not implement a 200 Mbps link or Run-time rate switching. The 2-flop
  system-clock RX sampler is not high-speed closure evidence (`CDC-02`).

## Decisions still required

1. Define the product's per-port operating-rate range, Run-time change
   command, application point, and behavior during an in-flight character
   or ESC pair. Distinguish this from the standard's permission to change
   rate in Run.
2. Decide whether every 700–1,000 ns Timecode request must be delivered at
   low link rates, or whether an explicit drop/coalescing policy is allowed.
   At 10 Mbps one Timecode needs 14 bit times (1.4 us), so this request rate
   exceeds wire capacity even before FCT/N-Char traffic.
3. Resolve DECISION-17's liveness versus strict Broadcast-priority conflict
   before adopting this candidate. The source decision now marks this product
   policy `open` and retracts the disproved normal-traffic claim.

## Next work, in order

1. Define the intended product envelope, then extend the periodic regression
   to 2 Mbps and unequal directional rates. The original-v5 negative control
   can be made automatic if that comparison becomes a required gate.
2. Resolve the now-open source DECISION-17 policy and update the broader
   verification plan when the product requirement is settled.
3. Keep the Data Link candidate isolated while separately designing the
   Encoder/PHY architecture needed for Run-time speed changes and 200 Mbps.

## Workspace state at handover

`harness/rtl` is on `main`, two commits ahead of `origin/main`. This work
modified only the v5 candidate RTL, TB, regression script, README, and this
handover. Several other untracked candidate directories and `codex_*.md`
files already existed and were not touched. `spec2rtl/spacewire` is on `main`
with a pre-existing `.gitignore` modification. This work also corrected its
`docs/decisions/DECISION-17_fct_nchar_starvation_v5.md` and `CLAUDE.md`;
the `.gitignore` modification was preserved.
