# DECISION-17 — Timecode admission and rate policy

- Status: approved
- Decision date: 2026-09-30
- Scope: product Data Link transmit policy and follow-up Encoder rate control

## Decision

1. **Option A is the product default.** Preserve strict Broadcast/Timecode
   priority over FCT and N-Char. Do not adopt the v5 Option B eight-request
   throttle as the default RTL.
2. **Use `latest-wins + drop counter` at Timecode admission.** If a new
   Timecode arrives while an older request is still pending, replace the
   pending value with the newest value and increment the drop counter for the
   displaced request.
3. **Option C is a performance extension.** Add per-port Run-time link-rate
   control in a separate Encoder/PHY change. It does not replace admission
   accounting and must not be used to claim lossless operation above wire
   capacity.

## Basis

ECSS-E-ST-50-12C Rev.1 clause 5.5.6 gives Broadcast priority over FCT and
N-Char. The v5 Option B throttle restores lower-priority progress under
continuous Timecode load, but intentionally violates that strict order after
eight contested selections.

A Timecode occupies 14 serial bits. At 10 Mbps it needs 1.4 us of wire time,
so 700 ns and 1,000 ns request periods exceed Timecode-only wire capacity
before FCT or N-Char traffic is considered. No scheduler can deliver every
request in that envelope; loss must be explicit and observable.

## Implementation gate

The policy is approved but is not yet implemented in the default RTL. Product
adoption requires all of the following:

- strict Broadcast priority in the default scheduler;
- single-pending-entry latest-wins behavior;
- a software-visible or verification-visible drop counter whose width,
  saturation/wrap behavior, clear mechanism, and interface are specified;
- directed tests proving replacement value, exact drop accounting, reset/clear
  behavior, and no regression of FCT/N-Char traffic within the supported
  request/rate envelope.

Option C requires a separate definition of supported per-port rates, command
interface, application boundary during an in-flight character or ESC pair,
CDC/timing closure, and unequal-direction-rate verification.

The existing v5 candidate remains retained as experimental evidence. Its PASS
results demonstrate a liveness tradeoff, not approval of Option B.
